#!/usr/bin/env bash
# Offline tests for a slack-done.sh candidate. Every run is dry (no Slack, no claude -p) with an
# isolated HOME, so no real config, token or state is read or written.
# Usage: slack-hook-tests.sh <candidate>
# Env: HOOK_BASH interpreter for the candidate (default bash), ONLY space-separated case ids,
#      FIXTURE_LIMIT first N fixture lines for case 14 (default all).
# Case 14 reads asks-fixture.jsonl next to this script, one {"msg", "expect"} object per line with
# expect none, qmark or phrase:<phrase>, and is skipped when the file is absent. The fixture is built
# from private transcripts and never ships with the skill.
# Needs BSD date (macOS): the transcript timestamps use its -v offsets.
set -u
cand="${1:?usage: slack-hook-tests.sh <candidate>}"
here="$(cd "$(dirname "$0")" && pwd)"
fixture="$here/asks-fixture.jsonl"
HOOK_BASH="${HOOK_BASH:-bash}"
ONLY="${ONLY:-}"
FIXTURE_LIMIT="${FIXTURE_LIMIT:-0}"

root="$(mktemp -d "${TMPDIR:-/tmp}/slack-hook-tests.XXXXXX")" || exit 1
trap 'rm -rf "$root"' EXIT
work="$root/cwd"; mkdir -p "$work"

pass=0; fail=0; skip=0; errs=""
want() { [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }
finish() {
  if [[ -z "$errs" ]]; then pass=$((pass + 1)); printf 'PASS %s\n' "$1"
  else fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "${errs#; }"; fi
  errs=""
}

ts() { date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z; }
epoch_ago() { printf '%s' $(( $(date +%s) - $1 )); }
new_home() { local h; h="$(mktemp -d "$root/home.XXXXXX")"; mkdir -p "$h/.claude/hooks"; printf '%s' "$h"; }
logf() { printf '%s' "$1/.claude/hooks/slack-done.log"; }
statef() { printf '%s' "$1/.claude/hooks/slack-done.state/$2"; }

# run <home> <payload> [VAR=value ...]: OUT is the candidate's stdout, FIRST its first line.
# The log is emptied first so assertions see this run only.
run() {
  local h="$1" p="$2"; shift 2
  : >"$(logf "$h")"
  OUT="$(printf '%s' "$p" | env -i PATH="$PATH" HOME="$h" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-en_US.UTF-8}" \
    SLACK_NOTIFIER_USER=UTEST SLACK_NOTIFIER_DRY_RUN=1 SLACK_NOTIFIER_SUMMARY=off ${1+"$@"} \
    "$HOOK_BASH" "$cand" 2>/dev/null)"
  FIRST="${OUT%%$'\n'*}"
}

first_has() { [[ "$FIRST" == *"$1"* ]] || errs="$errs; first line '${FIRST:0:70}' lacks '$1'"; }
silent() { [[ -z "$OUT" ]] || errs="$errs; printed '${FIRST:0:70}'"; }
log_has() { grep -qF -- "$2" "$(logf "$1")" 2>/dev/null || errs="$errs; log lacks '$2' (log: $(tr '\n' ' ' <"$(logf "$1")" | cut -c1-200))"; }
file_set() { [[ "$(cat "$1" 2>/dev/null)" =~ ^[0-9]+$ ]] || errs="$errs; $(basename "$1") not written"; }
file_unset() { [[ ! -e "$1" ]] || errs="$errs; $(basename "$1") written"; }

# ---------- transcript entries ----------
human() { jq -cn --arg ts "$(ts "$1")" --arg c "$2" '{type:"user", isMeta:false, timestamp:$ts, promptId:"p1", origin:{kind:"human"}, message:{role:"user", content:$c}}'; }
bare_human() { jq -cn --arg ts "$(ts "$1")" --arg c "$2" '{type:"user", timestamp:$ts, message:{role:"user", content:[{type:"text", text:$c}]}}'; }
notice() { jq -cn --arg ts "$(ts "$1")" '{type:"user", timestamp:$ts, promptId:"p2", origin:{kind:"task-notification"}, message:{role:"user", content:"<task-notification>\n<task-id>a1b2</task-id>\n<status>completed</status>\n</task-notification>"}}'; }
meta() { jq -cn --arg ts "$(ts "$1")" '{type:"user", isMeta:true, timestamp:$ts, message:{role:"user", content:"peer message"}}'; }
tool_result() { jq -cn --arg ts "$(ts "$1")" '{type:"user", timestamp:$ts, message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", content:"ok"}]}}'; }
assistant() { jq -cn --arg ts "$(ts "$1")" --arg c "$2" '{type:"assistant", timestamp:$ts, message:{role:"assistant", content:[{type:"text", text:$c}, {type:"tool_use", name:"Bash", input:{command:"ls", description:"List files"}}]}}'; }

# ---------- payloads ----------
# stop_payload <event> <session> <transcript or ""> <message> <background_tasks json>
stop_payload() {
  jq -cn --arg e "$1" --arg s "$2" --arg t "$3" --arg m "$4" --argjson bg "$5" --arg cwd "$work" '
    {session_id:$s, cwd:$cwd, prompt_id:"p1", permission_mode:"default", hook_event_name:$e, stop_hook_active:false,
     last_assistant_message:$m, background_tasks:$bg, session_crons:[]}
    + (if $t == "" then {} else {transcript_path:$t} end)'
}
notif_payload() {
  jq -cn --arg s "$1" --arg m "$2" --arg cwd "$work" \
    '{session_id:$s, cwd:$cwd, hook_event_name:"Notification", notification_type:"permission_prompt", message:$m}'
}
ask_payload() {
  jq -cn --arg s "$1" --arg cwd "$work" '{session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"AskUserQuestion",
    tool_input:{questions:[{question:"Which layout should the grid use?", header:"Layout", multiSelect:false,
      options:[{label:"Cards", description:"Card grid"}, {label:"Table", description:"Dense table"}]}]}}'
}
task() { jq -cn --arg t "$1" --arg st "$2" '[{id:"b1", type:$t, status:$st, description:"bg work"} + (if $t == "subagent" then {agent_type:"general-purpose"} else {} end)]'; }

plain="Done. Fixed the null check in the parser and reran the tests; all green."
question="I found two ways to fix the parser.

Should I apply the smaller patch now?"

# ---------- cases ----------
if want 0; then
  /bin/bash -n "$cand" 2>/dev/null || errs="$errs; bash -n failed"
  finish "0 bash -n (/bin/bash $(/bin/bash -c 'echo $BASH_VERSION'))"
fi

if want 1; then
  h="$(new_home)"; tr="$root/t1.jsonl"
  { human 300 "fix the parser"; assistant 290 "Working on it"; tool_result 280; meta 100; } >"$tr"
  run "$h" "$(stop_payload Stop sess0001-aaaa "$tr" "$plain" '[]')"
  first_has "*✅ Finished*"; file_set "$(statef "$h" sess0001-aaaa.announced)"; log_has "$h" 'dry-run Stop -> UTEST'
  log_has "$h" 'title="✅ Finished" ask=none bg=0 session=sess0001'
  finish "1 Stop 300s, no tasks -> ✅, .announced written"
fi

if want 2; then
  h="$(new_home)"; tr="$root/t2.jsonl"
  { human 30 "fix the parser"; assistant 20 "Working on it"; } >"$tr"
  run "$h" "$(stop_payload Stop sess0002-aaaa "$tr" "$plain" '[]')"
  silent; log_has "$h" "skipped Stop: turn took"
  finish "2 Stop 30s -> skipped (duration)"
fi

if want 3; then
  h="$(new_home)"; tr="$root/t3.jsonl"
  { human 300 "fix the parser"; assistant 290 "Spawning a subagent"; } >"$tr"
  run "$h" "$(stop_payload Stop sess0003-aaaa "$tr" "$plain" "$(task subagent running)")"
  silent; log_has "$h" "held Stop: 1 background task(s) running (subagent)"
  file_unset "$(statef "$h" sess0003-aaaa.announced)"
  finish "3 Stop 300s, subagent running -> held"
fi

if want 4; then
  h="$(new_home)"; tr="$root/t4.jsonl"
  { human 300 "fix the parser"; assistant 290 "Spawning a subagent"; } >"$tr"
  run "$h" "$(stop_payload Stop sess0004-aaaa "$tr" "$question" "$(task subagent running)")"
  first_has "*❓ Needs your input*"; file_unset "$(statef "$h" sess0004-aaaa.announced)"
  log_has "$h" "ask=qmark bg=1"
  finish "4 Stop 300s, subagent running, question -> ❓, .announced not written"
fi

if want 5 || want 6 || want 7; then
  h5="$(new_home)"; tr5="$root/t5.jsonl"
  { human 600 "fix the parser"; assistant 590 "Spawned a subagent, waiting"; notice 5; assistant 3 "Subagent done"; } >"$tr5"
  p5="$(stop_payload Stop sess0005-aaaa "$tr5" "$plain" '[]')"
fi
if want 5; then
  run "$h5" "$p5"
  first_has "*✅ Finished*"; file_set "$(statef "$h5" sess0005-aaaa.announced)"
  finish "5 Stop, prompt 600s, notice 5s, no state -> ✅"
fi
if want 6; then
  run "$h5" "$p5"
  silent; log_has "$h5" "skipped Stop: already announced for this prompt (woke"
  finish "6 case 5 again, same state -> skipped (already announced)"
fi
if want 7; then
  human 200 "now do the next part" >>"$tr5"
  run "$h5" "$p5"
  first_has "*✅ Finished*"
  finish "7 new human prompt 200s ago appended -> ✅"
fi

if want 7b; then
  h="$(new_home)"; tr="$root/t7b.jsonl"
  { human 600 "fix the parser"; assistant 590 "done"; human 200 "next part"; assistant 190 "Spawned"; notice 3; } >"$tr"
  mkdir -p "$h/.claude/hooks/slack-done.state"
  epoch_ago 400 >"$(statef "$h" sess007b-aaaa.announced)"
  run "$h" "$(stop_payload Stop sess007b-aaaa "$tr" "$plain" '[]')"
  first_has "*✅ Finished*"
  epoch_ago 100 >"$(statef "$h" sess007b-aaaa.announced)"
  run "$h" "$(stop_payload Stop sess007b-aaaa "$tr" "$plain" '[]')"
  silent; log_has "$h" "already announced for this prompt"
  finish "7b notice 3s: announced before prompt -> ✅; announced after prompt -> skipped"
fi

if want 8; then
  h="$(new_home)"; tr="$root/t8.jsonl"
  { human 300 "run the server"; assistant 290 "Started"; } >"$tr"
  run "$h" "$(stop_payload Stop sess0008-aaaa "$tr" "$plain" "$(task shell running)")"
  first_has "*✅ Finished*"; log_has "$h" "bg=1"
  run "$h" "$(stop_payload Stop sess0008-aaaa "$tr" "$plain" "$(task shell running)")" SLACK_NOTIFIER_HOLD_TYPES=subagent,workflow,shell
  silent; log_has "$h" "held Stop: 1 background task(s) running (shell)"
  finish "8 shell task -> ✅; HOLD_TYPES incl. shell -> held"
fi

if want 9; then
  h="$(new_home)"
  run "$h" "$(stop_payload Stop sess0009-aaaa "" "$plain" "$(task workflow pending)")"
  silent; log_has "$h" "held Stop: 1 background task(s) running (workflow)"
  run "$h" "$(stop_payload Stop sess0009-aaaa "" "$plain" '[]')"
  first_has "*✅ Finished*"
  finish "9 no transcript: workflow pending -> held; no tasks -> ✅"
fi

if want 10; then
  h="$(new_home)"
  run "$h" "$(notif_payload sess0010-aaaa "Claude needs your permission to use AskUserQuestion")"
  silent; log_has "$h" "skipped Notification: duplicate of the question ping"
  h="$(new_home)"
  run "$h" "$(notif_payload sess0010-aaaa "Claude needs your permission to use Bash")"
  first_has "*🔐 Needs your input: permission*"
  log_has "$h" 'msg="Claude needs your permission to use Bash" session=sess0010'
  finish "10 permission notice: AskUserQuestion -> skipped; Bash -> 🔐"
fi

if want 11; then
  h="$(new_home)"
  run "$h" "$(ask_payload sess0011-aaaa)"
  first_has "*❓ Needs your input: question*"; file_set "$(statef "$h" sess0011-aaaa.question)"
  log_has "$h" 'dry-run PreToolUse -> UTEST'; log_has "$h" 'title="❓ Needs your input: question" session=sess0011'
  run "$h" "$(notif_payload sess0011-aaaa "Claude needs your permission to use Question")"
  silent; log_has "$h" "duplicate of the question ping"
  finish "11 AskUserQuestion ping -> ❓ + .question; permission notice right after -> skipped"
fi

if want 12; then
  h="$(new_home)"; tr="$root/t12.jsonl"
  { human 300 "audit the module"; assistant 290 "Delegating"; } >"$tr"
  run "$h" "$(stop_payload SubagentStop sess0012-aaaa "$tr" "Report: three call sites found." "$(task subagent running)")"
  first_has "*🤖 Subagent finished*"; file_unset "$(statef "$h" sess0012-aaaa.announced)"
  finish "12 SubagentStop, wake 300s (subagent task listed) -> 🤖"
fi

if want 12b; then
  h="$(new_home)"; tr="$root/t12b.jsonl"
  { human 600 "audit the module"; assistant 590 "Delegating"; notice 30; } >"$tr"
  run "$h" "$(stop_payload SubagentStop sess012b-aaaa "$tr" "Report: three call sites found." '[]')"
  silent; log_has "$h" "skipped SubagentStop: turn took"
  finish "12b SubagentStop, prompt 600s, notice 30s -> skipped (single wake clock)"
fi

if want 13; then
  h="$(new_home)"; tr="$root/t13.jsonl"
  { bare_human 300 "fix the parser"; assistant 290 "Working"; } >"$tr"
  run "$h" "$(stop_payload Stop sess0013-aaaa "$tr" "$plain" '[]')"
  first_has "*✅ Finished*"
  { bare_human 30 "and the lexer"; } >>"$tr"
  run "$h" "$(stop_payload Stop sess0013-aaaa "$tr" "$plain" '[]')"
  silent; log_has "$h" "skipped Stop: turn took"
  finish "13 entries without origin: prompt 300s -> ✅; prompt 30s -> skipped"
fi

if want 15; then
  h="$(new_home)"; sd="$h/.claude/hooks/slack-done.state"; old="$(date -v-10d +%Y%m%d%H%M)"
  mkdir -p "$sd"; echo 1 >"$sd/gone.announced"; echo 1 >"$sd/keep.txt"; echo 1 >"$sd/fresh.question"
  touch -t "$old" "$sd/gone.announced" "$sd/keep.txt"
  run "$h" "$(stop_payload Stop sess0015-aaaa "" "$plain" '[]')"
  first_has "*✅ Finished*"; file_set "$sd/sess0015-aaaa.announced"; file_set "$sd/fresh.question"; file_set "$sd/keep.txt"
  [[ -e "$sd/gone.announced" ]] && errs="$errs; 10-day-old state file not pruned"
  h="$(new_home)"
  run "$h" "$(stop_payload Stop "" "" "$plain" '[]')"
  first_has "*✅ Finished*"; [[ -e "$h/.claude/hooks/slack-done.state" ]] && errs="$errs; state dir created for empty session"
  run "$h" "$(stop_payload Stop sess0015-bbbb "" "$plain" '[]')" SLACK_NOTIFIER_STATE_DIR=/dev/null/state
  first_has "*✅ Finished*"
  run "$h" "$(ask_payload sess0015-bbbb)" SLACK_NOTIFIER_STATE_DIR=/dev/null/state
  first_has "*❓ Needs your input: question*"
  finish "15 state: prunes >7d state files only, skips empty session, unwritable dir fails soft"
fi

if want 14 && [[ ! -f "$fixture" ]]; then
  skip=$((skip + 1)); printf 'SKIP 14 fixture agreement: %s not found\n' "$(basename "$fixture")"
elif want 14; then
  h="$(new_home)"; t0="$(date +%s)"
  jq -r '.expect' "$fixture" >"$root/fx.expect"
  jq -c --arg cwd "$work" '{session_id:"fixture0", cwd:$cwd, hook_event_name:"Stop", last_assistant_message:.msg}' "$fixture" >"$root/fx.payload"
  jq -r '.msg | gsub("\\s+"; " ") | .[0:160]' "$fixture" >"$root/fx.excerpt"
  n=0; tagree=0; aagree=0; both=0; mism=""
  e_none=0; e_q=0; e_p=0; g_none=0; g_q=0; g_p=0
  while IFS= read -r expect <&3 && IFS= read -r p <&4 && IFS= read -r ex <&5; do
    n=$((n + 1))
    [[ $FIXTURE_LIMIT -gt 0 && $n -gt $FIXTURE_LIMIT ]] && { n=$((n - 1)); break; }
    run "$h" "$p"
    got="$(sed -nE 's/.* ask=(.*) bg=[0-9]+ session=.*/\1/p' "$(logf "$h")" | tail -n 1)"
    if [[ "$expect" == none ]]; then wt="*✅ Finished*"; else wt="*❓ Needs your input*"; fi
    case "$expect" in none) e_none=$((e_none + 1)) ;; qmark) e_q=$((e_q + 1)) ;; phrase:*) e_p=$((e_p + 1)) ;; esac
    case "$got" in none) g_none=$((g_none + 1)) ;; qmark) g_q=$((g_q + 1)) ;; phrase:*) g_p=$((g_p + 1)) ;; esac
    tok=0; aok=0
    [[ "$FIRST" == "$wt"* ]] && { tok=1; tagree=$((tagree + 1)); }
    [[ "$got" == "$expect" ]] && { aok=1; aagree=$((aagree + 1)); }
    if [[ $tok -eq 1 && $aok -eq 1 ]]; then both=$((both + 1))
    else mism="$mism
  MISMATCH line $n: expected=$expect got_ask=${got:-<none logged>} got_title='${FIRST:0:40}' msg='$ex'"; fi
  done 3<"$root/fx.expect" 4<"$root/fx.payload" 5<"$root/fx.excerpt"
  printf '  fixture: %s lines in %ss; title agree %s/%s, ask= agree %s/%s, both %s/%s\n' "$n" $(( $(date +%s) - t0 )) "$tagree" "$n" "$aagree" "$n" "$both" "$n"
  printf '  expected: none=%s qmark=%s phrase=%s | got: none=%s qmark=%s phrase=%s\n' "$e_none" "$e_q" "$e_p" "$g_none" "$g_q" "$g_p"
  [[ -n "$mism" ]] && printf '%s\n' "${mism#?}"
  [[ $both -eq $n && $n -gt 0 ]] || errs="$errs; $(( n - both )) fixture mismatches"
  finish "14 fixture agreement ($both/$n)"
fi

printf 'TOTAL: %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
