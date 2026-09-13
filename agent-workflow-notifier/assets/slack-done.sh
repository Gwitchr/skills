#!/usr/bin/env bash
# Claude Code hook: DM the owner on Slack when an agent finishes (✅) or needs input (❓ / 🔐).
# Reads the hook payload on stdin. Config: ~/.claude/agent-workflow-notifier.env, then <cwd>/.env.
# Bot token: SLACK_NOTIFIER_TOKEN, else the cache file SLACK_NOTIFIER_TOKEN_FILE, else fetched once
# through apps.developerInstall with the Slack CLI session, else sent through the CLI.
# Sends only when the turn ran at least SLACK_NOTIFIER_MIN_SECONDS (default 120) since the last user prompt.
set -u

LOG="$HOME/.claude/hooks/slack-done.log"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }

payload="$(cat)"
[[ -n "$payload" ]] || exit 0
command -v jq >/dev/null 2>&1 || { log "jq not found; skipping"; exit 0; }

jqget() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }

event="$(jqget '.hook_event_name')"
cwd="$(jqget '.cwd')"; cwd="${cwd:-$PWD}"
session="$(jqget '.session_id')"
transcript="$(jqget '.transcript_path')"

# ---------- config: global file first, then the worktree's .env ----------
load_kv() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#export }"
    [[ "$line" == SLACK_NOTIFIER_*=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "$key" =~ ^SLACK_NOTIFIER_[A-Z0-9_]+$ ]] || continue
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    printf -v "$key" '%s' "$val"
  done <"$file"
}
load_kv "$HOME/.claude/agent-workflow-notifier.env"
load_kv "$cwd/.env"

: "${SLACK_NOTIFIER_USER:=}"
: "${SLACK_NOTIFIER_CHANNEL:=}"
: "${SLACK_NOTIFIER_TOKEN:=}"
: "${SLACK_NOTIFIER_APP_ID:=}"
: "${SLACK_NOTIFIER_TEAM_ID:=}"
: "${SLACK_NOTIFIER_PROJECT:=$HOME/.claude/agent-workflow-notifier}"
: "${SLACK_NOTIFIER_EVENTS:=}"
: "${SLACK_NOTIFIER_CLI:=}"
: "${SLACK_NOTIFIER_TOKEN_FILE:=$HOME/.claude/agent-workflow-notifier.token}"
: "${SLACK_NOTIFIER_MIN_SECONDS:=120}"
SLACK_NOTIFIER_PROJECT="${SLACK_NOTIFIER_PROJECT/#\~/$HOME}"
SLACK_NOTIFIER_TOKEN_FILE="${SLACK_NOTIFIER_TOKEN_FILE/#\~/$HOME}"

if [[ -n "$SLACK_NOTIFIER_EVENTS" && ",$SLACK_NOTIFIER_EVENTS," != *",$event,"* ]]; then
  exit 0
fi
[[ -n "$SLACK_NOTIFIER_USER" ]] || { log "SLACK_NOTIFIER_USER unset; skipping"; exit 0; }

# ---------- duration gate: a short turn means the user is still at the screen ----------
# Elapsed time is measured from the last user prompt in the transcript. No transcript,
# or SLACK_NOTIFIER_MIN_SECONDS=0, sends every time.
if [[ "$SLACK_NOTIFIER_MIN_SECONDS" =~ ^[0-9]+$ && "$SLACK_NOTIFIER_MIN_SECONDS" -gt 0 && -n "$transcript" && -f "$transcript" ]]; then
  started="$(jq -rR '
    fromjson? | select(.type=="user") | select(.isMeta != true)
    | select((.message.content | if type=="string" then . elif type=="array" then (map(select(.type=="text") | .text) | join("")) else "" end) | length > 0)
    | .timestamp // empty
  ' "$transcript" 2>/dev/null | tail -n 1)"
  start_s="$(printf '%s' "$started" | jq -rR 'select(length > 0) | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty' 2>/dev/null)"
  if [[ "$start_s" =~ ^[0-9]+$ ]]; then
    elapsed=$(( $(date +%s) - start_s ))
    if [[ $elapsed -lt $SLACK_NOTIFIER_MIN_SECONDS ]]; then
      log "skipped $event: turn took ${elapsed}s (< ${SLACK_NOTIFIER_MIN_SECONDS}s)"
      exit 0
    fi
  fi
fi

# ---------- context: repo / worktree / branch / agent / task ----------
worktree="$(basename "$cwd")"
repo=""; branch=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)"
  common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common" ]]; then
    repo="$(basename "$common")"
    [[ "$repo" == ".git" ]] && repo="$(basename "$(dirname "$common")")"
  fi
fi
where="$worktree"
[[ -n "$repo" && "$repo" != "$worktree" ]] && where="$repo/$worktree"
[[ -n "$branch" ]] && where="$where ($branch)"

agent="$(jqget '.agent_type')"
agent="${agent:-${CLAUDE_AGENT_NAME:-claude}}"

task=""
if [[ -n "$transcript" && -f "$transcript" ]]; then
  task="$(jq -rR '
    fromjson? | select(.type=="user") | select(.isMeta != true)
    | .message.content
    | if type=="string" then . elif type=="array" then (map(select(.type=="text") | .text) | join(" ")) else empty end
    | gsub("\\s+"; " ") | select(length>0) | select(startswith("<") | not)
  ' "$transcript" 2>/dev/null | head -n 1)"
fi

trunc() { local s="$1" n="$2"; if [[ ${#s} -gt $n ]]; then printf '%s…' "${s:0:$n}"; else printf '%s' "$s"; fi; }

# A Stop is "needs input" when the last paragraph of the final message asks
# something; otherwise the agent is done with the task.
asks_for_input() {
  local msg="$1" last
  last="$(printf '%s\n' "$msg" | awk 'BEGIN{RS=""} {p=$0} END{print p}')"
  [[ "$last" == *\?* ]] && return 0
  printf '%s' "$last" | grep -qiE 'let me know|should i|do you want|would you like|which (one|option)|your call|confirm|choose|pick one' && return 0
  return 1
}

case "$event" in
  Stop)
    detail="$(jqget '.last_assistant_message')"
    if asks_for_input "$detail"; then
      title="❓ Needs your input"
    else
      title="✅ Finished"
    fi
    detail="${detail:-turn ended}"
    ;;
  Notification)
    ntype="$(jqget '.notification_type')"
    case "$ntype" in
      permission_prompt)  title="🔐 Needs your input: permission" ;;
      elicitation_dialog) title="❓ Needs your input" ;;
      idle_prompt)        exit 0 ;;
      *)                  title="🔔 ${ntype:-notification}" ;;
    esac
    detail="$(jqget '.message')"
    ;;
  SessionEnd)
    exit 0
    ;;
  PreToolUse)
    tool="$(jqget '.tool_name')"
    title="❓ Needs your input: question"
    [[ "$tool" != "AskUserQuestion" ]] && title="🔔 $tool"
    detail="$(printf '%s' "$payload" | jq -r '
      [.tool_input.questions[]? | .question + (if (.options|length)>0 then " [" + ((.options|map(.label))|join(" / ")) + "]" else "" end)]
      | join(" | ")' 2>/dev/null)"
    [[ -z "$detail" ]] && detail="$(jqget '.tool_input.description')"
    ;;
  SubagentStop)
    title="🤖 Subagent finished"
    detail="$(jqget '.last_assistant_message')"
    ;;
  *)
    title="ℹ️ ${event:-hook}"
    detail="$(jqget '.message')"
    ;;
esac

task="$(trunc "$(printf '%s' "$task" | tr '\n' ' ')" 200)"
detail="$(trunc "$(printf '%s' "$detail" | tr '\n' ' ' | sed -E 's/  +/ /g')" 400)"

text="$(jq -rn \
  --arg user "$SLACK_NOTIFIER_USER" --arg title "$title" --arg where "$where" \
  --arg agent "$agent" --arg session "${session:0:8}" --arg task "$task" --arg detail "$detail" '
  def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
  [ "*\($title)* · `\($where|esc)` <@\($user)>",
    "*Agent:* \($agent|esc)" + (if $session != "" then " · *Session:* \($session)" else "" end),
    (if $task != "" then "*Task:* \($task|esc)" else empty end),
    (if $detail != "" then "*Now:* \($detail|esc)" else empty end)
  ] | join("\n")')"

channel="${SLACK_NOTIFIER_CHANNEL:-$SLACK_NOTIFIER_USER}"
body="$(jq -cn --arg ch "$channel" --arg text "$text" '{channel:$ch, text:$text, mrkdwn:true, unfurl_links:false, unfurl_media:false}')"

if [[ "${SLACK_NOTIFIER_DRY_RUN:-}" == "1" ]]; then printf '%s\n' "$text"; exit 0; fi

post_curl() {
  curl -sS -m 15 -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json; charset=utf-8' --data "$body" \
    https://slack.com/api/chat.postMessage 2>&1
}

# Fallback: the Slack CLI fetches the bot token itself from the project dir and
# refreshes its own session token on the way, so the next run can fill the cache.
post_cli() {
  local cli="$SLACK_NOTIFIER_CLI"
  [[ -z "$cli" ]] && cli="$(command -v slack 2>/dev/null || true)"
  [[ -z "$cli" && -x "$HOME/.local/bin/slack" ]] && cli="$HOME/.local/bin/slack"
  [[ -z "$cli" && -x "$HOME/.slack/bin/slack" ]] && cli="$HOME/.slack/bin/slack"
  [[ -n "$cli" ]] || { printf 'slack CLI not found and no bot token'; return 0; }
  [[ -n "$SLACK_NOTIFIER_APP_ID" && -n "$SLACK_NOTIFIER_TEAM_ID" ]] || { printf 'SLACK_NOTIFIER_APP_ID/TEAM_ID unset'; return 0; }
  (cd "$SLACK_NOTIFIER_PROJECT" 2>/dev/null && "$cli" api chat.postMessage -s --app "$SLACK_NOTIFIER_APP_ID" -w "$SLACK_NOTIFIER_TEAM_ID" --json "$body" 2>&1) || true
}

cached_token() {
  [[ -f "$SLACK_NOTIFIER_TOKEN_FILE" ]] || return 0
  head -n 1 "$SLACK_NOTIFIER_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]'
}

# Fetch the bot token once with the CLI's user session token, while that session
# is still valid, and cache it. Prints nothing when the session is expired or the
# call fails; the caller then falls back to the CLI.
fetch_bot_token() {
  local creds="$HOME/.slack/credentials.json" session exp now resp token
  [[ -f "$creds" && -n "$SLACK_NOTIFIER_APP_ID" && -n "$SLACK_NOTIFIER_TEAM_ID" ]] || return 0
  session="$(jq -r --arg t "$SLACK_NOTIFIER_TEAM_ID" '.[$t].token // empty' "$creds" 2>/dev/null)"
  exp="$(jq -r --arg t "$SLACK_NOTIFIER_TEAM_ID" '.[$t].exp // empty' "$creds" 2>/dev/null)"
  now="$(date +%s)"
  [[ -n "$session" && "$exp" =~ ^[0-9]+$ && "$exp" -gt "$now" ]] || return 0
  # Same request the Slack CLI makes: JSON body, app_id only (team_id is for org installs).
  resp="$(curl -sS -m 15 -H "Authorization: Bearer $session" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$(jq -cn --arg a "$SLACK_NOTIFIER_APP_ID" '{app_id:$a}')" \
    https://slack.com/api/apps.developerInstall 2>/dev/null)"
  token="$(printf '%s' "$resp" | jq -r '.api_access_tokens.bot // empty' 2>/dev/null)"
  if [[ -z "$token" ]]; then
    log "bot token fetch failed: $(printf '%s' "$resp" | jq -r '.error // "no response"' 2>/dev/null)"
    return 0
  fi
  (umask 077; printf '%s\n' "$token" >"$SLACK_NOTIFIER_TOKEN_FILE") && log "cached bot token"
  printf '%s' "$token"
}

resp=""
if [[ -n "$SLACK_NOTIFIER_TOKEN" ]]; then
  resp="$(post_curl "$SLACK_NOTIFIER_TOKEN")"
else
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    token="$(cached_token)"
    [[ -n "$token" ]] || token="$(fetch_bot_token)"
    if [[ -n "$token" ]]; then
      resp="$(post_curl "$token")"
      if [[ $attempt -eq 1 ]] && printf '%s' "$resp" | grep -qE '"error":"(invalid_auth|token_revoked|account_inactive)"'; then
        rm -f "$SLACK_NOTIFIER_TOKEN_FILE"
        log "dropped cached bot token; retrying"
        continue
      fi
    else
      resp="$(post_cli)"
    fi
    break
  done
fi

if printf '%s' "$resp" | grep -q '"ok":true'; then
  log "sent $event -> $channel ($where)"
else
  log "FAILED $event: $(printf '%s' "$resp" | tr '\n' ' ' | head -c 300)"
fi
exit 0
