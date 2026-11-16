"""Tests for pr_feedback.py: the scope gate, the P0 exception, the Copilot
overview, and `resolve`. GitHub is replaced by a stub `gh` on PATH.

Run from anywhere: python3 dumb-copilot/tests/test_pr_feedback.py
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "pr_feedback.py")

# The stub answers REST reads from FIXTURES (keyed by API path), prints the
# review threads one JSON object per line (what `--jq ...nodes[]` yields),
# and logs every resolve mutation's thread id to GH_LOG.
STUB_GH = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    fixtures = json.load(open(os.environ["FIXTURES"]))
    if args[:2] == ["api", "graphql"]:
        query = next(a for a in args if a.startswith("query="))
        if "resolveReviewThread" in query:
            thread = next(a for a in args if a.startswith("id="))[3:]
            open(os.environ["GH_LOG"], "a").write(thread + "\\n")
            print('{"data":{}}')
        else:
            for node in fixtures["threads"]:
                print(json.dumps(node))
    else:
        print(json.dumps(fixtures[args[-1]]))
''')

OVERVIEW = textwrap.dedent('''\
    <!-- ccr-overview-v2 -->

    ### 🟡 Changes recommended

    One open issue.

    - <img alt="High severity"> [Fix it](https://github.com/o/r/pull/7#discussion_r1) · New
''')


def thread(tid, ids, resolved=False):
    return {"id": tid, "isResolved": resolved,
            "comments": {"nodes": [{"databaseId": i} for i in ids]}}


def inline(cid, reply_to=None):
    return {"id": cid, "user": {"login": "Copilot"}, "body": "comment %d" % cid,
            "path": "a.py", "line": cid, "position": 1, "in_reply_to_id": reply_to}


class PrFeedbackTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        subprocess.run(["git", "init", "-q", root], check=True)
        os.mkdir(os.path.join(root, "bin"))
        gh = os.path.join(root, "bin", "gh")
        with open(gh, "w") as handle:
            handle.write(STUB_GH)
        os.chmod(gh, 0o755)
        self.log = os.path.join(root, "gh.log")
        self.fixtures = os.path.join(root, "fixtures.json")
        base = "repos/o/r/pulls/7"
        with open(self.fixtures, "w") as handle:
            json.dump({
                base: {"title": "t", "state": "open"},
                base + "/files": [{"filename": "a.py"}],
                base + "/comments": [inline(1), inline(2), inline(3), inline(4), inline(5, reply_to=4)],
                base + "/reviews": [
                    {"id": 10, "user": {"login": "copilot-pull-request-reviewer[bot]"},
                     "body": OVERVIEW, "state": "COMMENTED", "submitted_at": "2026-11-16T00:00:00Z"},
                    {"id": 11, "user": {"login": "alice"}, "body": "Please split this.",
                     "state": "COMMENTED", "submitted_at": "2026-11-16T01:00:00Z"},
                ],
                "repos/o/r/issues/7/comments": [],
                "threads": [thread("T1", [1]), thread("T2", [2]), thread("T3", [3]),
                            thread("T4", [4, 5]), thread("T9", [9], resolved=True)],
            }, handle)
        self.env = dict(os.environ, PATH=os.path.join(root, "bin") + os.pathsep + os.environ["PATH"],
                        FIXTURES=self.fixtures, GH_LOG=self.log)
        self.cli("fetch", "7", "--repo", "o/r")

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args, ok=True):
        proc = subprocess.run([sys.executable, SCRIPT, *args], cwd=self.tmp.name, env=self.env,
                              capture_output=True, text=True)
        if ok and proc.returncode != 0:
            self.fail("%s exited %d: %s" % (args, proc.returncode, proc.stderr))
        return proc

    def score(self, item, a, c, s, e, r, *extra, ok=True):
        return self.cli("score", "7", item, "--actionable", str(a), "--correct", str(c),
                        "--scope", str(s), "--effort", str(e), "--risk", str(r), *extra, ok=ok)

    def state(self):
        with open(os.path.join(self.tmp.name, ".pr-feedback", "pr-7.json")) as handle:
            return json.load(handle)

    def test_overview_is_metadata_not_an_item(self):
        state = self.state()
        ids = [i["id"] for i in state["items"]]
        self.assertNotIn("rv10", ids)
        self.assertIn("rv11", ids)
        self.assertEqual(state["copilot_overview"], "🟡 Changes recommended")

    def test_adjacent_code_is_ignored_even_with_a_high_index(self):
        out = self.score("rc1", 2, 2, 1, 2, 2).stdout
        self.assertIn("90.0 -> IGNORE", out)
        self.assertIn("gated: scope", out)

    def test_p0_needs_a_verified_claim(self):
        proc = self.score("rc1", 2, 1, 0, 2, 2, "--p0", "crash", ok=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--p0 needs --correct 2", proc.stderr)

    def test_p0_lifts_scope_gate_and_threshold_only(self):
        self.assertIn("62.5 -> APPLY", self.score("rc1", 2, 2, 0, 0, 1, "--p0", "crash").stdout)
        self.assertIn("gated: risk", self.score("rc2", 2, 2, 0, 2, 0, "--p0", "crash").stdout)

    def test_resolve_closes_only_decided_threads(self):
        self.score("rc1", 2, 2, 1, 2, 2)                # ignored: decided
        self.score("rc2", 2, 2, 2, 2, 2)                # APPLY, then applied
        self.cli("done", "7", "rc2")
        self.score("rc3", 2, 2, 2, 2, 2)                # APPLY, not yet applied
        self.score("rc4", 0, 1, 2, 2, 2)                # ignored, but reply rc5 is pending
        proc = self.cli("resolve", "7", ok=False)
        self.assertEqual(proc.returncode, 3)
        self.assertIn("left open rc3", proc.stdout)
        self.assertIn("left open rc4: undecided or not fetched: rc5", proc.stdout)
        with open(self.log) as handle:
            self.assertEqual(handle.read().split(), ["T1", "T2"])

        self.cli("done", "7", "rc3")
        self.score("rc5", 0, 1, 2, 2, 2)
        os.remove(self.log)
        self.assertIn("resolved 4 thread(s), left 0 open", self.cli("resolve", "7").stdout)
        with open(self.log) as handle:
            self.assertEqual(handle.read().split(), ["T1", "T2", "T3", "T4"])


if __name__ == "__main__":
    unittest.main()
