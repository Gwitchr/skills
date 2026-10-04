# agent-workflow-notifier

A Claude Code hook that sends you a Slack direct message (DM) when an agent finishes a turn, waits on a permission prompt, or asks a question. It is one bash script under `~/.claude/hooks`, one config file with your Slack ids, one Slack app created from the manifest in `assets/`, and a hook block merged into each repo's `.claude/settings.local.json`. Nothing in the assets names a user, app, team, or project.

## Requirements

- The `slack` CLI 4.x, logged in with `slack auth login`.
- `jq`, `curl`, git, bash 3.2 or newer.
- Claude Code with `Stop`, `Notification`, and `PreToolUse` hooks.
- Optional: the `claude` CLI for the summary bullets and `perl` for the time limit around it. Without them a finished turn shows the first sentence of the final message.

## What you get

Each event becomes one message: a title (`✅ Finished`, `❓ Needs your input`, `🔐 Needs your input: permission`), the repo and branch, and the session title in italics.

```
*✅ Finished* · `repo/worktree (branch)` <@USER_ID>
_Landing page update with aurora background_
• Rebuilt the hero section with an aurora background
• Pending: the mobile breakpoint still overflows
`claude · 1a2b3c4d · 23 min · 12 commands · 3 files edited · 4 subagents`
```

A finished turn carries 2 to 4 bullets and a footer of counts. The hook reads the transcript in one pass for the tool calls made since your last prompt, hands those plus the final message to a headless `claude -p` run, and keeps the bullets it writes. Zero counts drop out of the footer. A permission prompt or a question skips the summarizer, so it arrives with the pending text at once.

The hook posts with `curl` and a bot token it fetches once from the Slack CLI's session and caches at mode 600. Only when the cache is empty and the CLI session has expired does it fall back to `slack api`, which refreshes the session so the next send fills the cache. A `Stop` is skipped when fewer than `SLACK_NOTIFIER_MIN_SECONDS` (default 120) have passed since your last prompt, and held while a background subagent or workflow runs unless the final message asks you something. `SLACK_NOTIFIER_DRY_RUN=1` prints the message instead of sending it, and `SLACK_NOTIFIER_SUMMARY=off` makes that preview offline.

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
