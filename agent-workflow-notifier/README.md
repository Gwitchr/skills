# agent-workflow-notifier

A Claude Code hook that sends you a Slack direct message (DM) when an agent finishes a turn, waits on a permission prompt, or asks a question. It is one bash script under `~/.claude/hooks`, one config file with your Slack ids, one Slack app created from the manifest in `assets/`, and a hook block merged into each repo's `.claude/settings.local.json`. Nothing in the assets names a user, app, team, or project.

## Requirements

- The `slack` CLI 4.x, logged in with `slack auth login`.
- `jq`, `curl`, git, bash 3.2 or newer.
- Claude Code with `Stop`, `Notification`, and `PreToolUse` hooks.

## What you get

Each event becomes one message: a title (`✅ Finished`, `❓ Needs your input`, `🔐 Needs your input: permission`), the repo and branch, the agent name and session id, the first prompt of the session, and the last assistant message or the pending question.

The hook posts with `curl` and a bot token it fetches once from the Slack CLI's session and caches at mode 600. Only when the cache is empty and the CLI session has expired does it fall back to `slack api`, which refreshes the session so the next send fills the cache. A `Stop` after a turn shorter than `SLACK_NOTIFIER_MIN_SECONDS` (default 120) is skipped on the assumption that you were watching; permission prompts and questions always send. `SLACK_NOTIFIER_DRY_RUN=1` prints the message instead of sending it.

## Install

`SKILL.md` carries the full sequence. In short: copy `assets/slack-done.sh` to `~/.claude/hooks/`, create the Slack app with `slack app install` from a project dir holding `assets/manifest.json`, write `~/.claude/agent-workflow-notifier.env` from the template with your user, app, and team ids, and merge `assets/settings.hooks.json` into the repo's `.claude/settings.local.json`. In a bare clone (a git clone with no working tree of its own) set up with the `worktrees` skill, the manifest line `.claude/settings.local.json merge-json` makes `warm-worktrees.sh` do that merge for every worktree.

## Assets

| File | Installs as |
|---|---|
| `slack-done.sh` | `~/.claude/hooks/slack-done.sh` |
| `manifest.json` | `~/.claude/agent-workflow-notifier/manifest.json` |
| `get-manifest.sh` | `~/.claude/agent-workflow-notifier/get-manifest.sh` |
| `slack-hooks.json` | `~/.claude/agent-workflow-notifier/.slack/hooks.json` |
| `settings.hooks.json` | merged into `.claude/settings.local.json` or `~/.claude/settings.json` |
| `agent-workflow-notifier.env.template` | `~/.claude/agent-workflow-notifier.env` |
