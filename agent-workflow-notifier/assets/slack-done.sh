#!/usr/bin/env bash
# Claude Code hook: DM the owner on Slack when an agent finishes (✅) or needs input (❓ / 🔐).
# Reads the hook payload on stdin. Config: ~/.claude/agent-workflow-notifier.env, then <cwd>/.env.
# Bot token: SLACK_NOTIFIER_TOKEN, else the cache file SLACK_NOTIFIER_TOKEN_FILE, else fetched once
# through apps.developerInstall with the Slack CLI session, else sent through the CLI.
# Stop is sent only when the turn ran at least SLACK_NOTIFIER_MIN_SECONDS (default 120) since the last
# human prompt, and is held while a background task of a SLACK_NOTIFIER_HOLD_TYPES type (default
# subagent,workflow) runs, unless the final message asks something. A turn woken by a completion notice
# inside that window is sent unless a ping already went out for the prompt (per-session epoch files in
# SLACK_NOTIFIER_STATE_DIR). SubagentStop is sent when SLACK_NOTIFIER_MIN_SECONDS passed since the last
# user entry. Notification and PreToolUse are sent at any age, except a permission notification that
# repeats an AskUserQuestion ping. A Stop is titled ❓ when, outside code, URLs and headings, a line ends
# a sentence with "?" or the last paragraph holds an ask phrase.
# Stop and SubagentStop carry 2 to 4 bullets written by a headless `claude -p` run over the turn's
# tool calls and final message. SLACK_NOTIFIER_INNER=1 keeps that run from re-entering this hook.
set -u
[[ "${SLACK_NOTIFIER_INNER:-}" == "1" ]] && exit 0

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
: "${SLACK_NOTIFIER_SUMMARY:=claude}"
: "${SLACK_NOTIFIER_SUMMARY_MODEL:=haiku}"
: "${SLACK_NOTIFIER_SUMMARY_TIMEOUT:=45}"
: "${SLACK_NOTIFIER_CLAUDE:=}"
: "${SLACK_NOTIFIER_HOLD_TYPES:=subagent,workflow}"
: "${SLACK_NOTIFIER_STATE_DIR:=$HOME/.claude/hooks/slack-done.state}"
SLACK_NOTIFIER_PROJECT="${SLACK_NOTIFIER_PROJECT/#\~/$HOME}"
SLACK_NOTIFIER_TOKEN_FILE="${SLACK_NOTIFIER_TOKEN_FILE/#\~/$HOME}"
SLACK_NOTIFIER_CLAUDE="${SLACK_NOTIFIER_CLAUDE/#\~/$HOME}"
SLACK_NOTIFIER_STATE_DIR="${SLACK_NOTIFIER_STATE_DIR/#\~/$HOME}"
[[ "$SLACK_NOTIFIER_SUMMARY_TIMEOUT" =~ ^[0-9]+$ ]] || SLACK_NOTIFIER_SUMMARY_TIMEOUT=45

if [[ -n "$SLACK_NOTIFIER_EVENTS" && ",$SLACK_NOTIFIER_EVENTS," != *",$event,"* ]]; then
  exit 0
fi
[[ -n "$SLACK_NOTIFIER_USER" ]] || { log "SLACK_NOTIFIER_USER unset; skipping"; exit 0; }

# ---------- per-session state: one epoch per file, every read and write fails soft ----------
# <session>.announced: last Stop ping sent while no held task ran. <session>.question: last
# AskUserQuestion ping. A session id that is empty or not a plain token disables state.
state_ok=0
[[ "$session" =~ ^[A-Za-z0-9_-]+$ ]] && state_ok=1
state_get() {
  local v
  [[ $state_ok -eq 1 ]] || return 0
  v="$(head -n 1 "$SLACK_NOTIFIER_STATE_DIR/$session.$1" 2>/dev/null | tr -d '[:space:]')"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}
state_put() {
  [[ $state_ok -eq 1 ]] || return 0
  (umask 077; mkdir -p "$SLACK_NOTIFIER_STATE_DIR" && printf '%s\n' "$2" >"$SLACK_NOTIFIER_STATE_DIR/$session.$1"
    find "$SLACK_NOTIFIER_STATE_DIR" -maxdepth 1 -type f \( -name '*.announced' -o -name '*.question' \) -mtime +7 -delete) >/dev/null 2>&1
  return 0
}

# A Stop "needs input" when, with fenced code, inline code, URLs and heading lines removed, any line
# holds a "?" that ends a sentence (qmark), or the last paragraph holds an ask phrase as whole words
# (phrase:<phrase>). Sets ASK_RULE and ASK_LINE (the last question line, or the last paragraph).
ASK_RULE="none"; ASK_LINE=""
asks_for_input() {
  local out
  out="$(printf '%s' "$1" | jq -Rrs '
    def strip: gsub("```[\\s\\S]*?```"; "") | gsub("`[^`\\n]*`"; "") | gsub("(https?|mailto):[^\\s)>\\]]+"; "")
      | [splits("\n") | select(test("^\\s*#{1,6}\\s") | not)] | join("\n");
    strip as $s
    | ([$s | splits("\n") | select(test("\\?([\\s*_)\\]]|$)"))] | last) as $q
    | ([$s | splits("\n\\s*\n") | select(test("\\S"))] | last // "") as $p
    | ([$p | match("(^|[^A-Za-z0-9_])(let me know|should i|do you want|would you like|which (one|option)|your call|pick one)([^A-Za-z0-9_]|$)"; "i").captures[1].string] | first) as $w
    | if $q != null then "qmark\n" + $q elif $w != null then "phrase:" + ($w | ascii_downcase) + "\n" + $p else "none" end' 2>/dev/null)"
  ASK_RULE="${out%%$'\n'*}"; ASK_LINE=""
  [[ "$out" == *$'\n'* ]] && ASK_LINE="${out#*$'\n'}"
  [[ "$ASK_RULE" == qmark || "$ASK_RULE" == phrase:* ]] && return 0
  ASK_RULE="none"; ASK_LINE=""
  return 1
}

# ---------- duration gate: a short turn means the user is still at the screen ----------
# Applies to Stop and SubagentStop only; a permission prompt or a question is sent at any age.
# One pass over the transcript gives two clocks: the last human prompt, and the last user entry
# of any origin (completion notices included). Stop measures from the first, SubagentStop from the
# second. No transcript, or SLACK_NOTIFIER_MIN_SECONDS=0, skips the clocks.
now_s="$(date +%s)"
min="$SLACK_NOTIFIER_MIN_SECONDS"; [[ "$min" =~ ^[0-9]+$ ]] || min=0
human_s=""; wake_s=""; pending=0; bg=0; asks=0; detail=""
if [[ "$event" == Stop || "$event" == SubagentStop ]]; then
  if [[ $min -gt 0 && -n "$transcript" && -f "$transcript" ]]; then
    read -r human_s wake_s <<<"$(jq -rnR '
      def txt: if type=="string" then . elif type=="array" then (map(select(.type=="text") | .text) | join("")) else "" end;
      def epoch: if type=="string" then (sub("\\.[0-9]+"; "") | try fromdateiso8601 catch "-") else "-" end;
      reduce (inputs | fromjson? | select(type=="object" and .type=="user" and .isMeta != true)
        | (.message.content? | txt) as $t | select(($t | length) > 0 and .timestamp != null)
        | {ts: .timestamp, t: $t, k: (.origin.kind? // "human")}) as $e
        ({h: null, w: null};
         .w = $e.ts | if $e.k == "human" and ($e.t | startswith("<task-notification>") | not) then .h = $e.ts else . end)
      | "\(.h | epoch) \(.w | epoch)"' "$transcript" 2>/dev/null)"
    [[ "$human_s" =~ ^[0-9]+$ ]] || human_s=""
    [[ "$wake_s" =~ ^[0-9]+$ ]] || wake_s=""
  fi
  gate_s="$wake_s"
  [[ "$event" == Stop && -n "$human_s" ]] && gate_s="$human_s"
  if [[ -n "$gate_s" && $(( now_s - gate_s )) -lt $min ]]; then
    log "skipped $event: turn took $(( now_s - gate_s ))s (< ${min}s)"
    exit 0
  fi
fi

# Stop only: a ✅ waits while a held-type background task runs (its completion wakes the agent again),
# and a notice-woken wrap-up inside the window is dropped once this prompt was announced.
if [[ "$event" == Stop ]]; then
  read -r pending bg held <<<"$(printf '%s' "$payload" | jq -r --arg types "$SLACK_NOTIFIER_HOLD_TYPES" '
    ($types | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $h
    | [.background_tasks[]?] as $all
    | [$all[] | select(type=="object" and (.status=="running" or .status=="pending")) | select(.type as $t | any($h[]; . == $t))] as $p
    | "\($p | length) \($all | length) \($p | map(.type) | unique | join(","))"' 2>/dev/null)"
  [[ "$pending" =~ ^[0-9]+$ ]] || pending=0
  [[ "$bg" =~ ^[0-9]+$ ]] || bg=0
  detail="$(jqget '.last_assistant_message')"
  asks_for_input "$detail" && asks=1
  if [[ $pending -gt 0 && $asks -eq 0 ]]; then
    log "held Stop: $pending background task(s) running ($held)"
    exit 0
  fi
  if [[ -n "$human_s" && -n "$wake_s" && $(( now_s - wake_s )) -lt $min ]]; then
    announced="$(state_get announced)"
    if [[ -n "$announced" && $announced -ge $human_s ]]; then
      log "skipped Stop: already announced for this prompt (woke $(( now_s - wake_s ))s ago)"
      exit 0
    fi
  fi
fi

# ---------- context: repo / worktree / branch / agent ----------
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

trunc() { local s="$1" n="$2"; if [[ ${#s} -gt $n ]]; then printf '%s…' "${s:0:$n}"; else printf '%s' "$s"; fi; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | sed -E 's/  +/ /g'; }

# ---------- turn digest: one streaming jq pass over the transcript ----------
# The turn is every entry after the last real user prompt: a user entry that is not meta and
# whose text is non-empty and does not open with "<". Counters reset at each such prompt, so
# the pass never holds the transcript in memory. Text is clipped before any regex runs on it.
digest='{}'
if [[ -n "$transcript" && -f "$transcript" ]]; then
  d="$(jq -cnR '
    def txt: if type=="string" then . elif type=="array" then (map(select(.type=="text") | .text // "") | join("")) else "" end;
    def ptext: (.message.content | txt) | .[0:400] | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    def is_prompt: (.type == "user") and ((.isMeta // false) != true)
      and (ptext | (length > 0) and (startswith("<") | not));
    def act:
      if (.name == "Bash" or .name == "Agent" or .name == "Task") then (.input.description? // empty)
      elif (.name == "Edit" or .name == "Write") then ((.input.file_path? // empty) | split("/") | last | select(length > 0) | "edited " + .)
      elif (.name == "Skill") then ((.input.skill? // empty) | select(length > 0) | "skill " + .)
      else empty end;
    def push($s): if ($s | type) == "string" and ($s | length) > 0
      then .actions = ((if (.actions | length) > 0 and (.actions[-1] == $s) then .actions else .actions + [$s] end) | .[-40:])
      else . end;
    reduce inputs as $l (
      {start: "", title: "", task: "", cmds: 0, files: [], agents: 0, actions: []};
      (try ($l | fromjson) catch null) as $e
      | if ($e | type) != "object" then .
        elif $e.type == "ai-title" then (if ($e.aiTitle | type) == "string" then .title = $e.aiTitle else . end)
        elif ($e | is_prompt) then
          (.start = ($e.timestamp // "")
           | (if .task == "" then .task = ($e | ptext) else . end)
           | .cmds = 0 | .files = [] | .agents = 0 | .actions = [])
        elif $e.type == "assistant" then
          reduce ($e.message.content[]? | select(.type == "tool_use")) as $t (.;
            (if $t.name == "Bash" then .cmds += 1 else . end)
            | (if ($t.name == "Edit" or $t.name == "Write" or $t.name == "NotebookEdit") then .files += [$t.input.file_path? // empty] else . end)
            | (if ($t.name == "Agent" or $t.name == "Task") then .agents += 1 else . end)
            | push([$t | act] | first // ""))
        else . end)
    | .files = (.files | unique | length)
    | .actions = (.actions | map(if length > 100 then .[0:100] + "…" else . end))
  ' "$transcript" 2>/dev/null)"
  [[ -n "$d" ]] && digest="$d"
fi
dget() { printf '%s' "$digest" | jq -r "$1 // empty" 2>/dev/null; }

task="$(dget '.title')"
[[ -n "$task" ]] || task="$(dget '.task')"
task="$(trunc "$(oneline "$task")" 100)"
n_cmds="$(dget '.cmds')"; n_files="$(dget '.files')"; n_agents="$(dget '.agents')"

minutes=""
turn_start="$(printf '%s' "$(dget '.start')" | jq -rR 'select(length > 0) | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty' 2>/dev/null)"
if [[ "$turn_start" =~ ^[0-9]+$ ]]; then
  minutes=$(( ( $(date +%s) - turn_start ) / 60 ))
  [[ $minutes -lt 0 ]] && minutes=""
fi

# ---------- summary bullets ----------
SUMMARY_SYS='You write Slack notifications about a coding agent turn. Output only 2 to 4 bullets, each starting with "• ", each at most 12 words, past tense, plain words, no markdown, no preamble. Bullets say what was done. If something is pending, failed, or blocked, one bullet starts with "Pending:". If the final message asks the user something, the last bullet starts with "Asks:" and states the question.'
# macOS ships no timeout(1); perl's alarm survives exec and kills the child on SIGALRM.
run_limited() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  else
    "$@"
  fi
}

find_claude() {
  local c
  if [[ -n "$SLACK_NOTIFIER_CLAUDE" ]]; then
    [[ -x "$SLACK_NOTIFIER_CLAUDE" ]] && printf '%s' "$SLACK_NOTIFIER_CLAUDE"
    return 0
  fi
  c="$(command -v claude 2>/dev/null || true)"
  [[ -n "$c" ]] && { printf '%s' "$c"; return 0; }
  for c in /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 0
}

# Prints the bullet block, or nothing when the summarizer is unavailable or its answer
# carries no bullet. Runs from the Slack CLI project dir so no repo settings or hooks load.
run_summarizer() {
  local input="$1" bin dir out rc t0 t1 tmp
  bin="$(find_claude)"
  [[ -n "$bin" ]] || { log "summary: fallback (no claude binary)"; return 1; }
  dir="$SLACK_NOTIFIER_PROJECT"; [[ -d "$dir" ]] || dir="$HOME"
  tmp="$(mktemp "${TMPDIR:-/tmp}/slack-done.XXXXXX" 2>/dev/null)" || { log "summary: fallback (no temp file)"; return 1; }
  t0="$(date +%s)"
  # Answer goes to a file, not a pipe: a child that outlives the alarm would otherwise
  # hold the pipe open and the hook would wait for it anyway.
  (cd "$dir" 2>/dev/null && printf '%s' "$input" | SLACK_NOTIFIER_INNER=1 run_limited "$SLACK_NOTIFIER_SUMMARY_TIMEOUT" \
    "$bin" -p --model "$SLACK_NOTIFIER_SUMMARY_MODEL" --tools "" --no-session-persistence \
    --strict-mcp-config --settings '{"disableAllHooks":true}' --system-prompt "$SUMMARY_SYS" >"$tmp" 2>/dev/null)
  rc=$?
  t1="$(date +%s)"
  out="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
  if [[ $rc -eq 142 || $rc -eq 124 ]]; then log "summary: fallback (timeout)"; return 1; fi
  if [[ $rc -ne 0 ]]; then log "summary: fallback (claude exit $rc)"; return 1; fi
  printf '%s' "$out" | grep -q '^•' || { log "summary: fallback (no bullets)"; return 1; }
  printf '%s\n' "$out" | grep '^•' | head -n 4 | while IFS= read -r line; do trunc "$line" 140; printf '\n'; done
  log "summary: claude $(( t1 - t0 ))s"
  return 0
}

# First sentence of the first paragraph, plus the question line or ask paragraph when there is one.
fallback_summary() {
  local msg="$1" para line ask
  para="$(printf '%s\n' "$msg" | awk 'BEGIN{RS=""} NR==1{print; exit}')"
  line="$(oneline "$para" | sed -E 's/^[[:space:]]*[#*_-]+[[:space:]]*//; s/([.!?])[[:space:]].*/\1/; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -n "$line" ]] && trunc "$line" 200 && printf '\n'
  if asks_for_input "$msg"; then
    ask="$(oneline "$ASK_LINE" | sed -E 's/^[[:space:]]*[#*_-]+[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$ask" ]] && { printf 'Asks: '; trunc "$ask" 200; printf '\n'; }
  fi
  return 0
}

# Turn digest + final message in, bullet block out.
summarize() {
  local msg="$1" input actions out
  if [[ -z "$msg" ]]; then log "summary: no message"; printf 'turn ended'; return 0; fi
  if [[ ${#msg} -le 240 ]]; then log "summary: short message"; oneline "$msg"; return 0; fi
  if [[ "$SLACK_NOTIFIER_SUMMARY" == "claude" ]]; then
    actions="$(printf '%s' "$digest" | jq -r '.actions[]? | "- " + .' 2>/dev/null)"
    input="Task: $task
Actions this turn:
$actions
Final message:
$(trunc "$msg" 3000)"
    out="$(run_summarizer "$input")"
    if [[ -n "$out" ]]; then printf '%s' "$out"; return 0; fi
  else
    log "summary: fallback (summary off)"
  fi
  fallback_summary "$msg"
  return 0
}

# ---------- title and body per event ----------
msgbody=""
case "$event" in
  Stop)
    if [[ $asks -eq 1 ]]; then
      title="❓ Needs your input"
    else
      title="✅ Finished"
    fi
    msgbody="$(summarize "$detail")"
    ;;
  Notification)
    ntype="$(jqget '.notification_type')"
    case "$ntype" in
      permission_prompt)
        # An open AskUserQuestion dialog raises this notice 6 s later; the question ping covered it.
        qs="$(state_get question)"
        if [[ "$(jqget '.message')" == *AskUserQuestion* ]] || [[ -n "$qs" && $(( $(date +%s) - qs )) -le 10 ]]; then
          log "skipped Notification: duplicate of the question ping"
          exit 0
        fi
        title="🔐 Needs your input: permission" ;;
      elicitation_dialog) title="❓ Needs your input" ;;
      idle_prompt)        exit 0 ;;
      *)                  title="🔔 ${ntype:-notification}" ;;
    esac
    msgbody="$(trunc "$(oneline "$(jqget '.message')")" 300)"
    ;;
  SessionEnd)
    exit 0
    ;;
  PreToolUse)
    tool="$(jqget '.tool_name')"
    title="❓ Needs your input: question"
    [[ "$tool" != "AskUserQuestion" ]] && title="🔔 $tool"
    # Stamped before the post so a slow post cannot lose the race to the permission notice.
    [[ "$tool" == "AskUserQuestion" ]] && state_put question "$(date +%s)"
    detail="$(printf '%s' "$payload" | jq -r '
      [.tool_input.questions[]? | .question + (if (.options|length)>0 then " [" + ((.options|map(.label))|join(" / ")) + "]" else "" end)]
      | join(" | ")' 2>/dev/null)"
    [[ -z "$detail" ]] && detail="$(jqget '.tool_input.description')"
    msgbody="$(trunc "$(oneline "$detail")" 300)"
    ;;
  SubagentStop)
    title="🤖 Subagent finished"
    msgbody="$(summarize "$(jqget '.last_assistant_message')")"
    ;;
  *)
    title="ℹ️ ${event:-hook}"
    msgbody="$(trunc "$(oneline "$(jqget '.message')")" 300)"
    ;;
esac

# ---------- footer: agent, session, elapsed minutes, what the turn touched ----------
count_part() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || return 0
  if [[ "$n" -eq 1 ]]; then printf '%s %s' "$n" "$2"; else printf '%s %s' "$n" "$3"; fi
}
meta="$agent"
add_meta() { [[ -n "$1" ]] && meta="$meta · $1"; return 0; }
add_meta "${session:0:8}"
if [[ "$event" == Stop || "$event" == SubagentStop ]]; then
  [[ -n "$minutes" ]] && add_meta "$minutes min"
  add_meta "$(count_part "$n_cmds" command commands)"
  add_meta "$(count_part "$n_files" "file edited" "files edited")"
  add_meta "$(count_part "$n_agents" subagent subagents)"
fi

text="$(jq -rn \
  --arg user "$SLACK_NOTIFIER_USER" --arg title "$title" --arg where "$where" \
  --arg task "$task" --arg body "$msgbody" --arg meta "$meta" '
  def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
  [ "*\($title)* · `\($where|esc)` <@\($user)>",
    (if $task != "" then "_\($task|esc)_" else empty end),
    (if $body != "" then ($body|esc) else empty end),
    (if $meta != "" then "`\($meta|esc)`" else empty end)
  ] | join("\n")')"

channel="${SLACK_NOTIFIER_CHANNEL:-$SLACK_NOTIFIER_USER}"
body="$(jq -cn --arg ch "$channel" --arg text "$text" '{channel:$ch, text:$text, mrkdwn:true, unfurl_links:false, unfurl_media:false}')"

case "$event" in
  Stop)         logline="title=\"$title\" ask=$ASK_RULE bg=$bg" ;;
  Notification) logline="title=\"$title\" msg=\"$(trunc "$(oneline "$(jqget '.message')")" 80)\"" ;;
  *)            logline="title=\"$title\"" ;;
esac
logline="$event -> $channel ($where) $logline session=${session:0:8}"
# A Stop that goes out while no held task runs marks this prompt announced.
announce() { [[ "$event" == Stop && $pending -eq 0 ]] && state_put announced "$(date +%s)"; return 0; }

if [[ "${SLACK_NOTIFIER_DRY_RUN:-}" == "1" ]]; then log "dry-run $logline"; announce; printf '%s\n' "$text"; exit 0; fi

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
  log "sent $logline"
  announce
else
  log "FAILED $event: $(printf '%s' "$resp" | tr '\n' ' ' | head -c 300)"
fi
exit 0
