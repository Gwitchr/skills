#!/usr/bin/env bash
# nazgul config.sh: choose the report repo, who may reply, and the folders nazgul skips.
# Enrolling a repo is install.sh --enroll.
#
#   config.sh [--repo <owner/repo>] [--skip-paths <dir:dir>] [--max-rounds N]
#             [--auto-continue true|false] [--reply-authors <logins>]
#             [--require-verified true|false] [--speak true|false]
#   config.sh --show [--cwd <dir>]
#
# From a terminal it asks for the report repo and the skip paths when those flags are absent.
# Reply settings change only when their flags are passed. Without a terminal it uses the flags
# and the current values, and fails when no report repo is known. Writes only
# ~/.config/nazgul/config (mode 600); the [project] sections and any other line in it are kept.
# Nothing is written inside a repo. --show prints the settings and whether nazgul is on in --cwd.
set -u
# Find this script's folder. Some agent tools run commands in a bash that leaves BASH_SOURCE
# empty, so fall back to $0, then to NAZGUL_SCRIPTS, then to the default skill location.
nz_self="${BASH_SOURCE[0]:-}"; [[ -f "$nz_self" ]] || nz_self="$0"
NZ_SCRIPTS="$(cd "$(dirname "$nz_self")" 2>/dev/null && pwd -P)"
[[ -f "$NZ_SCRIPTS/lib.sh" ]] || NZ_SCRIPTS="${NAZGUL_SCRIPTS:-$HOME/.agents/skills/nazgul/scripts}"
[[ -f "$NZ_SCRIPTS/lib.sh" ]] || { printf 'nazgul: cannot find the scripts folder; set NAZGUL_SCRIPTS or run with /bin/bash\n' >&2; exit 2; }
. "$NZ_SCRIPTS/lib.sh"

usage() { sed -n '2,14p' "$NZ_SCRIPTS/config.sh" | sed 's/^# \{0,1\}//'; }

repo=""; skip=""; rounds=""; authors=""; auto=""; verified=""; speak=""; cwd="$PWD"; show=0
set_repo=0; set_skip=0; set_rounds=0; set_authors=0; set_auto=0; set_verified=0; set_speak=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --show) show=1; shift ;;
    --repo|--skip-paths|--max-rounds|--auto-continue|--reply-authors|--require-verified|--speak|--cwd)
      [[ $# -ge 2 ]] || { nz_warn "$1 needs a value"; exit 2; }
      case "$1" in
        --repo) repo="$2"; set_repo=1 ;;
        --skip-paths) skip="$2"; set_skip=1 ;;
        --max-rounds) rounds="$2"; set_rounds=1 ;;
        --auto-continue) auto="$2"; set_auto=1 ;;
        --reply-authors) authors="$2"; set_authors=1 ;;
        --require-verified) verified="$2"; set_verified=1 ;;
        --speak) speak="$2"; set_speak=1 ;;
        --cwd) cwd="$2" ;;
      esac
      shift 2 ;;
    *) nz_warn "unknown argument: $1"; exit 2 ;;
  esac
done

if [[ $show -eq 1 ]]; then
  printf 'user config:   %s%s\n' "$NZ_USER_CONFIG" "$([[ -f "$NZ_USER_CONFIG" ]] || printf ' (missing)')"
  printf 'report repo:   %s%s\n' "${NAZGUL_REPO:-$(nz_cfg "" repo)}" "$([[ -n "${NAZGUL_REPO:-}" ]] && printf ' (from NAZGUL_REPO)')"
  printf 'skip paths:    %s\n' "$(nz_cfg "" skip_paths)"
  printf 'auto continue: %s\n' "$([[ "$(nz_cfg "" auto_continue)" == true ]] && printf true || printf false)"
  printf 'reply authors: %s\n' "$(nz_cfg "" reply_authors)"
  printf 'require verified: %s\n' "$([[ "$(nz_cfg "" require_verified)" == true ]] && printf true || printf false)"
  printf 'speak:         %s\n' "$([[ "$(nz_cfg "" speak)" == true ]] && printf true || printf false)"
  printf 'enrolled:\n'
  n=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    n=$((n + 1))
    s="$(nz_cfg "$p" slug)" || s="$(nz_default_slug "$p")"
    printf '  %-20s %s%s\n' "$s" "$p" "$([[ -d "$p" ]] || printf ' (missing)')"
  done < <(nz_projects)
  [[ $n -gt 0 ]] || printf '  none; run install.sh --enroll inside a repo\n'
  here="$(git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1 && nz_common "$cwd")"
  if nz_load "$cwd"; then
    printf 'here:          on in %s\n' "$NZ_ROOT"
    printf '  project:     %s\n' "$NZ_PROJECT"
    printf '  branch:      %s\n' "$NZ_BRANCH"
    printf '  max rounds:  %s\n' "$NZ_MAX_ROUNDS"
    printf '  poll:        %s tries, %ss apart\n' "$NZ_POLL_TRIES" "$NZ_POLL_INTERVAL"
    printf '  auto continue: %s\n' "$NZ_AUTO_CONTINUE"
    printf '  reply authors: %s\n' "${NZ_REPLY_AUTHORS:-"(none; replies are not acted on)"}"
    printf '  require verified: %s\n' "$NZ_REQUIRE_VERIFIED"
    printf '  state:       %s\n' "$NZ_STATE"
  else
    if [[ "${NAZGUL_OFF:-}" == 1 ]]; then why="NAZGUL_OFF=1"
    elif [[ -z "$here" ]]; then why="not inside a git work tree"
    elif ! nz_enrolled "$here"; then why="this repo is not enrolled: $here"
    elif [[ -z "${NAZGUL_REPO:-$(nz_cfg "" repo)}" ]]; then why="no report repo; run config.sh"
    else why="under a skip path, or the report repo name is not owner/repo"; fi
    printf 'here:          off (%s)\n' "$why"
  fi
  exit 0
fi

interactive=0; [[ -t 0 ]] && interactive=1
ask() { # <prompt> <current> -> answer, or current on an empty answer
  local a
  read -r -p "$1 [${2}]: " a || a=""
  printf '%s' "${a:-$2}"
}

cur_repo="$(nz_cfg "" repo)"
cur_skip="$(nz_cfg "" skip_paths)"

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
[[ "$skip" != *$'\n'* ]] || { nz_warn "skip paths cannot hold a newline"; exit 2; }
[[ -z "$rounds" || "$rounds" =~ ^[0-9]+$ ]] || { nz_warn "--max-rounds takes a number"; exit 2; }
if [[ $set_auto -eq 1 ]]; then
  case "$auto" in true|false) ;; *) nz_warn "--auto-continue takes true or false"; exit 2 ;; esac
fi
if [[ $set_verified -eq 1 ]]; then
  case "$verified" in true|false) ;; *) nz_warn "--require-verified takes true or false"; exit 2 ;; esac
fi
if [[ $set_speak -eq 1 ]]; then
  case "$speak" in true|false) ;; *) nz_warn "--speak takes true or false"; exit 2 ;; esac
fi
if [[ $set_authors -eq 1 && -n "$authors" && "$authors" != "-" ]]; then
  [[ "$authors" != *$'\n'* && "$authors" != *'#'* ]] || { nz_warn "reply authors cannot hold a newline or a hash"; exit 2; }
fi

[[ -f "$NZ_USER_CONFIG" ]] || {
  mkdir -p "$(dirname "$NZ_USER_CONFIG")" &&
    (umask 077; printf '# nazgul user config, read line by line and never sourced. See SKILL.md.\n' >"$NZ_USER_CONFIG")
} || { nz_warn "cannot write $NZ_USER_CONFIG"; exit 1; }
nz_cfg_edit set "" repo "$repo" || { nz_warn "cannot write $NZ_USER_CONFIG"; exit 1; }
if [[ -n "$skip" ]]; then nz_cfg_edit set "" skip_paths "$skip"; else nz_cfg_edit unset "" skip_paths; fi
[[ $set_rounds -eq 1 && -n "$rounds" ]] && nz_cfg_edit set "" max_rounds "$rounds"
if [[ $set_auto -eq 1 ]]; then
  nz_cfg_edit set "" auto_continue "$auto" || { nz_warn "cannot write $NZ_USER_CONFIG"; exit 1; }
fi
if [[ $set_verified -eq 1 ]]; then
  nz_cfg_edit set "" require_verified "$verified" || { nz_warn "cannot write $NZ_USER_CONFIG"; exit 1; }
fi
if [[ $set_speak -eq 1 ]]; then
  nz_cfg_edit set "" speak "$speak" || { nz_warn "cannot write $NZ_USER_CONFIG"; exit 1; }
fi
if [[ $set_authors -eq 1 ]]; then
  if [[ -z "$authors" || "$authors" == "-" ]]; then
    nz_cfg_edit unset "" reply_authors || { nz_warn "cannot write $NZ_USER_CONFIG"; exit 1; }
  else
    nz_cfg_edit set "" reply_authors "$authors" || { nz_warn "cannot write $NZ_USER_CONFIG"; exit 1; }
  fi
fi
printf 'nazgul: wrote %s\n' "$NZ_USER_CONFIG"

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

here="$(nz_common "$cwd" 2>/dev/null)"
if [[ -n "$here" ]] && ! nz_enrolled "$here"; then
  printf 'nazgul: this repo is not enrolled; to enroll it run: bash "%s/install.sh" --enroll\n' "$NZ_SCRIPTS"
fi
