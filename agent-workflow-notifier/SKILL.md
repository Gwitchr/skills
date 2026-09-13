---
name: agent-workflow-notifier
description: Install, wire, or repair a Slack direct-message notifier for Claude Code, so the owner hears on Slack when an agent finishes a long turn, waits on a permission prompt, or asks a question. Setup is a short idempotent sequence the agent runs directly with the slack CLI, one hook script, one config file, and one hook block merged into a repo's .claude/settings.local.json or the user settings. Use this whenever the user mentions Slack together with Claude Code hooks, wants to be pinged, DMed, or notified when an agent is done or stuck, asks why a notification did not arrive, or says "agent-workflow-notifier", even when they do not say "hook" or "notifier".
---

# agent-workflow-notifier

This skill installs a hook that sends the owner a Slack direct message (DM) when a Claude Code agent stops, needs a permission decision, or asks a question, and only when the turn ran long enough that the owner has likely walked away. Everything lives under `~/.claude` (one script, one config file, one Slack CLI project, one token cache) plus a hook block per repo. The skill is generic: no user id, app id, or team id is baked into any asset.

TRIGGER when: the user wants Slack messages from Claude Code, asks to install or repair the notifier, wants a hook that reports when an agent finishes or waits for input, or names this skill.

> **Stack assumed.** The `slack` CLI 4.x (Slack's developer command-line tool), logged in with `slack auth login`; `jq` 1.6 or newer; `curl`; git; bash 3.2 or newer (macOS ships 3.2, Linux usually ships 5, the hook runs the same on either). Claude Code with hook support for `Stop`, `Notification`, and `PreToolUse`.

> **Notation.** `<APP_ID>`, `<TEAM_ID>`, and `<USER_ID>` are the ids the install steps produce. `<root>` is the root of a bare clone (a git clone with no working tree of its own) when the repo uses the `worktrees` skill; `<repo>` is any ordinary checkout.

> **Precedence.** Project conventions in `AGENTS.md` or `CLAUDE.md` win. If a project already documents its own notification hook, follow that instead.

## What gets installed

| Piece | Path | Mode |
|---|---|---|
| Hook script | `~/.claude/hooks/slack-done.sh` | 755 |
| Hook log | `~/.claude/hooks/slack-done.log` | written by the hook |
| Config | `~/.claude/agent-workflow-notifier.env` | 600 |
| Token cache | `~/.claude/agent-workflow-notifier.token` | 600, written by the hook |
| Slack CLI project | `~/.claude/agent-workflow-notifier/` | holds the app manifest |
| Hook block | `<repo>/.claude/settings.local.json` or `~/.claude/settings.json` | merged, never replaced |

The hook reads the hook payload (the JSON Claude Code pipes to it) on stdin, builds one Slack message, posts it, and always exits 0 so a Slack outage never blocks the agent. It logs one line per run to the hook log and never logs a token.

## Installing

No installer script exists. The agent runs these steps directly; each one is idempotent, so repeating them on a machine that already has the notifier changes nothing.

1. Copy `assets/slack-done.sh` to `~/.claude/hooks/slack-done.sh` and set `chmod 755`. When a file of that name already exists and differs from this skill's copy, show the user a diff summary and ask before replacing it; the difference is usually a local edit the user wants to keep.
2. Create the Slack app. Make `~/.claude/agent-workflow-notifier/` and put `assets/manifest.json` there as `manifest.json`, `assets/get-manifest.sh` as `get-manifest.sh` (`chmod 755`), and `assets/slack-hooks.json` as `.slack/hooks.json`. From that directory run `slack manifest validate -s`, then `slack app install -s -E deployed -w <TEAM_ID>` (`slack auth list` shows the team id). Record the App ID and Team ID the install prints; they also land in `.slack/apps.json`. Re-run the install after any manifest change, then delete the token cache (see Tokens).
3. Write the config. Copy `assets/agent-workflow-notifier.env.template` to `~/.claude/agent-workflow-notifier.env`, set `chmod 600`, and fill `SLACK_NOTIFIER_USER` with the `User ID` line of `slack auth list`, plus the app and team ids from step 2. The optional keys stay commented out unless the user wants them.
4. Wire the hooks into a repo or into the user settings; see Wiring below.
5. Test: a dry run, one real send, then read the log; see Testing below.

Claude Code loads hooks when a session starts, so an agent that was already running needs a restart before it sends anything.

## Config reference

The hook reads `~/.claude/agent-workflow-notifier.env` first, then `<cwd>/.env`, where `<cwd>` is the directory the session runs in. It greps `SLACK_NOTIFIER_*` lines and never sources either file, so a key in the repo's `.env` overrides the global one and nothing else in `.env` is read. The agent itself never reads `.env`, since that file holds secrets that do not belong in a transcript; only the hook reads it, at run time.

| Key | Required | Meaning |
|---|---|---|
| `SLACK_NOTIFIER_USER` | yes | Slack user id to DM and @-mention |
| `SLACK_NOTIFIER_APP_ID` | yes | App id from `slack app install` |
| `SLACK_NOTIFIER_TEAM_ID` | yes | Team id from `slack app install` |
| `SLACK_NOTIFIER_PROJECT` | no | Slack CLI project dir, default `~/.claude/agent-workflow-notifier` |
| `SLACK_NOTIFIER_CHANNEL` | no | Channel id to post to instead of a DM |
| `SLACK_NOTIFIER_TOKEN` | no | Bot token; skips the cache and the CLI entirely |
| `SLACK_NOTIFIER_TOKEN_FILE` | no | Token cache path, default `~/.claude/agent-workflow-notifier.token` |
| `SLACK_NOTIFIER_EVENTS` | no | Comma-separated hook events to send; others are dropped |
| `SLACK_NOTIFIER_MIN_SECONDS` | no | Minimum turn length before a send, default `120`; `0` sends every time |
| `SLACK_NOTIFIER_CLI` | no | Path to the `slack` binary when it is not on `PATH` |

Without `SLACK_NOTIFIER_CLI` the hook looks on `PATH`, then `~/.local/bin/slack`, then `~/.slack/bin/slack`. `SLACK_NOTIFIER_DRY_RUN=1` in the environment prints the message to stdout and exits before any network call, including the token fetch.

The duration gate applies to every event. The hook reads the timestamp of the last user prompt in `transcript_path`, and when fewer than `SLACK_NOTIFIER_MIN_SECONDS` have passed it logs `skipped <event>: turn took Ns` and exits, on the assumption that the user is still at the screen after a short turn. A payload with no transcript is sent every time.

## What the message says

One message per event, in mrkdwn (Slack's markdown dialect):

```
*✅ Finished* · `repo/worktree (branch)` <@USER_ID>
*Agent:* claude · *Session:* 1a2b3c4d
*Task:* first user prompt of the session, 200 chars
*Now:* last assistant message or the pending question, 400 chars
```

The repo name comes from `git rev-parse --git-common-dir` on the session's `cwd` (the bare clone directory for a worktree, the checkout for a plain repo), the branch from `git symbolic-ref`, the task from the first user prompt in `transcript_path`, and the agent from the payload's `agent_type`, else `$CLAUDE_AGENT_NAME`, else `claude`.

Which title the hook picks, once the duration gate has passed:

- `Stop`: `✅ Finished`, unless the last paragraph of `last_assistant_message` contains a `?` or one of `let me know`, `should i`, `do you want`, `would you like`, `which one`, `which option`, `your call`, `confirm`, `choose`, `pick one`; then `❓ Needs your input`. This is a text heuristic on the final paragraph, so a closing offer with a question mark reads as a question.
- `Notification` with `notification_type` `permission_prompt`: `🔐 Needs your input: permission`. `elicitation_dialog`: `❓ Needs your input`. `idle_prompt`: dropped.
- `PreToolUse` on `AskUserQuestion`: `❓ Needs your input: question`, with each question and its option labels.
- `SubagentStop`: `🤖 Subagent finished`. Not wired by default; see Tuning.
- `SessionEnd`: dropped.

## Tokens

The hook needs a bot token (`xoxb-…`) to post. It resolves one in this order and posts with curl as soon as it has one:

1. `SLACK_NOTIFIER_TOKEN` from the config files, when set.
2. The token cache file, when present.
3. A one-time fetch. The hook reads the CLI's user session token and its expiry from `~/.slack/credentials.json` under the team id, and while the session is still valid it calls `apps.developerInstall` with `{"app_id": "<APP_ID>"}`, writes the returned bot token to the cache with `umask 077`, and logs `cached bot token`.
4. When the session has expired or the fetch fails, the hook sends that one message through `slack api chat.postMessage --app <APP_ID> -w <TEAM_ID>` from the project dir. The CLI refreshes its session as a side effect, so the next run fills the cache.

On a Slack reply of `invalid_auth`, `token_revoked`, or `account_inactive`, the hook deletes the cache and retries once through steps 3 and 4.

Facts that matter when the notifier stops working:

- The CLI session token expires 12 hours after login; Slack fixes that lifetime. The CLI refreshes it with its stored refresh token on the next command it runs, which is why step 4 keeps working across days. If the refresh token is revoked, run `slack auth login` again.
- The bot token does not expire because the manifest sets `token_rotation_enabled: false`. It changes only when the app is reinstalled, so after `slack app install` (for example after a scope change) delete the cache file.
- Deleting the cache file forces a refetch on the next send.
- The manifest keeps `features.app_home.messages_tab_enabled: true`. Without it the DM fails with `messages_tab_disabled`.
- `slack api` sends no auth outside a project directory (`not_authed`), so every CLI call runs from the project dir or passes `--token`.

Leave the fetch to the hook. `~/.slack/credentials.json` holds the user's session token, so reading it from an agent would copy that token into the transcript, and an agent in auto mode is blocked from reading it anyway; the hook runs as a process the user owns, outside the transcript. When the user wants the bot token pinned in `SLACK_NOTIFIER_TOKEN` instead, they run one of these themselves and paste the result:

- `slack app settings` from the project dir, then OAuth & Permissions, "Bot User OAuth Token".
- `https://api.slack.com/apps/<APP_ID>/oauth` in a browser.
- The same call the hook makes:

  ```sh
  curl -sS -H "Authorization: Bearer $(jq -r '.<TEAM_ID>.token' ~/.slack/credentials.json)" \
    -H 'Content-Type: application/json' -d '{"app_id":"<APP_ID>"}' \
    https://slack.com/api/apps.developerInstall | jq -r '.api_access_tokens.bot'
  ```

## Wiring

`assets/settings.hooks.json` is the hook block: `Stop` with no matcher, `Notification` with matcher `permission_prompt|elicitation_dialog`, and `PreToolUse` with matcher `AskUserQuestion`, each running `~/.claude/hooks/slack-done.sh` with `async: true` so the agent never waits on Slack. Merge it; never replace a settings file the user already has, because `permissions.allow` lives in the same file.

The merge is a jq deep merge: objects merge key by key, arrays keep the destination's items and append new ones, other values come from the source. Refuse to write when the destination is not valid JSON.

```sh
dest=<path to settings file>; src=assets/settings.hooks.json
if [[ -e "$dest" ]]; then
  jq -e . "$dest" >/dev/null && jq -s '
    def merge($a; $b):
      if ($a|type)=="object" and ($b|type)=="object" then
        reduce ($b|keys_unsorted[]) as $k ($a; .[$k] = merge($a[$k]; $b[$k]))
      elif ($a|type)=="array" and ($b|type)=="array" then $a + ($b - $a)
      else $b end;
    merge(.[0]; .[1])' "$dest" "$src" > "$dest.tmp" && mv "$dest.tmp" "$dest"
else
  mkdir -p "$(dirname "$dest")" && cp "$src" "$dest"
fi
```

Where the block goes depends on the repo:

- **A bare clone set up with the `worktrees` skill.** Copy `assets/settings.hooks.json` to `<root>/.claude/settings.local.json` when that file is missing (ask before touching an existing one). Append the line `.claude/settings.local.json merge-json` to `<root>/.worktree-copy` when it is absent. Run `./warm-worktrees.sh` from `<root>`; its `merge-json` mode performs the same merge into every worktree and leaves each worktree's own permission list intact. New worktrees get the block on their first warm.
- **A plain checkout.** Run the merge above with `dest=<repo>/.claude/settings.local.json`.
- **Every project on the machine.** Run the merge above with `dest=~/.claude/settings.json`. Then skip the per-repo wiring, or the hook fires twice.

Keep `.claude/settings.local.json` git-ignored: it carries this machine's permission grants and a home-relative hook path, neither of which belongs in the remote. Claude Code does not ignore it for you, so check `git check-ignore -v .claude/settings.local.json` in the repo. When it is not ignored, append `.claude/settings.local.json` to the repo's own `info/exclude` (`<repo>/.git/info/exclude`, or `<root>/info/exclude` in a bare clone), which stays local to that repo. Mention that `~/.config/git/ignore` with the line `**/.claude/settings.local.json` would cover every repo at once, but do not create or edit that global file unless the user asks; it changes git behavior for everything on the machine.

## Testing

Run these after any change to the hook, the config, or the wiring:

1. Dry run. Pipe a fake `Stop` payload into the hook; it prints the message and exits before any network call:

   ```sh
   printf '{"hook_event_name":"Stop","session_id":"deadbeef","cwd":"%s","last_assistant_message":"Done.\\n\\nAll tests pass."}' "$PWD" \
     | SLACK_NOTIFIER_DRY_RUN=1 ~/.claude/hooks/slack-done.sh
   ```

   The first line must start with `*✅ Finished*`. Change the message to end in a question and it must start with `*❓ Needs your input*`. The fake payload carries no `transcript_path`, so the duration gate does not apply.
2. Real send. Drop `SLACK_NOTIFIER_DRY_RUN=1` and run the same command. The DM arrives within a few seconds, and `~/.claude/hooks/slack-done.log` gains `cached bot token` (first run only) and `sent Stop -> <USER_ID> (...)`.
3. Cache check. `ls -l ~/.claude/agent-workflow-notifier.token` shows mode `-rw-------`. A second send logs only the `sent` line.
4. Wiring check. Start a new Claude Code session in the wired repo and give it a task that runs longer than `SLACK_NOTIFIER_MIN_SECONDS`, or set `SLACK_NOTIFIER_MIN_SECONDS=0` in the config for the test. Confirm the `✅ Finished` DM, then restore the config.

A `FAILED` line in the log carries Slack's error string. `messages_tab_disabled` means the manifest lost its `app_home` block; `not_in_channel` means `SLACK_NOTIFIER_CHANNEL` names a channel the bot was not invited to; `not_authed` means the CLI ran outside the project dir.

## Tuning

- **Fewer messages.** Set `SLACK_NOTIFIER_EVENTS=Notification,PreToolUse` to hear only when the agent is blocked, or drop the `Stop` entry from the hook block.
- **Shorter or longer turns.** Raise `SLACK_NOTIFIER_MIN_SECONDS` to hear only about long runs, or set it to `0` to hear about every turn.
- **Subagents.** Add a `SubagentStop` entry to the hook block with the same command; the hook already formats it.
- **A channel instead of a DM.** Set `SLACK_NOTIFIER_CHANNEL` to a channel id and invite the bot to that channel.
- **Per-repo overrides.** Put any `SLACK_NOTIFIER_*` key in the repo's `.env`; the hook reads it after the global file.
- **No CLI on the machine.** Set `SLACK_NOTIFIER_TOKEN` in the config; the hook then needs only `curl` and `jq`.
