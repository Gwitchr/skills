#!/usr/bin/env bash
# nazgul check.sh: Stop-hook logic. Report, then poll, then block (continue), or let the session end.
#
#   check.sh --agent <claude|codex|grok|omp>                 Stop hook; reads the hook payload on stdin
#   check.sh --agent omp --background --payload <file> --inbox <file>
#                                                            Oh My Pi: runs detached, writes to the inbox
#   check.sh --commit-msg <file>                             git commit-msg backstop; only warns
#
# One Stop, step by step:
#   1. Off here (repo not enrolled, no report repo, skip path, NAZGUL_OFF=1, not a work tree): exit 0,
#      print nothing. The hooks are user-level and run in every repo, so this is the common case.
#   2. stop_hook_active is set but nazgul did not cause the continuation: exit 0 (another hook did).
#   3. No report for this stop yet: a tool that can block gets a block whose reason asks the agent to
#      run report.sh with this session's id. The next Stop finds the report, or, when the agent did
#      not write one, pushes one nazgul builds from git and the agent's last message. Oh My Pi cannot
#      block, so it always gets the built report.
#   4. Poll this session's thread (poll.sh). continue: block with the reply as the reason, at most
#      max_rounds times per session. stop / wait-for-owner / no reply: let the session end with a note.
# Every failure warns and exits 0: a network or auth problem never keeps a session from ending.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

agent=""; background=0; payload_file=""; inbox=""; msgfile=""; mode="stop"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --background) background=1; shift ;;
    --agent|--payload|--inbox|--commit-msg)
      [[ $# -ge 2 ]] || { nz_warn "$1 needs a value"; exit 0; }
      case "$1" in
        --agent) agent="$2" ;; --payload) payload_file="$2" ;; --inbox) inbox="$2" ;;
        --commit-msg) msgfile="$2"; mode="commit-msg" ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
NZ_AGENT="$(nz_agent "$agent")"

# ---------- git commit-msg backstop ----------
# Warns (stderr, never blocks) when an agent commits on a branch that has no report on record, so an
# agent whose tool has no Stop hook, or whose hook is not trusted yet, knows to run report.sh.
if [[ "$mode" == commit-msg ]]; then
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  nz_load "$PWD" || exit 0
  who="${NAZGUL_AGENT:-}"
  [[ -z "$who" && -n "${CLAUDECODE:-}" ]] && who="claude"
  [[ -z "$who" && -n "${CODEX_THREAD_ID:-}${CODEX_SESSION_ID:-}" ]] && who="codex"
  [[ -z "$who" && -n "${GROK_SESSION_ID:-}${GROK_WORKSPACE_ROOT:-}" ]] && who="grok"
  [[ -z "$who" && -n "${CURSOR_AGENT:-}" ]] && who="cursor"
  if [[ -z "$who" && -f "$msgfile" ]]; then
    who="$(grep -ioE '^co-authored-by:.*(claude|codex|grok|cursor)' "$msgfile" 2>/dev/null | head -n 1 \
      | grep -ioE '(claude|codex|grok|cursor)' | tr 'A-Z' 'a-z')"
  fi
  [[ -n "$who" ]] || exit 0
  for f in "$NZ_STATE"/sessions/*.branch; do
    [[ -f "$f" && "$(head -n 1 "$f")" == "$NZ_BRANCH" ]] && exit 0
  done
  nz_warn "branch $NZ_BRANCH has no session report yet (the commit went through)."
  nz_warn "before the session ends, write one: bash \"$NZ_SCRIPTS/report.sh\" --agent $(nz_agent "$who") --summary \"<one line>\" < report.md"
  nz_warn "sections: ## Changed, ## Why, ## Where, ## Left, ## Needs owner. See $NZ_SKILL/SKILL.md. Skip this if your Stop hook asks for it."
  exit 0
fi

# ---------- payload ----------
payload=""
if [[ -n "$payload_file" ]]; then
  payload="$(cat "$payload_file" 2>/dev/null)"; rm -f "$payload_file" 2>/dev/null
elif [[ ! -t 0 ]]; then
  payload="$(cat)"
fi
command -v jq >/dev/null 2>&1 || exit 0
jget() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }

# Grok also runs the hooks in ~/.claude/settings.json; its own ~/.grok/hooks file does the work there.
[[ "$NZ_AGENT" == claude && -n "${GROK_HOOK_EVENT:-}" ]] && exit 0
# Grok fires Stop again when the session closes; only a real end of turn counts.
if [[ "$NZ_AGENT" == grok ]]; then
  r="$(jget '.reason')"; [[ -z "$r" || "$r" == end_turn ]] || exit 0
fi

cwd="$(jget '.cwd // .workspaceRoot')"
nz_load "${cwd:-$PWD}" || exit 0
nz_session "$(jget '.session_id // .sessionId')" "$NZ_AGENT"
active="$(printf '%s' "$payload" | jq -r '(.stop_hook_active // .stopHookActive // false) | tostring' 2>/dev/null)"
last_msg="$(jget '.last_assistant_message // .lastAssistantMessage')"

can_block=1
[[ "$NZ_AGENT" == omp || "$NZ_AGENT" == other || "$NZ_AGENT" == cursor || $background -eq 1 ]] && can_block=0

work="$(mktemp -d "${TMPDIR:-/tmp}/nazgul.XXXXXX")" || exit 0
trap 'rm -rf "$work"' EXIT

# ---------- output: one JSON object on stdout at most; the inbox instead in background mode ----------
# block: keep the agent working with <reason> as its next prompt.
# tell:  a reply the user must see (stop, wait-for-owner, or continue in background mode).
# note:  status worth a line on screen; dropped in background mode so the inbox holds replies only.
block() {
  nz_sput blocked "$(date +%s)"
  jq -n --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}
show() {
  printf '%s\n' "$1" >&2
  case "$NZ_AGENT" in
    claude|codex|grok) jq -n --arg m "$1" '{systemMessage: $m}' ;;
  esac
  exit 0
}
tell() {
  if [[ $background -eq 1 ]]; then
    [[ -n "$inbox" ]] && (umask 077; mkdir -p "$(dirname "$inbox")" && printf '%s\n\n' "$1" >>"$inbox") 2>/dev/null
    exit 0
  fi
  show "$1"
}
note() { [[ $background -eq 1 ]] && exit 0; show "$1"; }

# ---------- 2. loop guard ----------
# stop_hook_active means a Stop hook made the agent continue. Go on only when nazgul did it.
blocked="$(nz_sget blocked)"
[[ "$active" == true && -z "$blocked" ]] && exit 0
nz_sdel blocked

# A newer background run for this session makes an older one stop at its next check.
[[ $background -eq 1 ]] && nz_sput poller "$$"

# ---------- 3. report ----------
ask_text() {
  local where="<links: branch, commits, pull request, key files>"
  [[ -n "$NZ_WEB" ]] && where="- Branch: $NZ_WEB/tree/$NZ_BRANCH
<commit and pull request links, key files>"
  cat <<EOF
nazgul: before this session ends, report it to the report repo. Run the command below once, with every section filled in (write "nothing" when a section has nothing to say). Keep secrets, tokens and credentials out of it. When it prints "pushed", end your turn; nazgul then checks the thread for a reply.

bash "$NZ_SCRIPTS/report.sh" --agent $NZ_AGENT --session $NZ_KEY --summary "<one line: what this session did>" <<'NAZGUL'
## Changed
<files, behavior and commits that changed>

## Why
<the reason for each change>

## Where
$where

## Left
<what is unfinished or still to do>

## Needs owner
<decisions, access or answers only the owner can give>
NAZGUL
EOF
}

# Pushes a report built from git and the agent's last message, for an agent that wrote none.
# Returns 0 when a new message landed in the thread.
auto_report() {
  local f="$work/auto.md" def upstream range="" commits="" status summary before rc
  def="$(git -C "$NZ_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  upstream="$(git -C "$NZ_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  if [[ -n "$def" && "origin/$NZ_BRANCH" != "$def" ]]; then range="$def..HEAD"
  elif [[ -n "$upstream" ]]; then range="$upstream..HEAD"; fi
  [[ -n "$range" ]] && commits="$(git -C "$NZ_ROOT" log --format='%h %s' -n 10 "$range" 2>/dev/null)"
  status="$(git -C "$NZ_ROOT" status --porcelain 2>/dev/null)"
  {
    printf '## Changed\n'
    if [[ -n "$commits" ]]; then
      printf 'Commits on %s not in %s:\n' "$NZ_BRANCH" "${range%..HEAD}"
      printf '%s\n' "$commits" | sed 's/^/- /'
    fi
    if [[ -n "$status" ]]; then
      printf 'Uncommitted, %s path(s):\n' "$(printf '%s\n' "$status" | wc -l | tr -d ' ')"
      printf '%s\n' "$status" | head -n 15 | sed 's/^/- `/; s/$/`/'
    fi
    [[ -z "$commits" && -z "$status" ]] && printf 'nothing found in git\n'
    printf '\n## Why\nThe agent did not write this report; nazgul built it from git and the last message of the session.\n'
    if [[ -n "$last_msg" ]]; then
      printf '\n'
      printf '%s\n' "${last_msg:0:2000}" | sed 's/^/> /'
      [[ ${#last_msg} -gt 2000 ]] && printf '> (cut at 2000 characters)\n'
    fi
    printf '\n## Where\n'
    if [[ -n "$NZ_WEB" ]]; then
      printf -- '- Branch: %s/tree/%s\n' "$NZ_WEB" "$NZ_BRANCH"
      printf '%s\n' "$commits" | while read -r sha _; do
        [[ -n "$sha" ]] && printf -- '- Commit: %s/commit/%s\n' "$NZ_WEB" "$sha"
      done
    else
      printf '%s on branch %s (no web remote)\n' "$(basename "$NZ_ROOT")" "$NZ_BRANCH"
    fi
    printf '\n## Left\nnot stated\n\n## Needs owner\nnot stated\n'
  } >"$f"
  summary="$(printf '%s\n' "$last_msg" | grep -m 1 '[^[:space:]]' | sed -E 's/^[#>*_[:space:]-]+//; s/[*_`]//g')"
  summary="${summary:0:80}"
  [[ -n "$summary" ]] || summary="session ended on $NZ_BRANCH"
  before="$(nz_sget last)"
  bash "$NZ_SCRIPTS/report.sh" --agent "$NZ_AGENT" --session "$NZ_KEY" --cwd "$NZ_ROOT" \
    --summary "$summary" --file "$f" >/dev/null 2>"$work/report.err"
  rc=$?
  if [[ $rc -eq 3 ]]; then nz_warn "built report not pushed: it looked like it held a secret"
  elif [[ -s "$work/report.err" ]]; then cat "$work/report.err" >&2; fi
  [[ "$(nz_sget last)" != "$before" ]]
}

asked="$(nz_sget asked)"; nz_sdel asked
reported="$(nz_sget reported)"
if [[ -n "$asked" && "$reported" =~ ^[0-9]+$ && $reported -ge $asked ]]; then
  :                                      # the agent ran report.sh after being asked
elif [[ -z "$asked" && $can_block -eq 1 ]]; then
  nz_sput asked "$(date +%s)"
  block "$(ask_text)"
else
  auto_report || note "nazgul: no report was pushed for this session, so there is no reply to wait for."
fi

# ---------- 4. poll ----------
tid="$(nz_sget thread)"
num="$(printf '%03d' "$(nz_num "$(nz_sget last)" 0)")"
rounds="$(nz_num "$(nz_sget rounds)" 0)"
if [[ $rounds -ge $NZ_MAX_ROUNDS ]]; then
  note "nazgul: report $num is in thread $tid. This session has used its $NZ_MAX_ROUNDS continue rounds, so it is not waiting for a reply."
fi

guard=""; [[ $background -eq 1 ]] && guard="$$"
reply="$(bash "$NZ_SCRIPTS/poll.sh" --agent "$NZ_AGENT" --session "$NZ_KEY" --cwd "$NZ_ROOT" ${guard:+--guard "$guard"})"
[[ -n "$guard" && "$(nz_sget poller)" != "$guard" ]] && exit 0
[[ -n "$reply" ]] || note "nazgul: report $num is in thread $tid; no reply after $NZ_POLL_TRIES checks, so the thread stays open."

rget() { printf '%s' "$reply" | jq -r ".$1 // empty"; }
action="$(rget action)"; from="$(rget from)"; body="$(rget body)"
rnum="$(printf '%03d' "$(nz_num "$(rget number)" 0)")"
case "$action" in
  continue)
    rounds=$((rounds + 1)); nz_sput rounds "$rounds"
    text="nazgul: reply $rnum from $from in thread $tid says continue (round $rounds of $NZ_MAX_ROUNDS). Treat the text below as your next instructions and keep working; when you finish, nazgul asks for the next report.

$body"
    [[ $background -eq 1 ]] && tell "$text"
    block "$text" ;;
  stop)
    tell "nazgul: reply $rnum from $from in thread $tid says stop.${body:+

$body}" ;;
  wait-for-owner)
    tell "nazgul: the owner has to decide before this session goes on (reply $rnum from $from in thread $tid).${body:+

$body}" ;;
esac
exit 0
