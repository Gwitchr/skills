#!/usr/bin/env bash
# nazgul report.sh: write the next numbered message in this session's thread of the report repo.
#
#   report.sh --agent <claude|codex|grok|omp|cursor|other> [--session <id>] [--summary "<one line>"]
#             [--file <body.md>] [--cwd <dir>]
#
# The body comes from --file or stdin and holds five sections, each with text ("nothing" is fine):
#   ## Changed   ## Why   ## Where   ## Left   ## Needs owner
# report.sh adds the frontmatter, scans for secrets, and creates
#   projects/<project>/threads/<thread-id>/<NNN>_<agent>.md
# through the GitHub contents API with the commit message "nazgul(<project>): <summary>".
#
# Exit: 0 pushed, or nazgul is off here (no config, skip path), or the report repo could not be
#       reached (warned on stderr; a network or auth failure never breaks the session);
#       2 bad arguments or a missing section; 3 a secret was found and nothing was pushed.
set -u
# Find this script's folder. Some agent tools run commands in a bash that leaves BASH_SOURCE
# empty, so fall back to $0, then to NAZGUL_SCRIPTS, then to the default skill location.
nz_self="${BASH_SOURCE[0]:-}"; [[ -f "$nz_self" ]] || nz_self="$0"
NZ_SCRIPTS="$(cd "$(dirname "$nz_self")" 2>/dev/null && pwd -P)"
[[ -f "$NZ_SCRIPTS/lib.sh" ]] || NZ_SCRIPTS="${NAZGUL_SCRIPTS:-$HOME/.agents/skills/nazgul/scripts}"
[[ -f "$NZ_SCRIPTS/lib.sh" ]] || { printf 'nazgul: cannot find the scripts folder; set NAZGUL_SCRIPTS or run with /bin/bash\n' >&2; exit 2; }
. "$NZ_SCRIPTS/lib.sh"

usage() { sed -n '2,16p' "$NZ_SCRIPTS/report.sh" | sed 's/^# \{0,1\}//'; }

agent="other"; session="${NAZGUL_SESSION:-}"; summary=""; file=""; cwd="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --agent|--session|--summary|--file|--cwd)
      [[ $# -ge 2 ]] || { nz_warn "$1 needs a value"; exit 2; }
      case "$1" in
        --agent) agent="$2" ;; --session) session="$2" ;; --summary) summary="$2" ;;
        --file) file="$2" ;; --cwd) cwd="$2" ;;
      esac
      shift 2 ;;
    *) nz_warn "unknown argument: $1"; exit 2 ;;
  esac
done

nz_load "$cwd" || exit 0
for bin in jq gh; do
  command -v "$bin" >/dev/null 2>&1 || { nz_warn "$bin not found; report not pushed"; exit 0; }
done
NZ_AGENT="$(nz_agent "$agent")"
nz_session "$session" "$NZ_AGENT"

work="$(mktemp -d "${TMPDIR:-/tmp}/nazgul.XXXXXX")" || { nz_warn "no temp dir; report not pushed"; exit 0; }
trap 'rm -rf "$work"' EXIT

if [[ -n "$file" ]]; then
  [[ -f "$file" ]] || { nz_warn "no such file: $file"; exit 2; }
  cat "$file" >"$work/body.md"
elif [[ ! -t 0 ]]; then
  cat >"$work/body.md"
else
  nz_warn "no report body: pass --file or pipe the sections on stdin"; exit 2
fi

if [[ "$(head -n 1 "$work/body.md" | tr -d '\r')" == "---" ]]; then
  nz_warn "leave out the frontmatter; report.sh writes it"; exit 2
fi

missing="$(awk -v req="$NZ_SECTIONS" '
  BEGIN { n = split(req, r, "|") }
  { sub(/\r$/, "") }
  /^##[ \t]+/ { h = $0; sub(/^##[ \t]+/, "", h); sub(/[ \t:]+$/, "", h); cur = tolower(h); seen[cur] = 1; next }
  /^#[ \t]/ { cur = ""; next }
  cur != "" && $0 ~ /[^ \t]/ { filled[cur] = 1 }
  END {
    for (i = 1; i <= n; i++) {
      k = tolower(r[i])
      if (!(k in seen)) print "## " r[i] " (missing)"
      else if (!(k in filled)) print "## " r[i] " (empty; write \"nothing\" if there is nothing)"
    }
  }' "$work/body.md")"
if [[ -n "$missing" ]]; then
  nz_warn "the report needs every section; fix these and run again:"
  printf '%s\n' "$missing" >&2
  exit 2
fi

summary="$(printf '%s' "$summary" | tr '\r\n\t' '   ' | sed -E 's/  +/ /g; s/^ //; s/ $//')"
if [[ -z "$summary" ]]; then
  summary="$(awk '
    { sub(/\r$/, "") }
    /^##[ \t]+/ { on = (tolower($0) ~ /^##[ \t]+changed/); next }
    on && $0 ~ /[^ \t]/ { sub(/^[ \t]*([-*+]|[0-9]+\.)?[ \t]*/, ""); print; exit }' "$work/body.md")"
fi
summary="${summary:0:100}"
[[ -n "$summary" ]] || summary="session report"

when="$(date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/')"
printf '%s\n' "$summary" >"$work/scan.md"
tr -d '\r' <"$work/body.md" >>"$work/scan.md"
if hit="$(nz_scan "$work/scan.md")"; then :; else
  nz_warn "refusing to push: possible secret ($hit, counting the summary as line 1). Remove it and run again."
  exit 3
fi

# A session keeps its thread. A new one takes date_time_agent_branch, plus -2, -3, ... when another
# session already holds that folder, so two sessions never share a thread.
tid="$(nz_sget thread)"; new=0; base=""; suffix=1
if ! nz_thread_ok "$tid"; then
  new=1; base="$(date +%Y-%m-%d_%H%M)_${NZ_AGENT}_${NZ_BRANCH_SLUG}"; tid="$base"
fi

attempt=0
while [[ $attempt -lt 8 ]]; do
  attempt=$((attempt + 1))
  dir="projects/$NZ_PROJECT/threads/$tid"
  names="$(nz_list "$dir")"; rc=$?
  if [[ $rc -eq 1 ]]; then nz_warn "could not read the report repo ($NZ_ERR); report not pushed"; exit 0; fi
  if [[ $new -eq 1 && $rc -eq 0 ]]; then suffix=$((suffix + 1)); tid="$base-$suffix"; continue; fi
  top="$(printf '%s\n' "$names" | nz_numbers | head -n 1)"
  n=$(( ${top:-0} + 1 ))
  path="$dir/$(printf '%03d' "$n")_${NZ_AGENT}.md"
  [[ "$path" =~ ^projects/[A-Za-z0-9._-]+/threads/[A-Za-z0-9._-]+/[0-9]{3,}_[a-z]+\.md$ ]] \
    || { nz_warn "refusing to write outside the project folder: $path"; exit 2; }
  {
    printf -- '---\n'
    printf 'project: %s\n' "$NZ_PROJECT"
    printf 'agent: %s\n' "$NZ_AGENT"
    printf 'repo: %s\n' "${NZ_ORIGIN:-$(basename "$NZ_ROOT")}"
    printf 'branch: %s\n' "$NZ_BRANCH"
    printf 'date: %s\n' "$when"
    printf 'thread: %s\n' "$tid"
    printf -- '---\n\n'
    tr -d '\r' <"$work/body.md"
  } >"$work/message.md"
  nz_put "$path" "$work/message.md" "nazgul($NZ_PROJECT): $summary"; rc=$?
  case $rc in
    0)
      nz_sput thread "$tid"
      nz_sput branch "$NZ_BRANCH"
      nz_sput last "$n"
      nz_sput reported "$(date +%s)"
      printf 'nazgul: pushed %s\n' "$path"
      printf 'nazgul: https://github.com/%s/blob/HEAD/%s\n' "$NZ_REPO" "$path"
      exit 0 ;;
    5) if [[ $new -eq 1 ]]; then suffix=$((suffix + 1)); tid="$base-$suffix"; fi ;;
    *) nz_warn "push failed ($NZ_ERR); report not pushed"; exit 0 ;;
  esac
done
nz_warn "could not find a free message number or thread in the report repo; report not pushed"
exit 0
