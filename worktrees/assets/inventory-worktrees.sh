#!/usr/bin/env bash
# inventory-worktrees-version: 1
#
# Take inventory of the linked worktrees of this repo: what each one holds, why
# it exists, and which ones have landed and can go. Removal is the second step
# and never happens on its own. The script lives next to warm-worktrees.sh in
# the repo root and takes the repo from its own location, so there is no path
# flag and nothing to install.
#
#   ./inventory-worktrees.sh            the inventory, changes nothing
#   ./inventory-worktrees.sh --remove   remove the worktrees marked "would remove"
#   ./inventory-worktrees.sh --no-gh    skip the pull request lookup
#
# Portability: macOS default bash 3.2 and Linux bash 5. No associative arrays,
# no line reading builtins from bash 4, no flag that differs between BSD and
# GNU. Dates come from git. One temporary directory, one EXIT trap.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: inventory-worktrees.sh [--remove] [--no-gh]

List every linked worktree of this repo with its branch, age, state, whether
its work has landed, a verdict, and the reason it exists. Run it from the repo
root, where it sits next to warm-worktrees.sh.

Options:
  --remove    remove the worktrees the inventory marks "would remove"
  --no-gh     skip the pull request lookup and use git history alone
  -h, --help  show this help text

Columns:
  NAME     the worktree directory, * marks the default branch
  BRANCH   the branch it holds, or (detached)
  AGE      how long ago its last commit was made
  STATE    clean, warm (only .worktree-copy paths changed), dirty, locked
  DONE     how the work landed, if it did
  VERDICT  would remove, or kept and why
  REASON   the title of its pull request, or its last commit subject

A worktree is finished when either of these holds:
  1. its HEAD is contained in the default branch on the remote, or
  2. gh reports a merged pull request for its branch whose head commit is the
     worktree's own HEAD, which is what a squash merge leaves behind.

A worktree is kept when it holds the default branch, is locked, has changes
outside .worktree-copy, is in detached HEAD, has an open pull request, or has
commits made after its pull request merged.

With --remove each removal re-checks the working tree first. A worktree dirty
only in .worktree-copy paths is removed with --force, anything else is skipped.
After removal the branch is deleted with `git branch -d`; when git refuses, the
exact `git branch -D` command is printed for you to run by hand.

Exit codes: 0 fine, 1 bad usage or environment, 3 something was skipped.
EOF
}

die() {
  echo "inventory-worktrees: $*" >&2
  exit 1
}

REMOTE="origin"
STALE_DAYS=30
EXIT_CODE=0

# Field separator for the internal lists. A tab cannot be used: it is an IFS
# whitespace character, so `read` folds runs of tabs and drops empty fields.
US=$(printf '\037')

TMPD=""
cleanup() {
  if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then
    rm -rf "$TMPD"
  fi
}
trap cleanup EXIT

DO_REMOVE=0
USE_GH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --remove)
      DO_REMOVE=1
      shift
      ;;
    --no-gh)
      USE_GH=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "inventory-worktrees: unknown option $1" >&2
      echo "run inventory-worktrees.sh --help for the three it accepts" >&2
      exit 1
      ;;
  esac
done

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/inventory-worktrees.XXXXXX")
MANIFEST="$TMPD/manifest"
PR_CACHE="$TMPD/prs.tsv"
RECORDS="$TMPD/records"
ROWS="$TMPD/rows"
REMOVALS="$TMPD/removals"
: > "$MANIFEST"
: > "$PR_CACHE"
: > "$RECORDS"
: > "$ROWS"
: > "$REMOVALS"

canonicalize() {
  # Resolve to the physical path, the form git prints in `worktree list`.
  local path="$1"
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
  else
    printf '%s' "$path"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR"

if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  die "$REPO_ROOT is not a git repository. Copy this script to the repo root."
fi

detect_default_branch() {
  local value candidate
  value="$(git -C "$REPO_ROOT" config --get wt.defaultBranch 2>/dev/null || true)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short "refs/remotes/${REMOTE}/HEAD" 2>/dev/null || true)"
  if [ -n "$value" ]; then
    printf '%s' "${value#"${REMOTE}"/}"
    return 0
  fi
  value="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  for candidate in main master develop; do
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${candidate}"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# .worktree-copy, one path per line, an optional second field naming the mode.
# Only the path matters here: it is what makes a change "warm" instead of real.
load_manifest() {
  local line entry
  if [ ! -f "$REPO_ROOT/.worktree-copy" ]; then
    return 0
  fi
  while IFS= read -r line <&7 || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    entry=""
    read -r entry _ <<< "$line" || true
    if [ -n "$entry" ]; then
      printf '%s\n' "$entry" >> "$MANIFEST"
    fi
  done 7< "$REPO_ROOT/.worktree-copy"
}

is_warm_path() {
  local candidate="${1%/}" entry base
  while IFS= read -r entry <&8 || [ -n "$entry" ]; do
    base="${entry%/}"
    if [ -z "$base" ]; then
      continue
    fi
    if [ "$candidate" = "$base" ]; then
      return 0
    fi
    case "$candidate" in
      "$base"/*) return 0 ;;
    esac
  done 8< "$MANIFEST"
  return 1
}

DIRT_KIND=""

# Sets DIRT_KIND to clean, warm, real, or empty when the status call failed,
# and writes the changed paths one per line to $2.
classify_dirt() {
  local path="$1" out="$2" raw field line
  DIRT_KIND=""
  : > "$out"
  if [ ! -d "$path" ]; then
    return 0
  fi
  if ! git -C "$path" status --porcelain -unormal > "$TMPD/status.raw" 2>/dev/null; then
    return 0
  fi
  while IFS= read -r raw <&8 || [ -n "$raw" ]; do
    if [ "${#raw}" -lt 4 ]; then
      continue
    fi
    field="${raw:3}"
    case "$field" in
      *" -> "*) field="${field#*" -> "}" ;;
    esac
    case "$field" in
      '"'*'"')
        field="${field#\"}"
        field="${field%\"}"
        ;;
    esac
    if [ -n "$field" ]; then
      printf '%s\n' "$field" >> "$out"
    fi
  done 8< "$TMPD/status.raw"
  if [ ! -s "$out" ]; then
    DIRT_KIND="clean"
    return 0
  fi
  DIRT_KIND="warm"
  while IFS= read -r line <&9 || [ -n "$line" ]; do
    if ! is_warm_path "$line"; then
      DIRT_KIND="real"
      break
    fi
  done 9< "$out"
}

first_three() {
  local count=0 first=1 line
  if [ ! -f "$1" ]; then
    return 0
  fi
  while IFS= read -r line <&8 || [ -n "$line" ]; do
    count=$((count + 1))
    if [ "$count" -gt 3 ]; then
      break
    fi
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ', '
    fi
    printf '%s' "$line"
  done 8< "$1"
}

# owner/repo out of an https, git, ssh, or scp style remote URL. A local path
# yields nothing, which is right: there is no forge behind it.
repo_slug() {
  local url="${1:-}" path="" owner name
  if [ -z "$url" ]; then
    return 0
  fi
  url="${url%/}"
  url="${url%.git}"
  case "$url" in
    http://* | https://* | git://* | ssh://*)
      path="${url#*://}"
      case "$path" in
        */*) path="${path#*/}" ;;
        *) return 0 ;;
      esac
      ;;
    *://*) return 0 ;;
    /* | .* | '~'*) return 0 ;;
    *:*)
      path="${url#*:}"
      case "$path" in
        /* | '~'*) return 0 ;;
      esac
      ;;
    *) return 0 ;;
  esac
  case "$path" in
    */*) ;;
    *) return 0 ;;
  esac
  name="${path##*/}"
  owner="${path%/*}"
  owner="${owner##*/}"
  if [ -n "$owner" ] && [ -n "$name" ]; then
    printf '%s/%s' "$owner" "$name"
  fi
}

GH_OK=0

# The one place that talks to a forge: a single call per run, filling a tab
# separated cache of branch, number, state, url, head commit, title. The gsub
# on the title keeps a tab or a newline in it from breaking the row shape. The
# --jq expression runs inside gh, which embeds its own jq, so jq is not needed
# on PATH. It is kept on one line you can paste into a terminal to check by hand.
fetch_prs() {
  local gh slug cwd rc=0
  if [ "$USE_GH" -eq 0 ]; then
    return 0
  fi
  gh="${WT_GH_CMD:-gh}"
  if ! command -v "$gh" >/dev/null 2>&1; then
    echo "inventory-worktrees: gh is not on PATH, using git history alone" >&2
    return 0
  fi
  slug="$(repo_slug "$(git -C "$REPO_ROOT" remote get-url "$REMOTE" 2>/dev/null || true)")"
  if [ -n "$slug" ]; then
    "$gh" pr list --state all --limit 500 -R "$slug" --json number,headRefName,state,url,headRefOid,title --jq '.[] | [.headRefName, (.number|tostring), .state, .url, .headRefOid, (.title|gsub("[\\t\\n\\r]"; " "))] | @tsv' > "$PR_CACHE" 2>/dev/null || rc=$?
  else
    cwd="$REPO_ROOT"
    if [ -d "$REPO_ROOT/$DEFAULT_BRANCH" ]; then
      cwd="$REPO_ROOT/$DEFAULT_BRANCH"
    fi
    (cd "$cwd" && "$gh" pr list --state all --limit 500 --json number,headRefName,state,url,headRefOid,title --jq '.[] | [.headRefName, (.number|tostring), .state, .url, .headRefOid, (.title|gsub("[\\t\\n\\r]"; " "))] | @tsv') > "$PR_CACHE" 2>/dev/null || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "inventory-worktrees: gh pr list failed, using git history alone" >&2
    : > "$PR_CACHE"
    return 0
  fi
  GH_OK=1
}

# One row per branch, printed as "STATE NUMBER HEADMATCH TITLE", the title last
# because it is the only field that holds spaces. An open pull request wins.
# Otherwise a merged one whose head commit is this worktree's HEAD wins, because
# that pair proves the branch tip itself landed, which is the only thing a
# squash merge leaves to go on. Otherwise the highest numbered row.
pr_for_branch() {
  if [ ! -s "$PR_CACHE" ] || [ -z "$1" ]; then
    return 0
  fi
  awk -F'\t' -v branch="$1" -v head="$2" '
    $1 != branch { next }
    {
      number = $2 + 0
      if ($3 == "OPEN") {
        if (!open_seen || number > open_num) { open_seen = 1; open_num = number; open_title = $6 }
      } else if ($3 == "MERGED" && $5 == head) {
        if (!hit_seen || number > hit_num) { hit_seen = 1; hit_num = number; hit_title = $6 }
      } else if ($3 == "MERGED") {
        if (!miss_seen || number > miss_num) { miss_seen = 1; miss_num = number; miss_title = $6 }
      } else if ($3 == "CLOSED") {
        if (!shut_seen || number > shut_num) { shut_seen = 1; shut_num = number; shut_title = $6 }
      }
    }
    END {
      if (open_seen) print "OPEN", open_num, 1, open_title
      else if (hit_seen) print "MERGED", hit_num, 1, hit_title
      else if (miss_seen) print "MERGED", miss_num, 0, miss_title
      else if (shut_seen) print "CLOSED", shut_num, 0, shut_title
    }
  ' "$PR_CACHE"
}

# The REASON column: 40 characters at most, the last three of them dots when
# there was more.
short() {
  local text="${1:-}"
  if [ -z "$text" ]; then
    printf -- '-'
  elif [ "${#text}" -le 40 ]; then
    printf '%s' "$text"
  else
    printf '%s...' "${text:0:37}"
  fi
}

render_table() {
  awk -F"$US" '
    { rows[NR] = $0
      n = split($0, f, FS)
      for (i = 1; i <= n; i++) if (length(f[i]) > w[i]) w[i] = length(f[i])
      if (n > cols) cols = n
    }
    END {
      for (r = 1; r <= NR; r++) {
        n = split(rows[r], f, FS)
        line = ""
        for (i = 1; i <= cols; i++) {
          cell = (i <= n) ? f[i] : ""
          if (i > 1) line = line "  "
          line = line sprintf("%-" w[i] "s", cell)
        }
        sub(/[ \t]+$/, "", line)
        print line
      }
    }
  ' "$1"
}

row() {
  local first=1 field
  for field in "$@"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf '%s' "$US"
    fi
    printf '%s' "$field"
  done
  printf '\n'
}

DEFAULT_BRANCH="$(detect_default_branch)" ||
  die "could not detect the default branch. Set one with: git config wt.defaultBranch <branch>"

REMOTE_REF="refs/remotes/${REMOTE}/${DEFAULT_BRANCH}"

if ! git -C "$REPO_ROOT" fetch --quiet "$REMOTE" \
  "+refs/heads/${DEFAULT_BRANCH}:${REMOTE_REF}" >/dev/null 2>&1; then
  echo "inventory-worktrees: could not fetch ${REMOTE}/${DEFAULT_BRANCH}, reading the local copy" >&2
fi

HAVE_REMOTE_REF=1
if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$REMOTE_REF" >/dev/null 2>&1; then
  HAVE_REMOTE_REF=0
  echo "inventory-worktrees: $REMOTE_REF does not exist, so nothing can be shown as finished" >&2
fi

load_manifest

if ! git -C "$REPO_ROOT" worktree list --porcelain > "$TMPD/list" 2>/dev/null; then
  die "could not list the worktrees of $REPO_ROOT"
fi

REC_PATH=""
REC_HEAD=""
REC_BRANCH=""
REC_BARE=0
REC_DETACHED=0
REC_LOCKED=0
REC_LOCK_REASON=""

reset_record() {
  REC_PATH=""
  REC_HEAD=""
  REC_BRANCH=""
  REC_BARE=0
  REC_DETACHED=0
  REC_LOCKED=0
  REC_LOCK_REASON=""
}

WOULD_REMOVE=0
KEPT=0
INDEX=0

# Pass one: read every working tree, before the forge call. Reading them first
# keeps the window the removal re-check has to close as small as possible, and
# it is the slow forge call that opens that window.
scan_record() {
  local path name branch

  if [ -z "$REC_PATH" ] || [ "$REC_BARE" -eq 1 ]; then
    return 0
  fi
  INDEX=$((INDEX + 1))
  path="$(canonicalize "$REC_PATH")"
  case "$path" in
    "$REPO_ROOT"/*) name="${path#"$REPO_ROOT"/}" ;;
    *) name="${path##*/}" ;;
  esac
  branch="${REC_BRANCH#refs/heads/}"
  if [ "$REC_DETACHED" -eq 1 ] || [ -z "$branch" ]; then
    branch=""
  fi
  classify_dirt "$path" "$TMPD/dirt.$INDEX"
  row "$INDEX" "$name" "$path" "$branch" "$REC_HEAD" "$REC_LOCKED" \
    "$REC_LOCK_REASON" "$DIRT_KIND" >> "$RECORDS"
}

# Pass two: turn one scanned record into a report line and, when it is
# finished, a removal.
evaluate_record() {
  local index="$1" name="$2" path="$3" branch="$4" head="$5"
  local locked="$6" lock_reason="$7" dirt_kind="$8"
  local age state done_text verdict reason dirt_file
  local pr_state pr_number pr_match pr_title age_days now commit_ts

  age="$(git -C "$REPO_ROOT" log -1 --format=%cr "$head" 2>/dev/null || true)"
  if [ -z "$age" ]; then
    age="-"
  fi
  commit_ts="$(git -C "$REPO_ROOT" log -1 --format=%ct "$head" 2>/dev/null || true)"
  age_days=""
  case "$commit_ts" in
    '' | *[!0-9]*) ;;
    *)
      now="$(date +%s)"
      age_days=$(((now - commit_ts) / 86400))
      ;;
  esac

  dirt_file="$TMPD/dirt.$index"
  state="clean"
  case "$dirt_kind" in
    warm) state="warm" ;;
    real) state="dirty" ;;
    '') state="unknown" ;;
  esac
  if [ "$locked" -eq 1 ]; then
    if [ "$state" = "clean" ]; then
      state="locked"
    else
      state="$state,locked"
    fi
  fi

  # The pull request this branch is judged by, picked once and used for both
  # the done signal and the reason column.
  pr_state=""
  pr_number=""
  pr_match=""
  pr_title=""
  if [ -n "$branch" ]; then
    read -r pr_state pr_number pr_match pr_title <<< "$(pr_for_branch "$branch" "$head")" || true
  fi

  # The done signal, and the reason to keep when there is none.
  done_text="-"
  reason=""
  if [ "$HAVE_REMOTE_REF" -eq 0 ]; then
    # Fail closed: with no remote copy of the default branch there is nothing
    # to prove a branch landed, so nothing is offered for removal.
    reason="no ${REMOTE}/${DEFAULT_BRANCH} to compare against"
  elif git -C "$REPO_ROOT" merge-base --is-ancestor "$head" "$REMOTE_REF" 2>/dev/null; then
    done_text="merged into ${REMOTE}/${DEFAULT_BRANCH}"
  else
    if [ "$pr_state" = "OPEN" ]; then
      done_text="open pr #$pr_number"
      reason="open pr #$pr_number"
    elif [ "$pr_state" = "MERGED" ] && [ "$pr_match" = "1" ]; then
      done_text="pr #$pr_number merged"
    elif [ "$pr_state" = "MERGED" ]; then
      done_text="pr #$pr_number merged"
      reason="commits after merged pr #$pr_number"
    elif [ "$pr_state" = "CLOSED" ]; then
      reason="pr #$pr_number closed without merging"
    elif [ "$GH_OK" -eq 1 ]; then
      reason="not merged, no pull request"
    else
      reason="not merged"
    fi
    if [ -n "$age_days" ] && [ "$age_days" -gt "$STALE_DAYS" ] && [ -n "$reason" ]; then
      case "$reason" in
        open*) ;;
        *) reason="$reason, stale $age_days days" ;;
      esac
    fi
  fi

  # Blockers outrank everything, including a finished branch.
  if [ -z "$branch" ]; then
    reason="detached head"
  elif [ "$branch" = "$DEFAULT_BRANCH" ]; then
    reason="default branch"
  elif [ "$locked" -eq 1 ]; then
    if [ -n "$lock_reason" ]; then
      reason="locked: $lock_reason"
    else
      reason="locked"
    fi
  elif [ "$dirt_kind" = "real" ]; then
    reason="local changes: $(first_three "$dirt_file")"
  elif [ -z "$dirt_kind" ]; then
    reason="could not read the working tree"
  fi

  if [ -n "$reason" ]; then
    verdict="kept: $reason"
    KEPT=$((KEPT + 1))
  else
    verdict="would remove"
    WOULD_REMOVE=$((WOULD_REMOVE + 1))
    row "$name" "$path" "$branch" >> "$REMOVALS"
  fi

  # Why this worktree exists, in its own words: the title of the pull request
  # it is judged by, or failing that the subject of its last commit.
  local why="$pr_title"
  if [ -z "$why" ]; then
    why="$(git -C "$REPO_ROOT" log -1 --format=%s "$head" 2>/dev/null || true)"
  fi

  local shown="$name"
  if [ "$branch" = "$DEFAULT_BRANCH" ]; then
    shown="*$name"
  fi
  local branch_shown="$branch"
  if [ -z "$branch_shown" ]; then
    branch_shown="(detached)"
  fi
  row "$shown" "$branch_shown" "$age" "$state" "$done_text" "$verdict" \
    "$(short "$why")" >> "$ROWS"
}

reset_record
while IFS= read -r line <&3 || [ -n "$line" ]; do
  if [ -z "$line" ]; then
    scan_record
    reset_record
    continue
  fi
  key="${line%% *}"
  if [ "$key" = "$line" ]; then
    value=""
  else
    value="${line#* }"
  fi
  case "$key" in
    worktree) REC_PATH="$value" ;;
    HEAD) REC_HEAD="$value" ;;
    branch) REC_BRANCH="$value" ;;
    bare) REC_BARE=1 ;;
    detached) REC_DETACHED=1 ;;
    locked)
      REC_LOCKED=1
      REC_LOCK_REASON="$value"
      ;;
  esac
done 3< "$TMPD/list"
scan_record

fetch_prs

while IFS="$US" read -r r_index r_name r_path r_branch r_head r_locked \
  r_lock_reason r_dirt <&3 || [ -n "$r_index" ]; do
  if [ -z "$r_index" ]; then
    continue
  fi
  evaluate_record "$r_index" "$r_name" "$r_path" "$r_branch" "$r_head" \
    "$r_locked" "$r_lock_reason" "$r_dirt"
done 3< "$RECORDS"

if [ ! -s "$ROWS" ]; then
  echo "No linked worktrees."
  exit 0
fi

{
  row "NAME" "BRANCH" "AGE" "STATE" "DONE" "VERDICT" "REASON"
  cat "$ROWS"
} > "$TMPD/table"
render_table "$TMPD/table"

if [ "$DO_REMOVE" -eq 0 ]; then
  echo
  echo "would remove: $WOULD_REMOVE  kept: $KEPT"
  if [ "$WOULD_REMOVE" -gt 0 ]; then
    if [ "$WOULD_REMOVE" -eq 1 ]; then
      echo "re-run with --remove to remove 1 worktree."
    else
      echo "re-run with --remove to remove $WOULD_REMOVE worktrees."
    fi
  fi
  exit 0
fi

REMOVED=0
SKIPPED=0
echo

while IFS="$US" read -r name path branch <&3 || [ -n "$name" ]; do
  if [ -z "$name" ]; then
    continue
  fi

  # The re-check closes the window between the report and the removal. Only a
  # tree confirmed warm here is ever removed with --force.
  classify_dirt "$path" "$TMPD/recheck"
  case "$DIRT_KIND" in
    clean) FORCE="" ;;
    warm) FORCE="--force" ;;
    *)
      echo "inventory-worktrees: $name changed since the report, skipped" >&2
      SKIPPED=$((SKIPPED + 1))
      EXIT_CODE=3
      continue
      ;;
  esac

  if [ -n "$FORCE" ]; then
    if ! git -C "$REPO_ROOT" worktree remove --force "$path" 2>"$TMPD/err"; then
      echo "inventory-worktrees: $name could not be removed: $(head -n 1 "$TMPD/err")" >&2
      SKIPPED=$((SKIPPED + 1))
      EXIT_CODE=3
      continue
    fi
  else
    if ! git -C "$REPO_ROOT" worktree remove "$path" 2>"$TMPD/err"; then
      echo "inventory-worktrees: $name could not be removed: $(head -n 1 "$TMPD/err")" >&2
      SKIPPED=$((SKIPPED + 1))
      EXIT_CODE=3
      continue
    fi
  fi
  echo "Removed $name"
  REMOVED=$((REMOVED + 1))

  if [ -n "$branch" ]; then
    if git -C "$REPO_ROOT" branch -d "$branch" >/dev/null 2>&1; then
      echo "Deleted branch $branch"
    else
      # git refuses when the branch is not merged in its own history, which is
      # what a squash merge produces. Hand the exact command over instead of
      # forcing it.
      echo "Kept branch $branch, git will not delete it as merged. To delete it:"
      echo "    git -C \"$REPO_ROOT\" branch -D $branch"
    fi
  fi
done 3< "$REMOVALS"

echo
echo "removed: $REMOVED  skipped: $SKIPPED  kept: $KEPT"
exit "$EXIT_CODE"
