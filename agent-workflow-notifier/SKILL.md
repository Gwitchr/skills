---
name: agent-workflow-notifier
description: Install, wire, or repair a Slack direct-message notifier for Claude Code, so the owner hears on Slack when an agent finishes a long turn, waits on a permission prompt, or asks a question. Setup is a short idempotent sequence the agent runs directly with the slack CLI, one hook script, one config file, and one hook block merged into a repo's .claude/settings.local.json or the user settings. Use this whenever the user mentions Slack together with Claude Code hooks, wants to be pinged, DMed, or notified when an agent is done or stuck, asks why a notification did not arrive, or says "agent-workflow-notifier", even when they do not say "hook" or "notifier".
---

# agent-workflow-notifier

This skill installs a hook that sends the owner a Slack direct message (DM) when a Claude Code agent stops, needs a permission decision, or asks a question, and only when the turn ran long enough that the owner has likely walked away. A finished turn arrives as a session title, 2 to 4 bullets about what the agent did, and a one-line footer of counts. Everything lives under `~/.claude` (one script, one config file, one Slack CLI project, one token cache) plus a hook block per repo. The skill is generic: no user id, app id, or team id is baked into any asset.

TRIGGER when: the user wants Slack messages from Claude Code, asks to install or repair the notifier, wants a hook that reports when an agent finishes or waits for input, or names this skill.

> **Stack assumed.** The `slack` CLI 4.x (Slack's developer command-line tool), logged in with `slack auth login`; `jq` 1.6 or newer; `curl`; git; bash 3.2 or newer (macOS ships 3.2, Linux usually ships 5, the hook runs the same on either). Claude Code with hook support for `Stop`, `Notification`, and `PreToolUse`. The hold on background tasks needs a Claude Code that sends `background_tasks` in the `Stop` payload, as 2.1.285 does. Two optional pieces: the `claude` CLI on `PATH` writes the summary bullets, and `perl` puts a time limit around that run. Without `claude` the body is the first sentence of the final message; without `perl` the summarizer runs untimed.

> **Notation.** `<APP_ID>`, `<TEAM_ID>`, and `<USER_ID>` are the ids the install steps produce. `<root>` is the root of a bare clone (a git clone with no working tree of its own) when the repo uses the `worktrees` skill; `<repo>` is any ordinary checkout.

> **Precedence.** Project conventions in `AGENTS.md` or `CLAUDE.md` win. If a project already documents its own notification hook, follow that instead.

## What gets installed

| Piece | Path | Mode |
|---|---|---|
| Hook script | `~/.claude/hooks/slack-done.sh` | 755 |
| Hook log | `~/.claude/hooks/slack-done.log` | written by the hook |
| Hook state | `~/.claude/hooks/slack-done.state/` | files 600, written by the hook |
| Config | `~/.claude/agent-workflow-notifier.env` | 600 |
| Token cache | `~/.claude/agent-workflow-notifier.token` | 600, written by the hook |
| Slack CLI project | `~/.claude/agent-workflow-notifier/` | holds the app manifest |
| Hook block | `<repo>/.claude/settings.local.json` or `~/.claude/settings.json` | merged, never replaced |

The hook reads the hook payload (the JSON Claude Code pipes to it) on stdin, builds one Slack message, posts it, and always exits 0 so a Slack outage never blocks the agent. It logs one line per run to the hook log, `sent <event> -> <channel> (<where>) title="…"`, with `ask=<rule> bg=<count>` on `Stop`, `msg="<first 80 chars>"` on `Notification`, and `session=<8 chars>` on every event, plus one line naming the summary path it took. A dry run logs the same line with `dry-run` in place of `sent`. The log holds no token and no assistant text; a `Notification` line holds the first 80 characters of the notification message. The headless `claude` run that writes the bullets carries `SLACK_NOTIFIER_INNER=1`, and the hook exits on that variable, so the run cannot trigger the hook again.

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
| `SLACK_NOTIFIER_MIN_SECONDS` | no | Seconds that must pass before a send, since the last human prompt for `Stop` and since the last user entry for `SubagentStop`; default `120`; `0` turns both clocks off |
| `SLACK_NOTIFIER_HOLD_TYPES` | no | Comma-separated background task types that hold a `Stop`, default `subagent,workflow` |
| `SLACK_NOTIFIER_STATE_DIR` | no | Per-session state dir, default `~/.claude/hooks/slack-done.state` |
| `SLACK_NOTIFIER_CLI` | no | Path to the `slack` binary when it is not on `PATH` |
| `SLACK_NOTIFIER_SUMMARY` | no | `claude` writes the summary bullets, `off` falls back to the final message; default `claude` |
| `SLACK_NOTIFIER_SUMMARY_MODEL` | no | Model that writes the bullets, default `haiku` |
| `SLACK_NOTIFIER_SUMMARY_TIMEOUT` | no | Seconds the summarizer may take, default `45` |
| `SLACK_NOTIFIER_CLAUDE` | no | Path to the `claude` binary when it is not on `PATH` |

Without `SLACK_NOTIFIER_CLI` the hook looks on `PATH`, then `~/.local/bin/slack`, then `~/.slack/bin/slack`. Without `SLACK_NOTIFIER_CLAUDE` it looks on `PATH`, then `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude`, `~/.claude/local/claude`. A key that appears in either config file wins over the same variable set in the hook's environment, so an override on the command line works only for keys the files leave out.

`SLACK_NOTIFIER_DRY_RUN=1` in the environment prints the message to stdout and exits before any Slack call or token fetch. It still runs the summarizer, since that is what the preview is for; add `SLACK_NOTIFIER_SUMMARY=off` for a dry run that touches no network at all.

The duration gate applies to `Stop` and `SubagentStop`. One pass over `transcript_path` gives two clocks: the last human prompt, a `user` entry that is not meta, has text, has `origin.kind` `human` or no `origin`, and does not start with `<task-notification>`; and the last user entry of any origin, which includes a completion notice. A `Stop` is skipped when fewer than `SLACK_NOTIFIER_MIN_SECONDS` have passed since the human prompt, a `SubagentStop` when fewer have passed since the last user entry of any origin; the hook logs `skipped <event>: turn took Ns` and exits. Permission prompts and questions go out at any age. A payload with no transcript, or `SLACK_NOTIFIER_MIN_SECONDS=0`, skips both clocks.

A `Stop` is held, with the log line `held Stop: N background task(s) running (<types>)`, while the payload's `background_tasks` holds a `running` or `pending` task whose `type` is in `SLACK_NOTIFIER_HOLD_TYPES`, unless the final message asks for input by the title rule below. The hold applies with no transcript and with `SLACK_NOTIFIER_MIN_SECONDS=0`. Each task is `{"id","type","status","description"}`, plus `command` on a `shell` task and `agent_type` on a `subagent` task; the types are `subagent`, `workflow`, `shell`, `monitor`, `MCP task`, `teammate`, `dream`, `auto-mode scan`, and `cloud session`. A Claude Code that sends no `background_tasks` holds nothing.

A `Stop` whose last user entry, a completion notice, is younger than `SLACK_NOTIFIER_MIN_SECONDS` is skipped when `<session_id>.announced` is at or after the human prompt; the hook logs `skipped Stop: already announced for this prompt` and exits. It writes `.announced` after a `Stop` goes out while no held-type task runs.

`SLACK_NOTIFIER_STATE_DIR` holds one epoch per file at mode 600: `<session_id>.announced` and `<session_id>.question`. The hook prunes state files older than 7 days on each write, and every read and write fails soft. A session id that is empty or holds a character outside letters, digits, `_`, and `-` turns state off. A dry run writes state too.

## What the message says

One message per event, in mrkdwn (Slack's markdown dialect). `Stop` and `SubagentStop` carry summary bullets:

```
*✅ Finished* · `repo/worktree (branch)` <@USER_ID>
_Landing page update with aurora background_
• Rebuilt the hero section with an aurora background
• Pending: the mobile breakpoint still overflows
`claude · 1a2b3c4d · 23 min · 12 commands · 3 files edited · 4 subagents`
```

A permission prompt or a question carries the pending text instead, and skips the summarizer so it arrives at once:

```
*🔐 Needs your input: permission* · `repo/worktree (branch)` <@USER_ID>
_Landing page update with aurora background_
Claude needs your permission to run: rm -rf dist
`claude · 1a2b3c4d`
```

The repo name comes from `git rev-parse --git-common-dir` on the session's `cwd` (the bare clone directory for a worktree, the checkout for a plain repo), the branch from `git symbolic-ref`, and the agent from the payload's `agent_type`, else `$CLAUDE_AGENT_NAME`, else `claude`.

The italic line is the session title: the last `ai-title` entry of `transcript_path`, else the first user prompt of the session, 100 chars. A payload with no transcript drops the line.

The footer is one code span: the agent, the first 8 characters of the session id, then on `Stop` and `SubagentStop` the minutes since the last user prompt and what the turn touched. Zero counts and an unknown elapsed time drop out, so a quiet turn shows the agent and the session alone.

Counts, action lines, and the title come from one streaming `jq` pass over `transcript_path` that keeps the entries after the last real user prompt: a `user` entry that is not meta and whose text is non-empty and does not open with `<`. Commands are `Bash` calls, files edited are the distinct `file_path` values of `Edit`, `Write`, and `NotebookEdit`, and subagents are `Agent` and `Task` calls. The pass also collects up to 40 action lines: the `description` of each `Bash`, `Agent`, and `Task` call, `edited <basename>` for each `Edit` and `Write`, and `skill <name>` for each `Skill`.

A final message of 240 characters or fewer becomes the body as one line. A longer one goes to the summarizer, which reads the title, the action lines, and the first 3000 characters of that message on stdin: `claude -p --model "$SLACK_NOTIFIER_SUMMARY_MODEL" --tools "" --no-session-persistence --strict-mcp-config --settings '{"disableAllHooks":true}'` with a system prompt asking for 2 to 4 bullets, run from `SLACK_NOTIFIER_PROJECT` so no repo settings load, under `SLACK_NOTIFIER_INNER=1` and a `perl` alarm of `SLACK_NOTIFIER_SUMMARY_TIMEOUT` seconds. The hook keeps at most 4 answer lines that open with `•`, 140 characters each.

Bullets are past tense and say what was done. One opens with `Pending:` when something is unfinished, failed, or blocked, and the last opens with `Asks:` when the final message asks the user something.

When the summarizer is off, missing, slow, or answers without a bullet, the body is the first sentence of the final message's first paragraph, 200 chars, plus an `Asks:` line when the message asks for input: the last question line under rule `qmark`, the last paragraph under rule `phrase`, taken from the stripped text, 200 chars. Either way the hook logs the path it took, `summary: claude 17s`, `summary: fallback (timeout)`, or `summary: short message`, and never the text.

Which title the hook picks, once the duration gate has passed:

- `Stop`: `❓ Needs your input` when the message asks for input, otherwise `✅ Finished`. The check reads `last_assistant_message` with fenced code, inline code spans, URLs (`http`, `https`, `mailto`), and markdown heading lines removed. The message asks when any line has a `?` followed by whitespace, the end of the line, or one of `*`, `_`, `)`, `]` (rule `qmark`), or when the last paragraph holds one of these as whole words: `let me know`, `should i`, `do you want`, `would you like`, `which one`, `which option`, `your call`, `pick one` (rule `phrase:<phrase>`). A `?` followed by a quote character does not count.
- `Notification` with `notification_type` `permission_prompt`: `🔐 Needs your input: permission`, or dropped with `skipped Notification: duplicate of the question ping` when its message contains `AskUserQuestion` or `<session_id>.question` is at most 10 s old. `elicitation_dialog`: `❓ Needs your input`. `idle_prompt`: dropped.
- `PreToolUse` on `AskUserQuestion`: `❓ Needs your input: question`, with each question and its option labels. The hook writes `<session_id>.question` before it posts.
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
     | SLACK_NOTIFIER_DRY_RUN=1 SLACK_NOTIFIER_SUMMARY=off ~/.claude/hooks/slack-done.sh
   ```

   The first line must start with `*✅ Finished*`. Change the message to end in a question and it must start with `*❓ Needs your input*`. `SLACK_NOTIFIER_SUMMARY=off` keeps the run offline, and the fake payload carries no `transcript_path`, so there is no title line, no counts, and no duration gate. The run logs a `dry-run Stop -> …` line and writes `deadbeef.announced` to the state dir.

   Then check the hold. The same payload with one running `subagent` in `background_tasks` prints nothing and logs `held Stop: 1 background task(s) running (subagent)`:

   ```sh
   printf '{"hook_event_name":"Stop","session_id":"deadbeef","cwd":"%s","last_assistant_message":"Done.\\n\\nAll tests pass.","background_tasks":[{"id":"b1","type":"subagent","status":"running","description":"audit"}]}' "$PWD" \
     | SLACK_NOTIFIER_DRY_RUN=1 SLACK_NOTIFIER_SUMMARY=off ~/.claude/hooks/slack-done.sh
   ```

   Then preview the bullets against a real transcript, which is where the title, the counts, and the summarizer input live. Pick any session file under `~/.claude/projects/` and write a final message of a few paragraphs:

   ```sh
   TR=~/.claude/projects/<project>/<session>.jsonl
   jq -cn --arg tr "$TR" --arg cwd "$PWD" --arg m "$(cat /tmp/final-message.txt)" \
     '{hook_event_name:"Stop",session_id:"deadbeef",cwd:$cwd,transcript_path:$tr,last_assistant_message:$m}' \
     | SLACK_NOTIFIER_DRY_RUN=1 SLACK_NOTIFIER_MIN_SECONDS=0 ~/.claude/hooks/slack-done.sh
   ```

   It takes as long as the summarizer needs, up to `SLACK_NOTIFIER_SUMMARY_TIMEOUT`, and prints an italic title, 2 to 4 bullets, and a footer with counts. `SLACK_NOTIFIER_MIN_SECONDS=0` only takes effect when that key is absent from the config files.
2. Real send. Drop `SLACK_NOTIFIER_DRY_RUN=1` from the first command and run it. The DM arrives within a few seconds, and `~/.claude/hooks/slack-done.log` gains `cached bot token` (first run only) and `sent Stop -> <USER_ID> (<where>) title="✅ Finished" ask=none bg=0 session=deadbeef`.
3. Cache check. `ls -l ~/.claude/agent-workflow-notifier.token` shows mode `-rw-------`. A second send logs only the `sent` line.
4. Wiring check. Start a new Claude Code session in the wired repo and give it a task that runs longer than `SLACK_NOTIFIER_MIN_SECONDS`, or set `SLACK_NOTIFIER_MIN_SECONDS=0` in the config for the test. Check that the `✅ Finished` DM arrives, then restore the config.

A `FAILED` line in the log carries Slack's error string. `messages_tab_disabled` means the manifest lost its `app_home` block; `not_in_channel` means `SLACK_NOTIFIER_CHANNEL` names a channel the bot was not invited to; `not_authed` means the CLI ran outside the project dir.

## Tuning

- **Fewer messages.** Set `SLACK_NOTIFIER_EVENTS=Notification,PreToolUse` to hear only when the agent is blocked, or drop the `Stop` entry from the hook block.
- **Shorter or longer turns.** Raise `SLACK_NOTIFIER_MIN_SECONDS` to hear only about long runs, or set it to `0` to turn both clocks off.
- **Background tasks.** `SLACK_NOTIFIER_HOLD_TYPES` names the task types that hold a `Stop`. Add `shell` to also hold on background commands, which includes a dev server.
- **Plainer or cheaper summaries.** Set `SLACK_NOTIFIER_SUMMARY=off` to drop the bullets for the first sentence of the final message, or point `SLACK_NOTIFIER_SUMMARY_MODEL` at another model. Raise `SLACK_NOTIFIER_SUMMARY_TIMEOUT` when the model runs past 45 seconds.
- **Subagents.** Add a `SubagentStop` entry to the hook block with the same command; the hook already formats it.
- **A channel instead of a DM.** Set `SLACK_NOTIFIER_CHANNEL` to a channel id and invite the bot to that channel.
- **Per-repo overrides.** Put any `SLACK_NOTIFIER_*` key in the repo's `.env`; the hook reads it after the global file.
- **No CLI on the machine.** Set `SLACK_NOTIFIER_TOKEN` in the config; the hook then needs only `curl` and `jq`.
