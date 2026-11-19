#!/usr/bin/env bash
# nazgul poll.sh: look for a reply in this session's thread of the report repo.
#
#   poll.sh [--agent <name>] [--session <id>] [--tries N] [--interval S] [--now] [--cwd <dir>]
#
# Waits --interval seconds (default 120), checks, and repeats up to --tries times (default 5), so a
# thread with no reply costs about 10 minutes. --now checks once at once, with no wait.
# It reads only projects/<project>/threads/<this session's thread>/ and only messages numbered
# after this session's last report. A reply counts only when nz_reply_gate accepts the commit that
# last wrote that file (allowlisted author, and verified when require_verified is true). The
# file body is not read until the commit passes. A reply that fails is ignored, with a one-line
# note on stderr, and is not treated as a reply. With no reply_authors, nothing is read and nothing
# is acted on. A reply that passes needs frontmatter with
#   action: continue | stop | wait-for-owner      (in_reply_to: is read when present)
# and in_reply_to, when set, must equal the number of this session's last report.
# The newest valid reply wins. It prints one JSON object and exits 0:
#   {"number":2,"path":"...","from":"...","action":"continue","in_reply_to":"1","body":"..."}
# "from" is the commit's GitHub author login, not the from: line in the file.
# It prints nothing and exits 0 when there is no reply, no thread yet, no config, or the repo cannot
# be reached (warned on stderr).
set -u
# Find this script's folder. Some agent tools run commands in a bash that leaves BASH_SOURCE
# empty, so fall back to $0, then to NAZGUL_SCRIPTS, then to the default skill location.
nz_self="${BASH_SOURCE[0]:-}"; [[ -f "$nz_self" ]] || nz_self="$0"
NZ_SCRIPTS="$(cd "$(dirname "$nz_self")" 2>/dev/null && pwd -P)"
[[ -f "$NZ_SCRIPTS/lib.sh" ]] || NZ_SCRIPTS="${NAZGUL_SCRIPTS:-$HOME/.agents/skills/nazgul/scripts}"
[[ -f "$NZ_SCRIPTS/lib.sh" ]] || { printf 'nazgul: cannot find the scripts folder; set NAZGUL_SCRIPTS or run with /bin/bash\n' >&2; exit 2; }
. "$NZ_SCRIPTS/lib.sh"

usage() { sed -n '2,20p' "$NZ_SCRIPTS/poll.sh" | sed 's/^# \{0,1\}//'; }

agent="other"; session="${NAZGUL_SESSION:-}"; tries=""; interval=""; now=0; cwd="$PWD"; guard=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --now) now=1; shift ;;
    --agent|--session|--tries|--interval|--cwd|--guard)
      [[ $# -ge 2 ]] || { nz_warn "$1 needs a value"; exit 2; }
      case "$1" in
        --agent) agent="$2" ;; --session) session="$2" ;; --tries) tries="$2" ;;
        --interval) interval="$2" ;; --cwd) cwd="$2" ;; --guard) guard="$2" ;;
      esac
      shift 2 ;;
    *) nz_warn "unknown argument: $1"; exit 2 ;;
  esac
done

nz_load "$cwd" || exit 0
for bin in jq gh; do command -v "$bin" >/dev/null 2>&1 || { nz_warn "$bin not found; not polling"; exit 0; }; done
NZ_AGENT="$(nz_agent "$agent")"
nz_session "$session" "$NZ_AGENT"
tries="$(nz_num "$tries" "$NZ_POLL_TRIES")"
interval="$(nz_num "$interval" "$NZ_POLL_INTERVAL")"
[[ $now -eq 1 ]] && tries=1

tid="$(nz_sget thread)"; last="$(nz_sget last)"
nz_thread_ok "$tid" && [[ "$last" =~ ^[0-9]+$ ]] || exit 0
dir="projects/$NZ_PROJECT/threads/$tid"

work="$(mktemp -d "${TMPDIR:-/tmp}/nazgul.XXXXXX")" || exit 0
trap 'rm -rf "$work"' EXIT

# Prints the newest valid reply as JSON; returns 1 when there is none.
# The commit is checked before the file is read, so a reply that is not allowlisted or not verified
# never has its body loaded.
find_reply() {
  local names n name f action from irt
  if [[ -z "$(nz_fold "${NZ_REPLY_AUTHORS:-}")" ]]; then
    nz_warn "reply_authors is not set; not acting on replies"
    return 1
  fi
  names="$(nz_list "$dir")"
  case $? in
    0) ;;
    4) return 1 ;;
    *) nz_warn "could not read the report repo ($NZ_ERR)"; return 1 ;;
  esac
  for n in $(printf '%s\n' "$names" | nz_numbers); do
    [[ $n -gt $last ]] || break
    name="$(printf '%s\n' "$names" | grep -E "^0*${n}_[A-Za-z0-9._-]+\.md$" | head -n 1)"
    [[ -n "$name" ]] || continue
    if ! from="$(nz_reply_gate "$dir/$name")"; then
      nz_warn "ignored $name: $from"
      continue
    fi
    f="$work/$name"
    nz_read "$dir/$name" >"$f" || continue
    action="$(nz_fm "$f" action | tr 'A-Z_ ' 'a-z--')"
    case "$action" in continue|stop|wait-for-owner) ;; *) continue ;; esac
    irt="$(nz_fm "$f" in_reply_to | tr -cd '0-9')"
    if [[ -n "$irt" && $((10#$irt)) -ne $last ]]; then continue; fi
    nz_body "$f" | head -c 20000 >"$f.body"
    jq -n --argjson number "$n" --arg path "$dir/$name" --arg from "$from" --arg action "$action" \
      --arg irt "$irt" --rawfile body "$f.body" \
      '{number: $number, path: $path, from: $from, action: $action, in_reply_to: $irt,
        body: ($body | sub("\\s+$"; ""))}'
    return 0
  done
  return 1
}

i=0
while [[ $i -lt $tries ]]; do
  i=$((i + 1))
  [[ $now -eq 1 ]] || sleep "$interval"
  # A newer background poller for this session takes over; this one stops quietly.
  if [[ -n "$guard" && "$(nz_sget poller)" != "$guard" ]]; then exit 0; fi
  if out="$(find_reply)" && [[ -n "$out" ]]; then printf '%s\n' "$out"; exit 0; fi
done
exit 0
