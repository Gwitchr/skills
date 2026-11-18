# nazgul

Agent sessions that report to a repo and wait for orders. When a Claude Code, Codex, Grok Build or Oh My Pi session ends, a Stop hook has the agent commit a short report to a "report repo" on GitHub, then polls the session's thread in that repo for a reply. A reply can tell the agent to continue with new instructions, to stop, or to wait for the owner. Nothing in the skill names an owner, repo or project; you pick the report repo when you run `config.sh`.

## Requirements

- git, bash 3.2 or newer, `jq` 1.6 or newer.
- `gh`, logged in, with push access to the report repo.
- Optional: `perl` (time limit on each GitHub call) and `gitleaks` (secret scan; built-in patterns otherwise).
- One or more of: Claude Code; Codex 0.129 or newer; Grok Build 0.2.107 or newer; Oh My Pi.

## Install

From the project repo, with the skill at `.agents/skills/nazgul/` (any folder inside the repo works):

```sh
bash .agents/skills/nazgul/scripts/config.sh    # asks for the report repo and the project slug
bash .agents/skills/nazgul/scripts/install.sh   # writes the hooks, prints the trust steps
```

Then trust the hooks where the tool asks for it: in Codex, run `/hooks` and press `t` (or choose "Trust all and continue" at startup); in Grok, run `/hooks-trust`. Claude Code and Oh My Pi load the hooks at the next session start.

## What a session does

1. The agent finishes. The Stop hook blocks once and hands it a `report.sh` command with five sections to fill in: Changed, Why, Where, Left, Needs owner.
2. `report.sh` checks the sections, scans for secrets, and creates `projects/<project>/threads/<thread-id>/001_<agent>.md` in the report repo through `gh api`. The commit message is `nazgul(<project>): <summary>`.
3. The hook checks the thread every 2 minutes, up to 5 times, for a newer file whose frontmatter says `action: continue`, `stop` or `wait-for-owner`.
4. `continue` makes the agent resume with the reply's body, at most 3 times per session; when it finishes, it reports again. `stop` and `wait-for-owner` end the session with a note. No reply ends it after about 10 minutes and leaves the thread open.

Oh My Pi cannot block at the end of a turn, so there nazgul pushes a report built from git and the last message, polls in the background, and shows a reply at the next prompt.

## Files

| Path | Role |
|---|---|
| `SKILL.md` | Instructions for the agent: setup, report and reply formats, rules, troubleshooting |
| `scripts/config.sh` | Sets the report repo, project slug and skip paths |
| `scripts/install.sh` | Writes or merges the hook files into the project |
| `scripts/report.sh` | Pushes the next numbered message in the session's thread |
| `scripts/poll.sh` | Looks for a reply in the session's thread |
| `scripts/check.sh` | Stop-hook logic: report, poll, then continue or end |
| `scripts/lib.sh` | Shared helpers: config, git context, GitHub calls, secret scan |
| `hooks/claude.settings.json` | Template for `.claude/settings.json` |
| `hooks/codex.hooks.json` | Template for `.codex/hooks.json` |
| `hooks/grok.hooks.json` | Template for `.grok/hooks/nazgul.json` |
| `hooks/omp/post/nazgul.ts` | Template for `.omp/hooks/post/nazgul.ts` |
| `hooks/commit-msg` | Git hook that warns an agent committing on a branch with no report |
| `tests/run.sh` | Every script against a fake `gh`; no network |
| `tests/e2e-claude.sh` | One real headless Claude Code session against the fake `gh` |

## Safety

The scripts only add files: GitHub refuses a contents `PUT` without a `sha` for a path that exists, and nazgul never sends one. They write only under the configured project and read only the session's own thread. They use the `gh` login already on the machine, never clone, and never put a token in a URL. A network or auth failure prints a warning and lets the session end.
