# nazgul

Agent sessions that report to a repo and wait for a reply. When a Claude Code, Codex, Grok Build or Oh My Pi session ends, a Stop hook has the agent commit a short report to a "report repo" on GitHub, then polls the session's thread in that repo for a reply. A reply can say continue, stop, or wait for the owner. Continue is shown to you and the session ends, unless you set `auto_continue=true`. A reply is acted on only when the commit that wrote it is from a GitHub login you listed in `reply_authors`. Nothing in the skill names an owner, repo or project; you pick the report repo when you run `config.sh`.

nazgul leaves no trace in your repos. The skill, its config and its hooks live in your home folder; a repo is turned on by enrolling it, and its state sits in its git dir. Nothing is committed, `git status` stays empty, and every worktree of an enrolled bare repo is covered, including worktrees you add later.

## Requirements

- git, bash 3.2 or newer, `jq` 1.6 or newer.
- `gh`, logged in, with push access to the report repo.
- Optional: `perl` (time limit on each GitHub call) and `gitleaks` (secret scan; built-in patterns otherwise).
- One or more of: Claude Code; Codex 0.129 or newer; Grok Build 0.2.107 or newer; Oh My Pi.

## Install

Put the skill outside your repos, for example at `~/.agents/skills/nazgul/` (for Claude Code to list it as a skill, also link it into `~/.claude/skills/`). Then, from any worktree of the repo, or from the bare repo itself:

```sh
bash ~/.agents/skills/nazgul/scripts/config.sh --repo <owner>/<repo> --reply-authors <login>,<login>
bash ~/.agents/skills/nazgul/scripts/install.sh --enroll   # per repo: enrolls it, writes the hooks
```

`auto_continue` stays off unless you pass `--auto-continue true`. `require_verified` stays off unless you pass `--require-verified true`. Turn it on only when replies come from signed commits; a contents-API commit made with a personal token is unsigned, so with it on those replies are ignored (see SKILL.md). `config.sh` with no flags asks for the report repo.

Spoken notifications are off by default. On macOS, run `bash ~/.agents/skills/nazgul/scripts/config.sh --speak true` to announce each successfully posted report and accepted reply with `say`. The announcements use fixed text, not the report or reply contents. Turn them off with `--speak false`; on other operating systems they remain silent. `config.sh --show` displays the setting.

`install.sh` writes user-level hooks for each tool you have (`~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.grok/hooks/nazgul.json`, `~/.omp/agent/hooks/post/nazgul.ts`) and a commit-msg backstop into the repo's git dir. The hooks run everywhere but do nothing outside enrolled repos. Then trust the hooks where the tool asks: in Codex, run `/hooks` and press `t` (or choose "Trust all and continue"); in Grok, accept the folder trust prompt or run `/hooks-trust` in each worktree. Claude Code and Oh My Pi load the hooks at the next session start.

`install.sh --unenroll` puts the repo back exactly as it was; after the last repo it removes the user-level hooks too. `config.sh --show` lists the enrolled repos.

## What a session does

1. The agent finishes. The Stop hook blocks once and hands it a `report.sh` command with five sections to fill in: Changed, Why, Where, Left, Needs owner.
2. `report.sh` checks the sections, scans for secrets, and creates `projects/<project>/threads/<thread-id>/001_<agent>.md` in the report repo through `gh api`. The commit message is `nazgul(<project>): <summary>`.
3. The hook checks the thread every 2 minutes, up to 5 times, for a newer file whose frontmatter says `action: continue`, `stop` or `wait-for-owner`.
4. With `reply_authors` set, a `continue` reply is shown to you and the session ends. With `auto_continue=true` it makes the agent resume with the reply's body, at most 3 times per session, and when it finishes it reports again. `stop` and `wait-for-owner` end the session with a note. No reply ends it after about 10 minutes and leaves the thread open. With no `reply_authors`, the report is still pushed and no reply is acted on.

Oh My Pi cannot block at the end of a turn, so there nazgul pushes a report built from git and the last message and polls in the background. A reply is shown at the next prompt, and added to the agent's context only when `auto_continue` is on.

## Files

| Path | Role |
|---|---|
| `SKILL.md` | Instructions for the agent: setup, report and reply formats, rules, troubleshooting |
| `scripts/config.sh` | Sets the report repo and skip paths; `--show` lists enrolled repos |
| `scripts/install.sh` | Enrolls or unenrolls a repo; writes or removes the user-level hooks |
| `scripts/report.sh` | Pushes the next numbered message in the session's thread |
| `scripts/poll.sh` | Looks for a reply in the session's thread |
| `scripts/check.sh` | Stop-hook logic: report, poll, then continue or end |
| `scripts/lib.sh` | Shared helpers: config, git context, GitHub calls, secret scan |
| `hooks/claude.settings.json` | Template for `~/.claude/settings.json` |
| `hooks/codex.hooks.json` | Template for `~/.codex/hooks.json` |
| `hooks/grok.hooks.json` | Template for `~/.grok/hooks/nazgul.json` |
| `hooks/omp/post/nazgul.ts` | Template for `~/.omp/agent/hooks/post/nazgul.ts` |
| `hooks/commit-msg` | Git hook, in the repo's git dir, that warns an agent committing on a branch with no report |
| `tests/run.sh` | The scripts against a fake `gh`; no network |
| `tests/e2e-claude.sh` | One real headless Claude Code session, in a worktree of a bare repo, against the fake `gh` |

## Safety

The scripts only add files: GitHub refuses a contents `PUT` without a `sha` for a path that exists, and nazgul never sends one. They write only under the configured project and read only the session's own thread, and only a reply whose commit is from an allowlisted login (and verified, when `require_verified` is on). They use the `gh` login already on the machine, never clone, and never put a token in a URL. A network or auth failure prints a warning and lets the session end. In your repos nazgul writes only inside the git dir (`hooks/commit-msg` and `nazgul/`), never in a work tree, `.gitignore` or `info/exclude`. The hooks are user-level and do nothing outside an enrolled repo. `install.sh --unenroll` removes them once no repo is enrolled. `auto_continue` is off by default, so a continue reply is shown to you and does not steer the agent.
