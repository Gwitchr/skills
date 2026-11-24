# nazgul shared helpers, sourced by the other scripts in this folder. Not meant to be run.
# bash 3.2 compatible. Needs git, jq and gh (already authenticated); perl is optional (timeouts).
#
# Config, one file per user, read line by line and never sourced:
#   ${NAZGUL_CONFIG:-${XDG_CONFIG_HOME:-~/.config}/nazgul/config}
#       repo=<owner/repo>       the report repo (NAZGUL_REPO overrides it)
#       skip_paths=<dir:dir>    folders where nazgul does nothing, even in an enrolled repo
#       max_rounds=<n>          continue rounds per session, default 3
#       poll_tries=<n>          default 5 (NAZGUL_POLL_TRIES overrides it)
#       poll_interval=<s>       default 120 (NAZGUL_POLL_INTERVAL overrides it)
#       reply_authors=<logins>  GitHub logins, comma-separated, whose replies may be acted on.
#                               Unset: no reply is acted on (the report is still pushed).
#       auto_continue=true|false  default false. true: a continue reply is the agent's next
#                               instructions. false: it is shown to the user and the session ends.
#       require_verified=true|false  default false: an allowlisted author is enough. true: the
#                               commit also has to be one GitHub reports as verified.
#       speak=true|false         default false; speak report and reply alerts on macOS.
#
#       [project "/abs/path/to/repo.git"]   one section per enrolled repo, keyed by its git common dir
#       slug=<slug>             optional; default: the repo name without .git
#       max_rounds=<n>          optional; overrides the value above for this repo
# A repo with no section is not enrolled, and every script exits at once there. Every worktree of a
# repo shares its git common dir, so one section covers all of them.
# Local state lives in <git common dir>/nazgul/: never in a work tree, shared by every worktree.

# The calling script sets NZ_SCRIPTS before sourcing this file; BASH_SOURCE is the fallback.
NZ_SCRIPTS="${NZ_SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd -P)}"
NZ_SKILL="$(dirname "$NZ_SCRIPTS")"
NZ_USER_CONFIG="${NAZGUL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nazgul/config}"
NZ_SECTIONS="Changed|Why|Where|Left|Needs owner"
NZ_ERR=""

nz_warn() { printf 'nazgul: %s\n' "$*" >&2; }

# A fixed, non-sensitive alert; never hold up a report or hook if speech fails.
nz_speak() {
  [[ "$(nz_cfg "" speak)" == true ]] || return 0
  [[ "$(uname -s 2>/dev/null)" == Darwin ]] || return 0
  command -v say >/dev/null 2>&1 || return 0
  say "$1" </dev/null >/dev/null 2>&1 &
  return 0
}

# The awk below reads section headers: [project "<path>"] gives <path>; any other [header] gives \001,
# which matches no section anyone asks for. Lines before the first header are the top level ("").
NZ_AWK_HEADER='
  function header(line,   s) {
    s = line
    if (s ~ /^[ \t]*\[project "[^"]*"\][ \t]*$/) { sub(/^[ \t]*\[project "/, "", s); sub(/"\][ \t]*$/, "", s); return s }
    return "\001"
  }
  function is_header(line) { return line ~ /^[ \t]*\[/ }'

# nz_cfg <section> <key>: the last value of key in that section of the user config ("" is the top
# level). Inline comments after whitespace and surrounding quotes are dropped. Returns 1 when absent.
nz_cfg() {
  [[ -f "$NZ_USER_CONFIG" ]] || return 1
  NZ_A_SEC="$1" NZ_A_KEY="$2" awk "$NZ_AWK_HEADER"'
    BEGIN { want = ENVIRON["NZ_A_SEC"]; key = ENVIRON["NZ_A_KEY"]; cur = "" }
    { line = $0; sub(/\r$/, "", line) }
    is_header(line) { cur = header(line); next }
    cur == want && line ~ ("^[ \t]*" key "[ \t]*=") {
      v = substr(line, index(line, "=") + 1)
      sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      val = v; found = 1
    }
    END { if (!found) exit 1; printf "%s", val }' "$NZ_USER_CONFIG"
}

# nz_projects: the path of every [project "<path>"] section, one per line.
nz_projects() {
  [[ -f "$NZ_USER_CONFIG" ]] || return 0
  awk "$NZ_AWK_HEADER"'{ line = $0; sub(/\r$/, "", line) } is_header(line) { s = header(line); if (s != "\001") print s }' "$NZ_USER_CONFIG"
}

nz_enrolled() { nz_projects | grep -qxF -- "$1"; }

# nz_cfg_edit <mode> <section> [key] [value]: rewrites the user config (mode 600), keeping every
# other line as it was.
#   set    key=value in the section; creates the section when missing
#   unset  drops key from the section
#   add    creates the section when missing
#   drop   removes the section and the blank lines in front of it
nz_cfg_edit() {
  local f="$NZ_USER_CONFIG" tmp
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$(nz_tmp)" || return 1
  { [[ -f "$f" ]] && cat "$f"; } | NZ_A_MODE="$1" NZ_A_SEC="$2" NZ_A_KEY="${3:-}" NZ_A_VAL="${4:-}" awk "$NZ_AWK_HEADER"'
    function flush() { printf "%s", blanks; blanks = "" }
    function put() { if (mode == "set" && !done) print key "=" val; done = 1 }
    BEGIN {
      mode = ENVIRON["NZ_A_MODE"]; want = ENVIRON["NZ_A_SEC"]; key = ENVIRON["NZ_A_KEY"]; val = ENVIRON["NZ_A_VAL"]
      cur = ""; seen = (want == ""); blanks = ""
    }
    {
      line = $0; sub(/\r$/, "", line)
      if (is_header(line)) {
        nxt = header(line)
        if (cur == want && mode == "set") put()
        if (nxt == want) { seen = 1; if (mode == "drop") { blanks = ""; cur = nxt; next } }
        flush(); cur = nxt; print $0; next
      }
      if (cur == want && mode == "drop" && want != "") { if (line ~ /^[ \t]*$/) blanks = blanks $0 "\n"; next }
      if (line ~ /^[ \t]*$/) { blanks = blanks $0 "\n"; next }
      if (cur == want && (mode == "set" || mode == "unset") && line ~ ("^[ \t]*" key "[ \t]*=")) {
        flush(); put(); next
      }
      flush(); print $0
    }
    END {
      if (mode == "drop" && cur == want) blanks = ""
      if ((mode == "set" || mode == "add") && !seen) {
        flush(); if (NR > 0) print ""
        print "[project \"" want "\"]"; put()
      } else if (mode == "set" && cur == want) { put(); flush() }
      else flush()
    }' >"$tmp" || { rm -f "$tmp"; return 1; }
  if [[ -f "$f" ]]; then cat "$tmp" >"$f" && rm -f "$tmp" && chmod 600 "$f"   # in place: keeps a symlink
  else chmod 600 "$tmp" && mv "$tmp" "$f"; fi
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

# nz_common <dir>: the physical path of the git common dir for dir (a work tree or a bare repo).
nz_common() {
  local d="$1" top c
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]] && d="$top"
  c="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  (cd "$d" && cd "$c" 2>/dev/null && pwd -P)
}

# nz_default_slug <common dir>: the repo name. /x/gadget.git -> gadget; /x/widget/.git -> widget;
# /x/gadget/.bare -> gadget.
nz_default_slug() {
  local v
  v="$(basename "$1")"
  case "$v" in .*) v="$(basename "$(dirname "$1")")" ;; esac
  nz_slug "${v%.git}"
}

# nz_load [dir]: loads config and project context for dir. Returns 1 and prints nothing when nazgul
# is off there: NAZGUL_OFF=1, no config, dir outside a git work tree, repo not enrolled, no report
# repo, or dir under a skip path. Cheap on purpose: the hooks are user-level and run in every repo.
nz_load() {
  local dir="${1:-$PWD}" re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' v
  [[ "${NAZGUL_OFF:-}" == 1 ]] && return 1
  [[ -f "$NZ_USER_CONFIG" ]] || return 1
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  NZ_ROOT="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$NZ_ROOT" ]] || return 1
  NZ_COMMON="$(nz_common "$NZ_ROOT")" || return 1
  nz_enrolled "$NZ_COMMON" || return 1
  NZ_REPO="${NAZGUL_REPO:-$(nz_cfg "" repo)}"
  [[ "$NZ_REPO" =~ $re ]] || return 1
  NZ_SKIP="$(nz_cfg "" skip_paths)"
  nz_skipped "$dir" && return 1
  NZ_STATE="$NZ_COMMON/nazgul"
  v="$(nz_cfg "$NZ_COMMON" slug)"
  [[ -n "$v" ]] || v="$(nz_default_slug "$NZ_COMMON")"
  NZ_PROJECT="$(nz_slug "$v")"
  [[ -n "$NZ_PROJECT" ]] || return 1
  NZ_BRANCH="$(git -C "$NZ_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)" || NZ_BRANCH="detached"
  NZ_BRANCH_SLUG="$(nz_slug "$NZ_BRANCH" 40)"
  [[ -n "$NZ_BRANCH_SLUG" ]] || NZ_BRANCH_SLUG="branch"
  v="$(nz_cfg "$NZ_COMMON" max_rounds || nz_cfg "" max_rounds)"
  NZ_MAX_ROUNDS="$(nz_num "$v" 3)"
  NZ_POLL_TRIES="$(nz_num "${NAZGUL_POLL_TRIES:-$(nz_cfg "" poll_tries)}" 5)"
  NZ_POLL_INTERVAL="$(nz_num "${NAZGUL_POLL_INTERVAL:-$(nz_cfg "" poll_interval)}" 120)"
  NZ_REPLY_AUTHORS="$(nz_cfg "" reply_authors)" || NZ_REPLY_AUTHORS=""
  v="$(nz_cfg "" auto_continue)" || v=""
  if [[ "$v" == true ]]; then NZ_AUTO_CONTINUE=true; else NZ_AUTO_CONTINUE=false; fi
  v="$(nz_cfg "" require_verified)" || v=""
  if [[ "$v" == true ]]; then NZ_REQUIRE_VERIFIED=true; else NZ_REQUIRE_VERIFIED=false; fi
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

# nz_fold <login>: lowercase, whitespace removed, for a GitHub login comparison.
nz_fold() { printf '%s' "$1" | tr -d '[:space:]' | tr 'A-Z' 'a-z'; }

# nz_author_allowed <login>: true when login is one of reply_authors. Comparison is case-insensitive.
# An empty reply_authors allows nobody.
nz_author_allowed() {
  local want rest a
  want="$(nz_fold "$1")"
  [[ -n "$want" ]] || return 1
  rest="${NZ_REPLY_AUTHORS:-},"
  while [[ -n "$rest" ]]; do
    a="$(nz_fold "${rest%%,*}")"
    rest="${rest#*,}"
    [[ -n "$a" && "$a" == "$want" ]] && return 0
  done
  return 1
}

# A login safe to print: letters, digits, brackets (bot logins), underscore and dash.
nz_login_shown() { printf '%s' "$1" | tr -cd 'A-Za-z0-9_[]-' | cut -c1-60; }

# nz_commit_meta <path>: one TSV line for the newest commit that touches path:
#   author_login \t committer_login \t true|false \t reason
# Returns 0 when a commit exists, 4 when the path has none, 1 on error (NZ_ERR).
# The newest commit is the one that last wrote the file. For a file that was only added, that is
# the commit that added it; a later edit has to pass the same check.
nz_commit_meta() {
  local out err rc
  NZ_ERR=""
  command -v gh >/dev/null 2>&1 || { NZ_ERR="gh not found"; return 1; }
  err="$(nz_tmp)" || { NZ_ERR="no temp file"; return 1; }
  out="$(nz_limit 30 gh api "repos/$NZ_REPO/commits?path=$1&per_page=1" \
    --jq 'if type=="array" and length>0 then .[0] | [(.author.login // ""), (.committer.login // ""), ((.commit.verification.verified // false)|tostring), (.commit.verification.reason // "unsigned")] | @tsv else empty end' 2>"$err")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    NZ_ERR="$(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')"
    [[ -n "$NZ_ERR" ]] || NZ_ERR="gh exit $rc"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  [[ -n "$out" ]] || return 4
  printf '%s\n' "$out" | head -n 1
  return 0
}

# nz_reply_gate <path>: the newest commit on path may be acted on.
# Success prints the author login. Failure prints a short reason and returns 1.
# The author login has to be in reply_authors. When require_verified is true, GitHub has to
# report the commit verified, and the signature has to be that author's (committer login equals
# the author) or GitHub's (committer login web-flow, the signature GitHub puts on a commit it
# signs). Verification attests the committer, so a verified commit signed by someone else does
# not count, even when the author email maps to an allowlisted login.
nz_reply_gate() {
  local meta rc login committer verified reason shown cfold afold
  if [[ -z "$(nz_fold "${NZ_REPLY_AUTHORS:-}")" ]]; then
    printf '%s\n' "reply_authors is not set"
    return 1
  fi
  meta="$(nz_commit_meta "$1")"; rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "could not check the commit that added it"
    return 1
  fi
  IFS=$'\t' read -r login committer verified reason <<<"$meta"
  if ! nz_author_allowed "$login"; then
    shown="$(nz_login_shown "$login")"
    if [[ -z "$shown" ]]; then printf '%s\n' "commit has no GitHub author"
    else printf '%s\n' "author '$shown' is not in reply_authors"; fi
    return 1
  fi
  if [[ "${NZ_REQUIRE_VERIFIED:-true}" != false ]]; then
    case "$reason" in
      unsigned|valid|invalid|unknown_key|expired_key|not_signing_key|bad_email|unverified_email|no_user|malformed_signature|unknown_signature_type|gpgverify_error|gpgverify_unavailable) ;;
      *) reason="unverified" ;;
    esac
    if [[ "$verified" != true ]]; then
      printf '%s\n' "commit is not verified (${reason:-unsigned})"
      return 1
    fi
    afold="$(nz_fold "$login")"
    cfold="$(nz_fold "$committer")"
    if [[ "$cfold" != "$afold" && "$cfold" != "web-flow" ]]; then
      shown="$(nz_login_shown "$committer")"
      if [[ -z "$shown" ]]; then printf '%s\n' "commit is verified but has no GitHub committer"
      else printf '%s\n' "commit is verified but committer '$shown' is not that author"; fi
      return 1
    fi
  fi
  printf '%s\n' "$(nz_login_shown "$login")"
  return 0
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
