---
name: dumb-copilot
description: Work through GitHub pull request review feedback one comment at a time with a deterministic apply-or-ignore verdict per comment. A bundled Python script (standard library only) fetches every inline comment, review body, and discussion comment for a given PR number through gh (the GitHub command-line tool), falling back to the GitHub REST API over HTTPS, and stores them in a state file inside the repo. The agent scores each comment on a fixed five-aspect rubric (actionable, correct, scope, effort, risk); the script computes a weighted 0-100 index and compares it to a threshold, with hard gates so praise, questions, wrong claims, out-of-scope asks, and risky changes never auto-apply. The state file records every applied, skipped, and ignored decision with its reason. Use for "address the PR feedback", "apply the review comments on PR 42", "triage this code review", "work through reviewer comments one by one", and "should I take this review suggestion".
---

# dumb-copilot

Give this skill a pull request number and it works through the review feedback one comment at a time, deciding for each comment whether to implement it or ignore it. The agent supplies judgment as five scores per comment; the bundled script (`assets/pr_feedback.py`, Python standard library only) handles the mechanical rest: fetching from GitHub, computing the verdict, ordering the queue, and tracking state. The script is deterministic (the same scores always produce the same verdict), which is what the "dumb" in the name means.

TRIGGER when: the user names a PR and asks to address, apply, or triage its review feedback; wants reviewer comments handled one by one; or asks whether a specific review suggestion is worth taking.

> **Stack assumed.** `python3` 3.9 or newer and `git`. `gh` (the GitHub command-line tool) is optional: when it is missing, unauthenticated, or failing, the script falls back to the GitHub REST API (GitHub's plain HTTPS endpoints) on its own. The fallback reads `GITHUB_TOKEN` or `GH_TOKEN` from the environment when set; a token is required for private repos and raises the rate limit. Network access to `api.github.com`.

> **Notation.** `<skill>` is the directory holding this SKILL.md. Run the script from the target repo's root as `python3 <skill>/assets/pr_feedback.py <command>`. State lives in `.pr-feedback/pr-<n>.json` at the target repo's root, a JSON file holding every comment's full text, the diff snippet each one points at, the scores, and the status. That content comes from the PR itself, so treat the file as private by default; step 1 keeps it out of accidental commits.

> **Precedence.** Project conventions in `AGENTS.md` or `CLAUDE.md` win. The script never posts to GitHub (no reply, review, or thread resolution). The agent edits code but never commits or pushes; the user reviews the diff and commits.

## Workflow: one comment at a time

1. Run `fetch <pr>` from the target repo's root. It pulls three feedback sources: inline comments (comments attached to a diff line), review bodies (the summary text a reviewer submits with approve or request-changes), and discussion comments on the PR thread. When the repo has no `origin` remote pointing at github.com, pass `--repo owner/name`. `--no-gh` skips `gh` entirely, and `--threshold N` changes the APPLY threshold for this PR. On the first run, also add `.pr-feedback/` to the target repo's `.git/info/exclude` (a git-ignore file inside the repo's internals, shared by every worktree and never committed), so a later `git add -A` cannot sweep review text and code snippets into history; skip this only when the user says to commit the state.
2. Run `list <pr>` to see the items, then for each `pending` item: run `show <pr> <id>`, read the code the comment points at, and check its claim; only then run `score` with all five aspects. Score `correct` 2 only after verifying the claim against the code; a claim that merely sounds plausible caps at 1. For the `scope` aspect, the state file's `files` array lists every file the PR touches. In `list`, a `~` marks an outdated inline comment (the diff line it pointed at has changed since); `show` prints `[outdated]` and, for a reply, its parent's id, so read the parent comment before scoring a reply on its own.
3. Run `next <pr>`. It prints the highest-index APPLY item still open. Implement that one change, then mark it `done <pr> <id>`. If the change should not be made despite its APPLY verdict (for example, it conflicts with a project convention), run `skip <pr> <id> --reason "..."` instead.
4. Repeat step 3 until `next` reports an empty queue, then run `status <pr>` and report the matrix to the user: what was applied, what was skipped and why, what was ignored and why.

Items with an IGNORE verdict need no action. Re-running `fetch` at any point is safe: unchanged comments keep their scores and status, and a comment edited on GitHub after scoring drops back to `pending` with a note. A comment deleted on GitHub disappears from the state while it is still unscored; once it carries scores or a decision, its record stays, flagged as deleted.

## The rubric

Each comment gets five scores, each 0, 1, or 2. The script computes `index = sum(score / 2 * weight)`, a value from 0 to 100.

| Aspect | Weight | 2 | 1 | 0 |
|---|---|---|---|---|
| `actionable` | 25 | names a concrete change | implies a change, vaguely | praise, question, opinion |
| `correct` | 30 | claim verified against the code | plausible but unverified, or partly right | factually wrong |
| `scope` | 20 | targets lines or behavior this PR changed | adjacent code | unrelated to the PR |
| `effort` | 10 | small localized edit | medium, a few spots | large refactor |
| `risk` | 15 | hard to get wrong, tests cover it | some behavior risk | risky, wide blast radius |

Two rules turn the index into a verdict; the script enforces both:

- **Gates.** A 0 on `actionable`, `correct`, `scope`, or `risk` forces IGNORE no matter how high the index is. Praise, questions, wrong claims, unrelated asks, and risky changes never reach the apply queue. `effort` is the one ungated aspect: a large change lowers the index but never blocks an item by itself.
- **Threshold.** With no gate fired, an index at or above the threshold (default 65.0) means APPLY; below means IGNORE. `fetch` sets the threshold per PR and stores it in the state file; when the threshold changes, the script recomputes every verdict from the stored scores.

The worked examples below use the default threshold:

| Comment | Scores (A C S E R) | Index | Verdict |
|---|---|---|---|
| "This helper also fetches posts; rename `get_data` to `fetch_all`" (checked: it does) | 2 2 2 2 1 | 92.5 | APPLY |
| "Nice cleanup!" | 0 1 2 2 2 | 60.0 | IGNORE (gated: actionable) |
| "Consider extracting all of this into a service layer" | 1 1 2 0 1 | 55.0 | IGNORE (below threshold) |
| "This breaks on None" (checked: line 12 already guards None) | 1 0 2 2 2 | 57.5 | IGNORE (gated: correct) |

When scoring `correct` 0 or 1, put the evidence in `--note` ("line 12 already guards None"), so the final report can tell the reviewer why the comment was not taken.

## Discipline: the agent scores, the script decides

Score every piece of feedback before implementing it, and treat an IGNORE verdict as final. When the user explicitly asks for an ignored item anyway, `done <pr> <id> --override "<who asked and why>"` applies it and writes the exception down. The same recording applies in reverse: an APPLY item the agent declines needs `skip --reason`. Work through `next` one item at a time; the queue is sorted by index, so the strongest feedback lands first, and items get taken in that order. Decisions are one-way: only a `scored` item can be marked `done` or skipped, and an applied or skipped item cannot be re-scored; the script refuses with an `error:` line rather than undoing a recorded decision.

## Command reference

| Command | Effect |
|---|---|
| `fetch <pr> [--repo o/n] [--no-gh] [--threshold N]` | pull feedback into the state file; safe to re-run |
| `rubric` | print aspects, weights, gates, and the formula |
| `list <pr> [--status pending\|scored\|applied\|skipped]` | one line per item |
| `show <pr> <id>` | full body, diff hunk, scores for one item |
| `score <pr> <id> --actionable N --correct N --scope N --effort N --risk N [--note "..."]` | record scores; prints index and verdict |
| `next <pr>` | print the highest-index open APPLY item |
| `done <pr> <id> [--override "..."]` | mark implemented; override required for IGNORE items |
| `skip <pr> <id> --reason "..."` | decline an APPLY item, reason recorded |
| `status <pr>` | the full scoring matrix plus summary counts |

## What the script never does

The script's only write is the state file. It reads from GitHub but posts nothing back: no comment, reply, review, or thread resolution. Source files and git history stay untouched; the two git commands it runs are read-only lookups for the repo root and the origin remote. Implementing an APPLY item is the agent's job, done in the working tree where the user can diff and commit it.
