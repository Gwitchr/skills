#!/usr/bin/env bash
# nazgul config.sh: choose the report repo, the project slug, and the folders nazgul skips.
#
#   config.sh [--repo <owner/repo>] [--project <slug>] [--skip-paths <dir:dir>] [--max-rounds N]
#             [--cwd <dir>] [--show]
#
# From a terminal it asks for every value not given as a flag, showing the current one as the
# default. Without a terminal it uses the flags and the current values, and fails when no report
# repo is known. Writes:
#   ~/.config/nazgul/config   repo=, skip_paths=, max_rounds=   (mode 600; other keys are kept)
#   <project root>/.nazgul    project=                          (git-ignored, never committed)
# --show prints the effective settings for --cwd and whether nazgul is on there.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

repo=""; project=""; skip=""; rounds=""; cwd="$PWD"; show=0
set_repo=0; set_project=0; set_skip=0; set_rounds=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --show) show=1; shift ;;
    --repo|--project|--skip-paths|--max-rounds|--cwd)
      [[ $# -ge 2 ]] || { nz_warn "$1 needs a value"; exit 2; }
      case "$1" in
        --repo) repo="$2"; set_repo=1 ;;
        --project) project="$2"; set_project=1 ;;
        --skip-paths) skip="$2"; set_skip=1 ;;
        --max-rounds) rounds="$2"; set_rounds=1 ;;
        --cwd) cwd="$2" ;;
      esac
      shift 2 ;;
    *) nz_warn "unknown argument: $1"; exit 2 ;;
  esac
done

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
default_project() {
  local common v
  [[ -n "$root" ]] || return 0
  common="$(cd "$root" && cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)" || return 0
  v="$(basename "$common")"
  [[ "$v" == .git ]] && v="$(basename "$(dirname "$common")")"
  nz_slug "${v%.git}"
}

if [[ $show -eq 1 ]]; then
  printf 'user config:   %s%s\n' "$NZ_USER_CONFIG" "$([[ -f "$NZ_USER_CONFIG" ]] || printf ' (missing)')"
  printf 'report repo:   %s%s\n' "${NAZGUL_REPO:-$(nz_kv "$NZ_USER_CONFIG" repo)}" "$([[ -n "${NAZGUL_REPO:-}" ]] && printf ' (from NAZGUL_REPO)')"
  printf 'skip paths:    %s\n' "$(nz_kv "$NZ_USER_CONFIG" skip_paths)"
  if nz_load "$cwd"; then
    printf 'project:       %s\n' "$NZ_PROJECT"
    printf 'branch:        %s\n' "$NZ_BRANCH"
    printf 'max rounds:    %s\n' "$NZ_MAX_ROUNDS"
    printf 'poll:          %s tries, %ss apart\n' "$NZ_POLL_TRIES" "$NZ_POLL_INTERVAL"
    printf 'state:         %s\n' "$NZ_STATE"
    printf 'status:        on in %s\n' "$NZ_ROOT"
  else
    printf 'status:        off here (NAZGUL_OFF=1, no report repo, a skip path, or not a git repo)\n'
  fi
  exit 0
fi

interactive=0; [[ -t 0 ]] && interactive=1
ask() { # <prompt> <current> -> answer, or current on an empty answer
  local a
  read -r -p "$1 [${2}]: " a || a=""
  printf '%s' "${a:-$2}"
}

cur_repo="$(nz_kv "$NZ_USER_CONFIG" repo)"
cur_skip="$(nz_kv "$NZ_USER_CONFIG" skip_paths)"
cur_rounds="$(nz_kv "$NZ_USER_CONFIG" max_rounds)"
cur_project="$( [[ -n "$root" ]] && nz_kv "$root/.nazgul" project)"
[[ -n "$cur_project" ]] || cur_project="$(default_project)"

if [[ $set_repo -eq 0 ]]; then
  repo="$cur_repo"
  [[ $interactive -eq 1 ]] && repo="$(ask "Report repo, as owner/repo" "$cur_repo")"
fi
re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
[[ "$repo" =~ $re ]] || { nz_warn "the report repo must look like owner/repo (got '${repo}')"; exit 2; }

if [[ $set_skip -eq 0 ]]; then
  skip="$cur_skip"
  [[ $interactive -eq 1 ]] && skip="$(ask "Folders where nazgul does nothing, colon-separated ('-' for none)" "${cur_skip:--}")"
fi
[[ "$skip" == "-" ]] && skip=""

if [[ $set_rounds -eq 0 ]]; then rounds="$cur_rounds"; fi
[[ -z "$rounds" || "$rounds" =~ ^[0-9]+$ ]] || { nz_warn "--max-rounds takes a number"; exit 2; }

if [[ -n "$root" ]]; then
  if [[ $set_project -eq 0 ]]; then
    project="$cur_project"
    [[ $interactive -eq 1 ]] && project="$(ask "Project slug for $(basename "$root")" "$cur_project")"
  fi
  project="$(nz_slug "$project")"
  [[ -n "$project" ]] || { nz_warn "the project slug is empty"; exit 2; }
elif [[ $set_project -eq 1 ]]; then
  nz_warn "--project needs a git repo; run config.sh from inside the project"; exit 2
fi

# User config: managed keys rewritten, any other key=value line kept.
mkdir -p "$(dirname "$NZ_USER_CONFIG")"
tmp="$(nz_tmp)" || exit 1
{
  printf '# nazgul user config, written by config.sh. Read line by line, never sourced.\n'
  printf 'repo=%s\n' "$repo"
  printf 'skip_paths=%s\n' "$skip"
  [[ -n "$rounds" ]] && printf 'max_rounds=%s\n' "$rounds"
  if [[ -f "$NZ_USER_CONFIG" ]]; then
    grep -E '^[[:space:]]*[a-z_]+=' "$NZ_USER_CONFIG" | grep -vE '^[[:space:]]*(repo|skip_paths|max_rounds)='
  fi
} >"$tmp"
chmod 600 "$tmp" && mv "$tmp" "$NZ_USER_CONFIG"
printf 'nazgul: wrote %s\n' "$NZ_USER_CONFIG"

if [[ -n "$root" ]]; then
  tmp="$(nz_tmp)" || exit 1
  {
    printf 'project=%s\n' "$project"
    [[ -f "$root/.nazgul" ]] && grep -E '^[[:space:]]*[a-z_]+=' "$root/.nazgul" | grep -vE '^[[:space:]]*project='
  } >"$tmp"
  mv "$tmp" "$root/.nazgul"
  printf 'nazgul: wrote %s/.nazgul\n' "$root"
  if ! git -C "$root" check-ignore -q .nazgul 2>/dev/null; then
    [[ -s "$root/.gitignore" && -n "$(tail -c 1 "$root/.gitignore")" ]] && printf '\n' >>"$root/.gitignore"
    printf '.nazgul\n' >>"$root/.gitignore"
    printf 'nazgul: added .nazgul to %s/.gitignore\n' "$root"
  fi
fi

if command -v gh >/dev/null 2>&1; then
  push="$(nz_limit 30 gh api "repos/$repo" --jq '.permissions.push' 2>/dev/null)"
  case "$push" in
    true) printf 'nazgul: %s is reachable and you can push to it\n' "$repo" ;;
    false) nz_warn "you can read $repo but not push to it; reports will fail until you can" ;;
    *) nz_warn "could not reach $repo with gh; check the name and run 'gh auth status'" ;;
  esac
else
  nz_warn "gh not found; nazgul needs the GitHub CLI, logged in"
fi
