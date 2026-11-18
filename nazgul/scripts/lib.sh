# nazgul shared helpers, sourced by the other scripts in this folder. Not meant to be run.
# bash 3.2 compatible. Needs git, jq and gh (already authenticated); perl is optional (timeouts).
#
# Config, read line by line and never sourced:
#   ${NAZGUL_CONFIG:-${XDG_CONFIG_HOME:-~/.config}/nazgul/config}
#       repo=<owner/repo>   the report repo (NAZGUL_REPO overrides it)
#       skip_paths=<dir:dir> folders where nazgul does nothing
#       max_rounds=<n>      continue rounds per session, default 3
#       poll_tries=<n>      default 5 (NAZGUL_POLL_TRIES overrides it)
#       poll_interval=<s>   default 120 (NAZGUL_POLL_INTERVAL overrides it)
#   <project root>/.nazgul
#       project=<slug>      default: the repo folder name
#       max_rounds=<n>      overrides the user value
# Local state lives in <git common dir>/nazgul/, so it is never committed and every worktree shares it.

NZ_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
NZ_SKILL="$(dirname "$NZ_SCRIPTS")"
NZ_USER_CONFIG="${NAZGUL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nazgul/config}"
NZ_SECTIONS="Changed|Why|Where|Left|Needs owner"
NZ_ERR=""

nz_warn() { printf 'nazgul: %s\n' "$*" >&2; }

# nz_kv <file> <key>: prints the last value of key=<value> in file; returns 1 when absent.
nz_kv() {
  local file="$1" key="$2" line val="" found=1
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == "$key="* ]] || continue
    val="${line#*=}"
    val="${val%"${val##*[![:space:]]}"}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    found=0
  done <"$file"
  [[ $found -eq 0 ]] && printf '%s' "$val"
  return $found
}

nz_num() { if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# nz_slug <text> [max]: letters, digits, dot, underscore and dash; anything else becomes a dash.
nz_slug() {
  local s
  s="$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | LC_ALL=C sed -e 's/--*/-/g' -e 's/^[.-]*//')"
  s="${s:0:${2:-60}}"
  printf '%s' "${s%-}"
}

nz_agent() {
  case "$1" in
    claude|codex|grok|omp|cursor|other) printf '%s' "$1" ;;
    *) printf 'other' ;;
  esac
}

# nz_skipped <physical dir>: true when dir is a skip path or sits under one.
nz_skipped() {
  local path="$1" rest="${NZ_SKIP:-}:" s
  while [[ -n "$rest" ]]; do
    s="${rest%%:*}"; rest="${rest#*:}"
    [[ -n "$s" ]] || continue
    s="${s/#\~/$HOME}"
    s="$(cd "$s" 2>/dev/null && pwd -P)" || continue
    s="${s%/}"
    [[ "$path" == "$s" || "$path" == "$s"/* ]] && return 0
  done
  return 1
}

# nz_origin: NZ_ORIGIN=<owner/repo> and NZ_WEB=https://<host>/<owner/repo> from the origin remote.
# Only the host and path are kept, so a credential inside the remote URL is never printed.
nz_origin() {
  local url host path re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+$'
  NZ_ORIGIN=""; NZ_WEB=""
  url="$(git -C "$NZ_ROOT" remote get-url origin 2>/dev/null)" || return 0
  case "$url" in
    *://*) url="${url#*://}"; url="${url#*@}"; host="${url%%/*}"; path="${url#*/}" ;;
    *@*:*) url="${url#*@}"; host="${url%%:*}"; path="${url#*:}" ;;
    *) return 0 ;;
  esac
  host="${host%%:*}"; path="${path%/}"; path="${path%.git}"
  [[ -n "$host" && "$path" =~ $re ]] || return 0
  NZ_ORIGIN="$path"; NZ_WEB="https://$host/$path"
}

# nz_load [dir]: loads config and project context for dir. Returns 1 and prints nothing when nazgul
# is off there: NAZGUL_OFF=1, no report repo, dir under a skip path, or dir outside a git work tree.
nz_load() {
  local dir="${1:-$PWD}" re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' common v
  [[ "${NAZGUL_OFF:-}" == 1 ]] && return 1
  NZ_REPO="${NAZGUL_REPO:-$(nz_kv "$NZ_USER_CONFIG" repo)}"
  [[ "$NZ_REPO" =~ $re ]] || return 1
  NZ_SKIP="$(nz_kv "$NZ_USER_CONFIG" skip_paths)"
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  nz_skipped "$dir" && return 1
  NZ_ROOT="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$NZ_ROOT" ]] || return 1
  common="$(cd "$NZ_ROOT" && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  common="$(cd "$NZ_ROOT" && cd "$common" 2>/dev/null && pwd -P)" || return 1
  NZ_STATE="$common/nazgul"
  v="$(nz_kv "$NZ_ROOT/.nazgul" project)"
  if [[ -z "$v" ]]; then
    v="$(basename "$common")"
    [[ "$v" == .git ]] && v="$(basename "$(dirname "$common")")"
    v="${v%.git}"
  fi
  NZ_PROJECT="$(nz_slug "$v")"
  [[ -n "$NZ_PROJECT" ]] || return 1
  NZ_BRANCH="$(git -C "$NZ_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)" || NZ_BRANCH="detached"
  NZ_BRANCH_SLUG="$(nz_slug "$NZ_BRANCH" 40)"
  [[ -n "$NZ_BRANCH_SLUG" ]] || NZ_BRANCH_SLUG="branch"
  v="$(nz_kv "$NZ_ROOT/.nazgul" max_rounds || nz_kv "$NZ_USER_CONFIG" max_rounds)"
  NZ_MAX_ROUNDS="$(nz_num "$v" 3)"
  NZ_POLL_TRIES="$(nz_num "${NAZGUL_POLL_TRIES:-$(nz_kv "$NZ_USER_CONFIG" poll_tries)}" 5)"
  NZ_POLL_INTERVAL="$(nz_num "${NAZGUL_POLL_INTERVAL:-$(nz_kv "$NZ_USER_CONFIG" poll_interval)}" 120)"
  nz_origin
  return 0
}

# nz_session <raw id> <agent>: NZ_KEY names this session's local state. Without an id the key is
# <agent>_<branch>, so an agent that has no session id keeps one thread per branch.
nz_session() {
  local k
  k="$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-')"
  k="${k:0:80}"
  [[ "$k" =~ [A-Za-z0-9] ]] || k="${2}_${NZ_BRANCH_SLUG}"
  NZ_KEY="$k"
}

# Per-session state: one value per file under $NZ_STATE/sessions, mode 600. Reads and writes fail soft.
nz_sget() { local f="$NZ_STATE/sessions/$NZ_KEY.$1"; [[ -f "$f" ]] && head -n 1 "$f" 2>/dev/null; return 0; }
nz_sput() {
  (umask 077; mkdir -p "$NZ_STATE/sessions" && printf '%s\n' "$2" >"$NZ_STATE/sessions/$NZ_KEY.$1"
    find "$NZ_STATE/sessions" -type f -mtime +30 -delete) >/dev/null 2>&1
  return 0
}
nz_sdel() { rm -f "$NZ_STATE/sessions/$NZ_KEY.$1" 2>/dev/null; return 0; }

nz_thread_ok() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}_[A-Za-z0-9._-]+$ ]]; }

# nz_limit <seconds> <cmd...>: runs cmd under an alarm when perl exists (macOS has no timeout(1)).
nz_limit() {
  local s="$1"; shift
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$s" "$@"; else "$@"; fi
}

nz_tmp() { mktemp "${TMPDIR:-/tmp}/nazgul.XXXXXX"; }

# nz_list <dir>: file names in <dir> of the report repo, one per line.
# Returns 0 listed (maybe empty), 4 folder not found, 1 network or auth error (NZ_ERR says which).
nz_list() {
  local out err rc
  command -v gh >/dev/null 2>&1 || { NZ_ERR="gh not found"; return 1; }
  err="$(nz_tmp)" || { NZ_ERR="no temp file"; return 1; }
  out="$(nz_limit 30 gh api "repos/$NZ_REPO/contents/$1" \
    --jq 'if type=="array" then .[] | select(.type=="file") | .name else empty end' 2>"$err")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    if grep -q 'HTTP 404' "$err" 2>/dev/null; then rm -f "$err"; return 4; fi
    NZ_ERR="$(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')"; [[ -n "$NZ_ERR" ]] || NZ_ERR="gh exit $rc"
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# nz_read <path>: raw content of a file in the report repo.
nz_read() {
  nz_limit 30 gh api -H 'Accept: application/vnd.github.raw+json' "repos/$NZ_REPO/contents/$1" 2>/dev/null
}

# nz_put <path> <local file> <commit message>: creates path in the report repo through the contents
# API. No sha is ever sent, so an existing file is never replaced. Returns 0 created, 5 path taken
# (or the branch moved under us), 1 network or auth error (NZ_ERR says which).
nz_put() {
  local b64 err rc
  b64="$(nz_tmp)" && err="$(nz_tmp)" || { NZ_ERR="no temp file"; return 1; }
  base64 <"$2" | tr -d '\n' >"$b64"
  jq -n --arg m "$3" --rawfile c "$b64" '{message: $m, content: $c}' \
    | nz_limit 30 gh api -X PUT "repos/$NZ_REPO/contents/$1" --input - --jq '.content.path' >/dev/null 2>"$err"
  rc=$?
  if [[ $rc -eq 0 ]]; then rm -f "$b64" "$err"; return 0; fi
  if grep -qE 'HTTP (409|422)' "$err" 2>/dev/null; then rm -f "$b64" "$err"; return 5; fi
  NZ_ERR="$(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')"; [[ -n "$NZ_ERR" ]] || NZ_ERR="gh exit $rc"
  rm -f "$b64" "$err"
  return 1
}

# nz_numbers: reads file names on stdin, prints the message numbers (decimal), highest first.
nz_numbers() { sed -nE 's/^0*([0-9]+)_[A-Za-z0-9._-]+\.md$/\1/p' | sort -rn; }

# Secret patterns for the fallback scan, one per entry as <rule>=<extended regex>.
NZ_SECRET_RES=(
  'private-key=-----BEGIN [A-Z ]*PRIVATE KEY'
  'aws-access-key=(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}'
  'github-token=(^|[^A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,}'
  'github-pat=github_pat_[A-Za-z0-9_]{30,}'
  'gitlab-token=glpat-[A-Za-z0-9_-]{20,}'
  'slack-token=xox[abposr]-[A-Za-z0-9-]{10,}'
  'api-key-sk=(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'
  'google-api-key=AIza[0-9A-Za-z_-]{35}'
  'stripe-key=(^|[^A-Za-z0-9])[rs]k_live_[0-9A-Za-z]{20,}'
  'npm-token=(^|[^A-Za-z0-9])npm_[A-Za-z0-9]{36}'
  'jwt=eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  'url-credentials=[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]+@'
)
NZ_SECRET_GENERIC='(api[_-]?key|secret|token|passw(or)?d|credential)s?["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+_.=-]{16,}'

# nz_scan <file>: returns 0 when the file looks clean. On a hit prints "<rule> line <n>" (never the
# match itself) and returns 1. Uses gitleaks when installed, else the patterns above.
nz_scan() {
  local f="$1" dir rep rc hit entry
  if command -v gitleaks >/dev/null 2>&1; then
    dir="$(mktemp -d "${TMPDIR:-/tmp}/nazgul.XXXXXX")" && rep="$dir.json"
    cp "$f" "$dir/report.md"
    gitleaks dir "$dir" --no-banner --redact --exit-code 3 --log-level error \
      --report-format json --report-path "$rep" >/dev/null 2>&1
    rc=$?
    if [[ $rc -ne 0 && $rc -ne 3 ]]; then
      gitleaks detect --no-git --source "$dir" --no-banner --redact --exit-code 3 --log-level error \
        --report-format json --report-path "$rep" >/dev/null 2>&1
      rc=$?
    fi
    if [[ $rc -eq 3 ]]; then
      hit="$(jq -r '.[0] | "gitleaks \(.RuleID) line \(.StartLine)"' "$rep" 2>/dev/null)"
      rm -rf "$dir" "$rep"
      printf '%s\n' "${hit:-gitleaks finding}"
      return 1
    fi
    rm -rf "$dir" "$rep"
    [[ $rc -eq 0 ]] && return 0
  fi
  for entry in "${NZ_SECRET_RES[@]}"; do
    hit="$(LC_ALL=C grep -nE -- "${entry#*=}" "$f" 2>/dev/null | head -n 1 | cut -d: -f1)"
    [[ -n "$hit" ]] && { printf '%s line %s\n' "${entry%%=*}" "$hit"; return 1; }
  done
  hit="$(LC_ALL=C grep -niE -- "$NZ_SECRET_GENERIC" "$f" 2>/dev/null | head -n 1 | cut -d: -f1)"
  [[ -n "$hit" ]] && { printf 'generic-secret line %s\n' "$hit"; return 1; }
  return 0
}

# nz_fm <file> <key>: a frontmatter value, quotes and CR stripped.
nz_fm() {
  awk -v k="$2" '
    NR == 1 { sub(/\r$/, ""); if ($0 != "---") exit; next }
    { sub(/\r$/, "") }
    $0 == "---" { exit }
    {
      i = index($0, ":"); if (i == 0) next
      key = substr($0, 1, i - 1); val = substr($0, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (key == k) { gsub(/^["\047]|["\047]$/, "", val); print val; exit }
    }' "$1"
}

# nz_body <file>: everything after the frontmatter, leading blank lines dropped.
nz_body() {
  awk '
    NR == 1 { sub(/\r$/, ""); if ($0 == "---") { fm = 1; next } }
    { sub(/\r$/, "") }
    fm && $0 == "---" { fm = 0; next }
    fm { next }
    !started && $0 ~ /^[ \t]*$/ { next }
    { started = 1; print }' "$1"
}
