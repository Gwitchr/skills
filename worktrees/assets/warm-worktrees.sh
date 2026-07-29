#!/usr/bin/env bash
# wt-warm-version: 1

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: warm-worktrees.sh [--skip WORKTREE]... [--rebase] [WORKTREE...]

Copy paths listed in .worktree-copy from the bare repo root into linked worktrees.

Arguments:
  WORKTREE              Optional worktree name or absolute path. If omitted, warm all worktrees.

Options:
  --skip WORKTREE       Skip a worktree name or absolute path. Can be passed multiple times.
  --rebase              After copying, rebase each selected worktree's branch onto the detected
                         default branch (see "Default branch detection" below). A worktree already
                         on the default branch, or in detached HEAD, is skipped. On conflict the
                         rebase is aborted and the worktree reported as failed; other worktrees
                         continue.
  -h, --help            Show this help text.

Default branch detection, first match wins:
  1. git config wt.defaultBranch
  2. the remote's HEAD symbolic reference (refs/remotes/<remote>/HEAD)
  3. the bare repo root's own HEAD
  4. the first of main, master, develop that exists under refs/heads

.worktree-copy format:
  One path per line, relative to the bare repo root. Blank lines and lines starting
  with # are skipped. An optional second field, separated by whitespace, sets the
  copy mode: copy (default), copy-if-missing, or link. See worktree-copy.template.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

REMOTE="origin"

detect_default_branch() {
  local configured
  configured="$(git config --get wt.defaultBranch 2>/dev/null || true)"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return 0
  fi

  local remote_head
  remote_head="$(git symbolic-ref --quiet --short "refs/remotes/${REMOTE}/HEAD" 2>/dev/null || true)"
  if [[ -n "$remote_head" ]]; then
    printf '%s\n' "${remote_head#"${REMOTE}"/}"
    return 0
  fi

  local repo_head
  repo_head="$(git -C "$BARE_REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -n "$repo_head" ]]; then
    printf '%s\n' "$repo_head"
    return 0
  fi

  local candidate
  for candidate in main master develop; do
    if git -C "$BARE_REPO_ROOT" show-ref --verify --quiet "refs/heads/${candidate}"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

copy_path() {
  local source_path="$1"
  local destination_path="$2"
  local mode="$3"

  case "$mode" in
    copy-if-missing)
      [[ -e "$destination_path" ]] && return 0
      ;;
    link)
      mkdir -p "$(dirname "$destination_path")"
      ln -sfn "$source_path" "$destination_path"
      return 0
      ;;
  esac

  if [[ -d "$source_path" ]]; then
    mkdir -p "$destination_path"
    cp -Rf "$source_path"/. "$destination_path"
  else
    mkdir -p "$(dirname "$destination_path")"
    cp -f "$source_path" "$destination_path"
  fi
}

canonicalize() {
  # Resolve to the physical path (pwd -P), the same form git prints in
  # `git worktree list --porcelain`. Plain `pwd` follows the shell's logical
  # working directory and can disagree with git when a parent directory
  # (commonly a symlinked /tmp) is itself a symlink, which used to make a
  # worktree's canonical path collide with BARE_REPO_ROOT and turn a copy
  # into a no-op "same file" error.
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
  else
    local parent
    parent="$(dirname "$path")"
    local base
    base="$(basename "$path")"
    (cd "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base")
  fi
}

matches_worktree() {
  local candidate="$1"
  local worktree_path="$2"
  local worktree_name
  worktree_name="$(basename "$worktree_path")"

  [[ "$candidate" == "$worktree_path" || "$candidate" == "$worktree_name" ]]
}

skip_worktree() {
  local worktree_path="$1"
  local item

  if [[ ${#SKIP_WORKTREES[@]} -eq 0 ]]; then
    return 1
  fi

  for item in "${SKIP_WORKTREES[@]}"; do
    if matches_worktree "$item" "$worktree_path"; then
      return 0
    fi
  done

  return 1
}

select_worktree() {
  local worktree_path="$1"
  local item

  if [[ ${#TARGET_WORKTREES[@]} -eq 0 ]]; then
    return 0
  fi

  for item in "${TARGET_WORKTREES[@]}"; do
    if matches_worktree "$item" "$worktree_path"; then
      return 0
    fi
  done

  return 1
}

SKIP_WORKTREES=()
TARGET_WORKTREES=()
WORKTREE_PATHS=()
REBASE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip)
      [[ $# -ge 2 ]] || die "--skip requires a worktree name or path"
      SKIP_WORKTREES+=("$2")
      shift 2
      ;;
    --rebase)
      REBASE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      TARGET_WORKTREES+=("$1")
      shift
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BARE_REPO_ROOT="$SCRIPT_DIR"
COPY_LIST="$BARE_REPO_ROOT/.worktree-copy"

[[ -f "$COPY_LIST" ]] || die "Missing copy manifest: $COPY_LIST"

while IFS= read -r line; do
  [[ -n "$line" ]] || continue

  if [[ "$line" == worktree\ * ]]; then
    worktree_path="${line#worktree }"
    worktree_path="$(canonicalize "$worktree_path")"

    if [[ "$worktree_path" == "$BARE_REPO_ROOT" ]]; then
      continue
    fi

    WORKTREE_PATHS+=("$worktree_path")
  fi
done < <(git worktree list --porcelain)

[[ ${#WORKTREE_PATHS[@]} -gt 0 ]] || die "No linked worktrees found"

copied_any=0

while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
  [[ -z "$manifest_line" || "$manifest_line" == \#* ]] && continue

  file_path=""
  mode=""
  read -r file_path mode <<< "$manifest_line"
  mode="${mode:-copy}"

  case "$mode" in
    copy|copy-if-missing|link) ;;
    *) die "Unknown copy mode '$mode' for $file_path in $COPY_LIST" ;;
  esac

  [[ -e "$BARE_REPO_ROOT/$file_path" ]] || die "Missing source path: $BARE_REPO_ROOT/$file_path"

  for worktree_path in "${WORKTREE_PATHS[@]}"; do
    if ! select_worktree "$worktree_path"; then
      continue
    fi

    if skip_worktree "$worktree_path"; then
      echo "Skipped $(basename "$worktree_path"): $file_path"
      continue
    fi

    copy_path "$BARE_REPO_ROOT/$file_path" "$worktree_path/$file_path" "$mode"
    echo "Copied $file_path -> $worktree_path ($mode)"
    copied_any=1
  done
done < "$COPY_LIST"

if [[ $copied_any -eq 0 ]]; then
  echo "Nothing copied"
fi

if [[ $REBASE -eq 1 ]]; then
  DEFAULT_BRANCH="$(detect_default_branch)" || die "Could not detect the default branch. Set one with: git config wt.defaultBranch <branch>"

  echo
  echo "Fetching ${REMOTE}/${DEFAULT_BRANCH}..."
  git fetch "$REMOTE" "+refs/heads/${DEFAULT_BRANCH}:refs/remotes/${REMOTE}/${DEFAULT_BRANCH}"

  REBASE_OK=()
  REBASE_SKIPPED=()
  REBASE_FAILED=()

  for worktree_path in "${WORKTREE_PATHS[@]}"; do
    if ! select_worktree "$worktree_path"; then
      continue
    fi

    if skip_worktree "$worktree_path"; then
      continue
    fi

    worktree_name="$(basename "$worktree_path")"
    branch="$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD || true)"

    if [[ -z "$branch" ]]; then
      echo "Skipped rebase for $worktree_name: detached HEAD"
      REBASE_SKIPPED+=("$worktree_name (detached HEAD)")
      continue
    fi

    if [[ "$branch" == "$DEFAULT_BRANCH" ]]; then
      echo "Skipped rebase for $worktree_name: on $DEFAULT_BRANCH"
      REBASE_SKIPPED+=("$worktree_name (on $DEFAULT_BRANCH)")
      continue
    fi

    echo "Rebasing $worktree_name ($branch) onto ${REMOTE}/${DEFAULT_BRANCH}..."
    if git -C "$worktree_path" rebase "${REMOTE}/${DEFAULT_BRANCH}"; then
      REBASE_OK+=("$worktree_name ($branch)")
    else
      echo "Rebase failed for $worktree_name; aborting" >&2
      git -C "$worktree_path" rebase --abort || true
      REBASE_FAILED+=("$worktree_name ($branch)")
    fi
  done

  echo
  echo "Rebase summary:"
  echo "  succeeded: ${#REBASE_OK[@]}"
  for item in ${REBASE_OK[@]+"${REBASE_OK[@]}"}; do
    echo "    - $item"
  done
  echo "  skipped:   ${#REBASE_SKIPPED[@]}"
  for item in ${REBASE_SKIPPED[@]+"${REBASE_SKIPPED[@]}"}; do
    echo "    - $item"
  done
  echo "  failed:    ${#REBASE_FAILED[@]}"
  for item in ${REBASE_FAILED[@]+"${REBASE_FAILED[@]}"}; do
    echo "    - $item"
  done

  if [[ ${#REBASE_FAILED[@]} -gt 0 ]]; then
    exit 1
  fi
fi
