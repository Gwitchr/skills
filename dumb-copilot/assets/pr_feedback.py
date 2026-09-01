#!/usr/bin/env python3
"""Deterministic triage for GitHub pull-request feedback.

Subcommands:
  fetch   pull every piece of review feedback on a PR into a local state file
  rubric  print the scoring rubric (aspects, weights, gates, threshold)
  list    one line per feedback item, optionally filtered by status
  show    print one item in full (body, diff hunk, scores)
  score   record the five aspect scores for one item; the script computes
          the weighted index and the APPLY / IGNORE verdict
  next    print the highest-index APPLY item still waiting for implementation
  done    mark an item implemented
  skip    decline an APPLY item, with a required reason
  status  print the scoring matrix and summary counts

Stdlib only, Python 3.9+. Reads GitHub through `gh` when available and
falls back to the REST API over HTTPS (GH_TOKEN / GITHUB_TOKEN are used
when set). The script never posts to GitHub and never runs git commands
other than read-only lookups.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

API_ROOT = "https://api.github.com"
STATE_DIR = ".pr-feedback"
DEFAULT_THRESHOLD = 65.0

# (key, weight, anchor text for scores 2 / 1 / 0)
ASPECTS = [
    ("actionable", 25, "2: names a concrete change. 1: implies a change but vaguely. "
                       "0: praise, a question, or an opinion with nothing to change."),
    ("correct", 30, "2: the comment's claim was verified against the code. "
                    "1: plausible but unverified, or only partly right. 0: factually wrong."),
    ("scope", 20, "2: targets lines or behavior this PR changed. "
                  "1: adjacent code the PR touches indirectly. 0: unrelated to the PR."),
    ("effort", 10, "2: small localized edit. 1: medium change across a few spots. "
                   "0: large refactor or new subsystem."),
    ("risk", 15, "2: hard to get wrong, behavior covered by tests. "
                 "1: some behavior risk. 0: risky change or wide blast radius."),
]
WEIGHTS = {key: weight for key, weight, _ in ASPECTS}
# Any gated aspect scored 0 forces IGNORE regardless of the index.
GATES = ("actionable", "correct", "scope", "risk")
KIND_RANK = {"review": 0, "comment": 1, "inline": 2}
STATUSES = ("pending", "scored", "applied", "skipped")


def fail(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def repo_root():
    proc = run(["git", "rev-parse", "--show-toplevel"])
    return proc.stdout.strip() if proc.returncode == 0 else os.getcwd()


def repo_slug(explicit):
    if explicit:
        if not re.fullmatch(r"(?!\.+/)[A-Za-z0-9._-]+/(?!\.+$)[A-Za-z0-9._-]+", explicit):
            fail("--repo must be owner/name, got %r" % explicit)
        return explicit
    proc = run(["git", "remote", "get-url", "origin"])
    if proc.returncode != 0:
        fail("no origin remote found; pass --repo owner/name")
    match = re.search(r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", proc.stdout.strip())
    if not match:
        fail("origin is not a github.com remote; pass --repo owner/name")
    return match.group(1) + "/" + match.group(2)


# ---------- GitHub access: gh first, HTTPS fallback ----------

def parse_concat_json(text):
    """Parse gh --paginate output: one or more JSON documents back to back."""
    decoder = json.JSONDecoder()
    text = text.strip()
    results, pos = [], 0
    while pos < len(text):
        obj, pos = decoder.raw_decode(text, pos)
        results.extend(obj if isinstance(obj, list) else [obj])
        while pos < len(text) and text[pos] in " \t\r\n":
            pos += 1
    return results


def gh_get(path):
    proc = run(["gh", "api", "--paginate", path])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip().splitlines()[0] if proc.stderr.strip() else "gh api failed")
    return parse_concat_json(proc.stdout)


def http_get(path):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "pr-feedback-script",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    sep = "&" if "?" in path else "?"
    url = API_ROOT + "/" + path + sep + "per_page=100"
    results = []
    while url:
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                results.extend(data if isinstance(data, list) else [data])
                link = resp.headers.get("Link") or ""
                match = re.search(r'<([^>]+)>;\s*rel="next"', link)
                url = match.group(1) if match else None
        except urllib.error.HTTPError as err:
            hint = "" if token else "; set GITHUB_TOKEN for private repos or higher rate limits"
            fail("GitHub API returned %d for %s%s" % (err.code, path, hint))
        except urllib.error.URLError as err:
            fail("cannot reach api.github.com (%s)" % err.reason)
    return results


def api_get(path, no_gh):
    if not no_gh and shutil.which("gh"):
        try:
            return gh_get(path)
        except RuntimeError as err:
            print("gh failed (%s); falling back to HTTPS" % err, file=sys.stderr)
    return http_get(path)


# ---------- state ----------

def state_path(pr):
    return os.path.join(repo_root(), STATE_DIR, "pr-%d.json" % pr)


def load_state(pr, missing_ok=False):
    path = state_path(pr)
    if not os.path.exists(path):
        if missing_ok:
            return None
        fail("no state for PR #%d; run `fetch %d` first (expected %s)" % (pr, pr, path))
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def save_state(state):
    path = state_path(state["pr"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")


def find_item(state, item_id):
    for item in state["items"]:
        if item["id"] == item_id:
            return item
    fail("no item %r in PR #%d state; run `list %d`" % (item_id, state["pr"], state["pr"]))


def num_id(item_id):
    return int(re.sub(r"\D", "", item_id) or "0")


def sort_key(item):
    return (
        KIND_RANK.get(item["kind"], 9),
        item.get("path") or "",
        item.get("line") or 0,
        num_id(item["id"]),
    )


# ---------- scoring ----------

def compute_verdict(scores, threshold):
    index = round(sum(scores[k] * WEIGHTS[k] / 2.0 for k in WEIGHTS), 1)
    gated = sorted(k for k in GATES if scores[k] == 0)
    if gated:
        return index, "IGNORE", gated
    return index, ("APPLY" if index >= threshold else "IGNORE"), []


def recompute_all(state):
    for item in state["items"]:
        if item.get("scores"):
            item["index"], item["verdict"], item["gated"] = compute_verdict(
                item["scores"], state["threshold"]
            )


# ---------- commands ----------

def make_item(item_id, kind, raw_user, body, **extra):
    item = {
        "id": item_id,
        "kind": kind,
        "author": (raw_user or {}).get("login", "unknown"),
        "body": body,
        "body_hash": hashlib.sha256(body.encode("utf-8")).hexdigest()[:12],
        "path": None,
        "line": None,
        "outdated": False,
        "reply_to": None,
        "url": "",
        "diff_hunk": "",
        "status": "pending",
        "scores": None,
        "index": None,
        "verdict": None,
        "gated": [],
        "note": "",
        "deleted": False,
    }
    item.update(extra)
    return item


def cmd_fetch(args):
    slug = repo_slug(args.repo)
    base = "repos/%s/pulls/%d" % (slug, args.pr)
    meta_list = api_get(base, args.no_gh)
    if not meta_list:
        fail("PR #%d not found in %s" % (args.pr, slug))
    meta = meta_list[0]
    files = api_get(base + "/files", args.no_gh)
    inline = api_get(base + "/comments", args.no_gh)
    reviews = api_get(base + "/reviews", args.no_gh)
    general = api_get("repos/%s/issues/%d/comments" % (slug, args.pr), args.no_gh)

    items = []
    for c in inline:
        items.append(make_item(
            "rc%d" % c["id"], "inline", c.get("user"), c.get("body") or "",
            path=c.get("path"),
            line=c.get("line") or c.get("original_line"),
            outdated=c.get("position") is None,
            reply_to=("rc%d" % c["in_reply_to_id"]) if c.get("in_reply_to_id") else None,
            url=c.get("html_url") or "",
            diff_hunk=c.get("diff_hunk") or "",
        ))
    for r in reviews:
        body = (r.get("body") or "").strip()
        if not body:
            continue
        items.append(make_item(
            "rv%d" % r["id"], "review", r.get("user"), body,
            url=r.get("html_url") or "",
            note="review state: %s" % r.get("state", ""),
        ))
    for c in general:
        items.append(make_item(
            "ic%d" % c["id"], "comment", c.get("user"), c.get("body") or "",
            url=c.get("html_url") or "",
        ))

    old = load_state(args.pr, missing_ok=True)
    threshold = args.threshold if args.threshold is not None else (
        old["threshold"] if old else DEFAULT_THRESHOLD
    )
    old_items = {i["id"]: i for i in old["items"]} if old else {}
    for item in items:
        prev = old_items.pop(item["id"], None)
        if prev is None:
            continue
        if prev["body_hash"] == item["body_hash"]:
            for key in ("status", "scores", "index", "verdict", "gated", "note"):
                item[key] = prev[key]
        elif prev["status"] != "pending":
            item["note"] = "body edited after scoring; score again"
    for leftover in old_items.values():
        if leftover["status"] != "pending":
            leftover["deleted"] = True
            items.append(leftover)

    items.sort(key=sort_key)
    state = {
        "repo": slug,
        "pr": args.pr,
        "title": meta.get("title", ""),
        "pr_state": meta.get("state", ""),
        "files": sorted(f.get("filename", "") for f in files),
        "threshold": threshold,
        "items": items,
    }
    recompute_all(state)
    save_state(state)

    kinds = {"inline": 0, "review": 0, "comment": 0}
    for item in items:
        if not item["deleted"]:
            kinds[item["kind"]] = kinds.get(item["kind"], 0) + 1
    print("PR #%d %s: %s" % (args.pr, slug, state["title"]))
    print("fetched %d items: %d inline, %d review bodies, %d comments"
          % (sum(kinds.values()), kinds["inline"], kinds["review"], kinds["comment"]))
    print("state: %s (threshold %.1f)" % (os.path.relpath(state_path(args.pr)), threshold))
    print_counts(state)


def cmd_rubric(_args):
    print("Aspects (each scored 0, 1, or 2):")
    for key, weight, anchors in ASPECTS:
        print("  %-10s weight %2d  %s" % (key, weight, anchors))
    print("Gates: a 0 on any of %s forces IGNORE regardless of the index." % ", ".join(GATES))
    print("Index = sum(score / 2 * weight), range 0-100.")
    print("Verdict: APPLY when no gate fired and index >= threshold (default %.1f)." % DEFAULT_THRESHOLD)


def one_line(text, width):
    flat = re.sub(r"\s+", " ", text).strip()
    return flat if len(flat) <= width else flat[: width - 3] + "..."


def where(item):
    if item["kind"] != "inline":
        return "-"
    loc = item["path"] or "?"
    if item["line"]:
        loc += ":%d" % item["line"]
    return loc


def cmd_list(args):
    state = load_state(args.pr)
    for item in state["items"]:
        if args.status and item["status"] != args.status:
            continue
        verdict = item["verdict"] or "-"
        index = "%.1f" % item["index"] if item["index"] is not None else "-"
        flags = ("~" if item["outdated"] else "") + ("x" if item["deleted"] else "")
        print("%-10s %-8s %-6s %5s %-2s %-16s %-28s %s" % (
            item["id"], item["status"], verdict, index, flags,
            one_line(item["author"], 16), one_line(where(item), 28),
            one_line(item["body"], 70),
        ))


def print_item(item, threshold):
    print("id:      %s (%s)" % (item["id"], item["kind"]))
    print("author:  %s" % item["author"])
    print("where:   %s%s" % (where(item), "  [outdated]" if item["outdated"] else ""))
    if item["reply_to"]:
        print("reply_to: %s" % item["reply_to"])
    if item["url"]:
        print("url:     %s" % item["url"])
    if item["deleted"]:
        print("deleted: true (comment no longer on GitHub)")
    if item["scores"]:
        parts = " ".join("%s=%d" % (k, item["scores"][k]) for k, _, _ in ASPECTS)
        gate_note = " gated: %s" % ",".join(item["gated"]) if item["gated"] else ""
        print("scores:  %s -> index %.1f -> %s (threshold %.1f)%s"
              % (parts, item["index"], item["verdict"], threshold, gate_note))
    print("status:  %s%s" % (item["status"], "  note: " + item["note"] if item["note"] else ""))
    print("--- body ---")
    print(item["body"])
    if item["diff_hunk"]:
        print("--- diff hunk ---")
        print(item["diff_hunk"])


def cmd_show(args):
    state = load_state(args.pr)
    print_item(find_item(state, args.id), state["threshold"])


def cmd_score(args):
    state = load_state(args.pr)
    item = find_item(state, args.id)
    if item["deleted"]:
        fail("%s was deleted on GitHub; nothing to score" % args.id)
    if item["status"] in ("applied", "skipped"):
        fail("%s is already %s" % (args.id, item["status"]))
    scores = {key: getattr(args, key) for key in WEIGHTS}
    item["scores"] = scores
    item["index"], item["verdict"], item["gated"] = compute_verdict(scores, state["threshold"])
    item["status"] = "scored"
    if args.note:
        item["note"] = args.note
    save_state(state)
    gate_note = " (gated: %s)" % ",".join(item["gated"]) if item["gated"] else ""
    print("%s index %.1f -> %s (threshold %.1f)%s"
          % (args.id, item["index"], item["verdict"], state["threshold"], gate_note))


def apply_queue(state):
    queue = [i for i in state["items"]
             if i["verdict"] == "APPLY" and i["status"] == "scored" and not i["deleted"]]
    queue.sort(key=lambda i: (-i["index"], num_id(i["id"])))
    return queue


def cmd_next(args):
    state = load_state(args.pr)
    pending = [i for i in state["items"] if i["status"] == "pending" and not i["deleted"]]
    queue = apply_queue(state)
    if not queue:
        if pending:
            print("queue empty, but %d items are still unscored; score them first." % len(pending))
        else:
            print("queue empty: every APPLY item is applied or skipped.")
        print_counts(state)
        return
    print_item(queue[0], state["threshold"])
    if len(queue) > 1:
        print("--- queued behind this: %d more APPLY items ---" % (len(queue) - 1))
    if pending:
        print("--- still unscored: %d items ---" % len(pending))


def cmd_done(args):
    state = load_state(args.pr)
    item = find_item(state, args.id)
    if item["status"] != "scored":
        fail("%s is %s; only scored items can be marked done" % (args.id, item["status"]))
    if item["verdict"] == "IGNORE" and not args.override:
        fail("%s verdict is IGNORE; pass --override '<who asked and why>' to apply anyway" % args.id)
    item["status"] = "applied"
    if args.override:
        prefix = item["note"] + "; " if item["note"] else ""
        item["note"] = prefix + "override: " + args.override
    save_state(state)
    print("%s marked applied." % args.id)
    print_counts(state)


def cmd_skip(args):
    state = load_state(args.pr)
    item = find_item(state, args.id)
    if item["status"] != "scored":
        fail("%s is %s; only scored items can be skipped" % (args.id, item["status"]))
    if item["verdict"] != "APPLY":
        fail("%s verdict is IGNORE; it needs no action and cannot be skipped" % args.id)
    item["status"] = "skipped"
    prefix = item["note"] + "; " if item["note"] else ""
    item["note"] = prefix + "skipped: " + args.reason
    save_state(state)
    print("%s marked skipped." % args.id)
    print_counts(state)


def print_counts(state):
    live = [i for i in state["items"] if not i["deleted"]]
    counts = {status: 0 for status in STATUSES}
    for item in live:
        counts[item["status"]] += 1
    apply_left = len(apply_queue(state))
    ignored = sum(1 for i in live if i["status"] == "scored" and i["verdict"] == "IGNORE")
    deleted = len(state["items"]) - len(live)
    line = ("pending %d | scored %d (apply queue %d, ignore %d) | applied %d | skipped %d"
            % (counts["pending"], counts["scored"], apply_left, ignored,
               counts["applied"], counts["skipped"]))
    if deleted:
        line += " | deleted %d" % deleted
    print(line)


def cmd_status(args):
    state = load_state(args.pr)
    print("PR #%d %s: %s" % (state["pr"], state["repo"], state["title"]))
    print("threshold %.1f | aspects: A=actionable C=correct S=scope E=effort R=risk (0-2)"
          % state["threshold"])
    header = "%-10s %-7s %-30s %s %s %s %s %s %6s %-7s %-8s %s" % (
        "ID", "KIND", "WHERE", "A", "C", "S", "E", "R", "INDEX", "VERDICT", "STATUS", "NOTE")
    print(header)
    print("-" * len(header))
    for item in state["items"]:
        scores = item["scores"] or {}
        cell = lambda key: str(scores[key]) if key in scores else "-"
        index = "%.1f" % item["index"] if item["index"] is not None else "-"
        loc = where(item)
        if item["outdated"]:
            loc += " ~"
        if item["deleted"]:
            loc += " x"
        print("%-10s %-7s %-30s %s %s %s %s %s %6s %-7s %-8s %s" % (
            item["id"], item["kind"], one_line(loc, 30),
            cell("actionable"), cell("correct"), cell("scope"), cell("effort"), cell("risk"),
            index, item["verdict"] or "-", item["status"], one_line(item["note"], 40)))
    print("-" * len(header))
    print_counts(state)


def main():
    parser = argparse.ArgumentParser(
        prog="pr_feedback.py",
        description="Deterministic triage for GitHub pull-request feedback.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("fetch", help="pull PR feedback into the state file")
    p.add_argument("pr", type=int)
    p.add_argument("--repo", help="owner/name; default: parsed from the origin remote")
    p.add_argument("--no-gh", action="store_true", help="skip gh, use HTTPS directly")
    p.add_argument("--threshold", type=float, help="APPLY threshold, default %.1f" % DEFAULT_THRESHOLD)
    p.set_defaults(func=cmd_fetch)

    p = sub.add_parser("rubric", help="print aspects, weights, gates, and the formula")
    p.set_defaults(func=cmd_rubric)

    p = sub.add_parser("list", help="one line per item")
    p.add_argument("pr", type=int)
    p.add_argument("--status", choices=STATUSES)
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("show", help="print one item in full")
    p.add_argument("pr", type=int)
    p.add_argument("id")
    p.set_defaults(func=cmd_show)

    p = sub.add_parser("score", help="record aspect scores; computes index and verdict")
    p.add_argument("pr", type=int)
    p.add_argument("id")
    for key, _, anchors in ASPECTS:
        p.add_argument("--" + key, type=int, choices=[0, 1, 2], required=True, help=anchors)
    p.add_argument("--note", help="one-line justification for the scores")
    p.set_defaults(func=cmd_score)

    p = sub.add_parser("next", help="print the highest-index APPLY item still open")
    p.add_argument("pr", type=int)
    p.set_defaults(func=cmd_next)

    p = sub.add_parser("done", help="mark an item implemented")
    p.add_argument("pr", type=int)
    p.add_argument("id")
    p.add_argument("--override", help="required to apply an IGNORE item: who asked and why")
    p.set_defaults(func=cmd_done)

    p = sub.add_parser("skip", help="decline an APPLY item")
    p.add_argument("pr", type=int)
    p.add_argument("id")
    p.add_argument("--reason", required=True)
    p.set_defaults(func=cmd_skip)

    p = sub.add_parser("status", help="print the scoring matrix and counts")
    p.add_argument("pr", type=int)
    p.set_defaults(func=cmd_status)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
