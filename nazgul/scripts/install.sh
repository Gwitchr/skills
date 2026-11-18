#!/usr/bin/env bash
# nazgul install.sh: enroll a repo and wire nazgul's hooks without writing anything into the repo.
#
#   install.sh [--enroll] [--slug <slug>] [--only claude,codex,grok,omp,git] [--cwd <dir>]
#   install.sh --unenroll [--cwd <dir>]
#
# --enroll (the default) works from any worktree of the repo, or from a bare repo itself:
#   ~/.config/nazgul/config            [project "<git common dir>"]; slug= only when it differs
#                                      from the repo name
#   user-level hooks, for each tool whose home folder exists, or each tool --only names:
#     ~/.claude/settings.json          Stop -> check.sh --agent claude  (merged, other settings kept)
#     ~/.codex/hooks.json              Stop -> check.sh --agent codex   (merged, other hooks kept)
#     ~/.grok/hooks/nazgul.json        Stop -> check.sh --agent grok
#     ~/.omp/agent/hooks/post/nazgul.ts  agent_end -> check.sh --agent omp --background
#   <git common dir>/hooks/commit-msg  backstop warning; skipped when core.hooksPath is set or a
#                                      commit-msg hook of another tool is there
# The hooks run in every repo and exit at once unless the repo is enrolled. CLAUDE_CONFIG_DIR,
# CODEX_HOME, GROK_HOME and PI_CODING_AGENT_DIR move those folders. Running it again changes only
# nazgul's own entries.
# --unenroll removes the repo's [project] section, its commit-msg backstop and <git common dir>/nazgul/.
# When no enrolled repo is left, it also removes nazgul's user-level hooks.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { nz_warn "$*"; exit 1; }
disp() { printf '%s' "${1/#$HOME\//~/}"; }

action="enroll"; slug=""; set_slug=0; only=""; cwd="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --enroll) action="enroll"; shift ;;
    --unenroll) action="unenroll"; shift ;;
    --slug|--only|--cwd)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in --slug) slug="$2"; set_slug=1 ;; --only) only="$2" ;; --cwd) cwd="$2" ;; esac
      shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
common="$(nz_common "$cwd")" || die "not inside a git repo: $cwd"
[[ "$common" != *'"'* && "$common" != *$'\n'* ]] || die "the repo path holds a quote or a newline: $common"

claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
grok_home="${GROK_HOME:-$HOME/.grok}"
omp_home="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
claude_file="$claude_home/settings.json"
codex_file="$codex_home/hooks.json"
grok_file="$grok_home/hooks/nazgul.json"
omp_file="$omp_home/hooks/post/nazgul.ts"
backstop="$common/hooks/commit-msg"

# The regex that finds nazgul's own entry for <agent> in a JSON hooks file.
entry_re() { printf '%s' 'scripts/check\.sh" --agent '"$1"'( |$)'; }
JQ_STRIP='def strip($re): .hooks.Stop = [(.hooks.Stop // [])[]
  | .hooks = [(.hooks // [])[] | select((.command // "") | test($re) | not)] | select(.hooks | length > 0)];'

# unmerge <file> <agent>: takes nazgul's entry out of a JSON hooks file; deletes the file when
# nothing else is left in it.
unmerge() {
  local dest="$1" re tmp
  re="$(entry_re "$2")"
  [[ -f "$dest" ]] || return 0
  jq -e --arg re "$re" 'type == "object" and ([.hooks.Stop[]?.hooks[]?.command // "" | test($re)] | any)' \
    "$dest" >/dev/null 2>&1 || return 0
  tmp="$(nz_tmp)" || return 0
  jq --arg re "$re" "$JQ_STRIP"'
    strip($re) | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end' "$dest" >"$tmp" || { rm -f "$tmp"; return 0; }
  if [[ "$(jq -c . "$tmp")" == "{}" ]]; then
    rm -f "$tmp" "$dest"; printf '  removed    %s\n' "$(disp "$dest")"
  else
    cat "$tmp" >"$dest"; rm -f "$tmp"; printf '  cleaned    %s\n' "$(disp "$dest")"
  fi
}

# unplace <file> <marker>: deletes a file nazgul wrote, recognised by a line it always holds.
unplace() {
  [[ -f "$1" ]] && grep -qF -- "$2" "$1" || return 0
  rm -f "$1" && printf '  removed    %s\n' "$(disp "$1")"
}

remove_user_hooks() {
  unmerge "$claude_file" claude
  unmerge "$codex_file" codex
  unplace "$grok_file" 'check.sh\" --agent grok'
  unplace "$omp_file" 'nazgul for Oh My Pi'
}

# ---------- unenroll ----------
if [[ "$action" == unenroll ]]; then
  printf 'nazgul: unenrolling %s\n' "$common"
  if nz_enrolled "$common"; then
    nz_cfg_edit drop "$common" && printf '  removed    [project "%s"] from %s\n' "$common" "$(disp "$NZ_USER_CONFIG")"
  else
    printf '  not enrolled; removing any leftovers\n'
  fi
  if [[ -f "$backstop" ]] && grep -q 'nazgul backstop' "$backstop"; then
    rm -f "$backstop" && printf '  removed    %s\n' "$backstop"
  fi
  if [[ -n "$common" && -d "$common/nazgul" ]]; then
    rm -rf "${common:?}/nazgul" && printf '  removed    %s/nazgul/ (session state)\n' "$common"
  fi
  if [[ -z "$(nz_projects)" ]]; then
    printf 'nazgul: no enrolled repo is left, so the user-level hooks go too\n'
    remove_user_hooks
  fi
  exit 0
fi

# ---------- enroll ----------
safe='^[A-Za-z0-9._/@+~ -]+$'
[[ "$NZ_SKILL" =~ $safe ]] || die "the skill path holds characters a hook command cannot quote safely: $NZ_SKILL"
if [[ "$(nz_common "$NZ_SKILL" 2>/dev/null)" == "$common" ]] && git -C "$NZ_SKILL" rev-parse --show-toplevel >/dev/null 2>&1; then
  die "the skill sits inside a work tree of this repo ($NZ_SKILL). It would show in git status and vanish with the worktree. Move it out, for example to ~/.agents/skills/nazgul, and run install.sh from there."
fi

want() {
  if [[ -n "$only" ]]; then [[ ",$only," == *",$1,"* ]]; return; fi
  case "$1" in
    claude) [[ -d "$claude_home" ]] ;;
    codex) [[ -d "$codex_home" ]] ;;
    grok) [[ -d "$grok_home" ]] ;;
    omp) [[ -d "$omp_home" || -d "$HOME/.omp" ]] ;;
    *) return 0 ;;
  esac
}

# render <template>: the template with __NAZGUL_SH__ replaced by the scripts folder. Plain string
# replacement, so no character of the path is read as a pattern.
render() {
  NZ_SH="$NZ_SCRIPTS" awk '
    function rep(s, from, to,   out, i) {
      out = ""
      while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) }
      return out s
    }
    { print rep($0, "__NAZGUL_SH__", ENVIRON["NZ_SH"]) }' "$NZ_SKILL/hooks/$1"
}

# place <template> <dest> [mode]: writes nazgul's own file, reporting created / updated / unchanged.
place() {
  local dest="$2" tmp
  tmp="$(nz_tmp)" || die "no temp file"
  render "$1" >"$tmp"
  mkdir -p "$(dirname "$dest")" || { rm -f "$tmp"; nz_warn "cannot create $(dirname "$dest")"; return; }
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; printf '  unchanged  %s\n' "$(disp "$dest")"; return; fi
  [[ -f "$dest" ]] && printf '  updated    %s\n' "$(disp "$dest")" || printf '  created    %s\n' "$(disp "$dest")"
  mv "$tmp" "$dest"
  chmod "${3:-644}" "$dest"
}

# merge <template> <dest> <agent>: puts nazgul's Stop entry into a JSON hooks file. nazgul's old
# entry for <agent> is replaced; everything else in the file stays.
merge() {
  local dest="$2" new tmp re
  re="$(entry_re "$3")"
  new="$(render "$1")"
  tmp="$(nz_tmp)" || die "no temp file"
  if [[ -f "$dest" ]]; then
    jq -e 'type == "object" and ((.hooks // {}) | type == "object")' "$dest" >/dev/null 2>&1 \
      || { nz_warn "$(disp "$dest") is not a JSON object with a hooks object; left alone"; rm -f "$tmp"; return; }
    jq --argjson new "$new" --arg re "$re" "$JQ_STRIP"'
      .hooks = (.hooks // {}) | strip($re) | .hooks.Stop += $new.hooks.Stop' "$dest" >"$tmp" \
      || { nz_warn "could not merge into $(disp "$dest"); left alone"; rm -f "$tmp"; return; }
    if cmp -s "$tmp" "$dest"; then rm -f "$tmp"; printf '  unchanged  %s\n' "$(disp "$dest")"; return; fi
    # Written in place, so a symlinked settings file stays a symlink and keeps its mode.
    cat "$tmp" >"$dest" && rm -f "$tmp"
    printf '  merged     %s\n' "$(disp "$dest")"
    return
  else
    mkdir -p "$(dirname "$dest")" || { rm -f "$tmp"; nz_warn "cannot create $(dirname "$dest")"; return; }
    printf '%s\n' "$new" | jq . >"$tmp"
    chmod 600 "$tmp"
    printf '  created    %s\n' "$(disp "$dest")"
  fi
  mv "$tmp" "$dest"
}

default_slug="$(nz_default_slug "$common")"
printf 'nazgul: enrolling %s\n' "$common"
if nz_enrolled "$common"; then
  printf '  unchanged  [project "%s"] in %s\n' "$common" "$(disp "$NZ_USER_CONFIG")"
else
  if [[ $set_slug -eq 0 && -t 0 ]]; then
    read -r -p "Project slug in the report repo [$default_slug]: " slug || slug=""
    [[ -n "$slug" ]] && set_slug=1
  fi
  nz_cfg_edit add "$common" || die "cannot write $NZ_USER_CONFIG"
  printf '  added      [project "%s"] to %s\n' "$common" "$(disp "$NZ_USER_CONFIG")"
fi
if [[ $set_slug -eq 1 ]]; then
  s="$(nz_slug "$slug")"
  [[ -n "$s" ]] || die "the slug is empty after cleanup: '$slug'"
  if [[ "$s" == "$default_slug" ]]; then nz_cfg_edit unset "$common" slug; else nz_cfg_edit set "$common" slug "$s"; fi
fi
project="$(nz_cfg "$common" slug)" || project="$default_slug"
printf '  project    %s (reports go to projects/%s/ in the report repo)\n' "$project" "$project"

home_of() {
  if [[ "$1" == claude ]]; then disp "$claude_home"
  elif [[ "$1" == codex ]]; then disp "$codex_home"
  elif [[ "$1" == grok ]]; then disp "$grok_home"
  else disp "${PI_CODING_AGENT_DIR:-$HOME/.omp}"; fi
}
installed=""
for tool in claude codex grok omp; do
  if ! want "$tool"; then
    printf '  skipped    %s (no %s; rerun with --only %s to force it)\n' "$tool" "$(home_of "$tool")" "$tool"
    continue
  fi
  installed="$installed $tool"
  case "$tool" in
    claude) merge claude.settings.json "$claude_file" claude ;;
    codex) merge codex.hooks.json "$codex_file" codex ;;
    grok) place grok.hooks.json "$grok_file" ;;
    omp) place omp/post/nazgul.ts "$omp_file" ;;
  esac
done

if want git; then
  hooks_path="$(git -C "$cwd" config --get core.hooksPath 2>/dev/null)"
  if [[ -n "$hooks_path" ]]; then
    printf '  skipped    commit-msg backstop: core.hooksPath is set (%s), so git runs no hook from\n' "$hooks_path"
    printf '             %s/hooks; the repo hook setup is left alone\n' "$common"
  elif [[ -f "$backstop" ]] && ! grep -q 'nazgul backstop' "$backstop"; then
    printf '  skipped    %s (another commit-msg hook is there; to add the warning, put this line in it:)\n' "$backstop"
    printf '             bash "%s/check.sh" --commit-msg "$1" || true\n' "$NZ_SCRIPTS"
  else
    place commit-msg "$backstop" 755
  fi
fi

repo_set=1; [[ -n "${NAZGUL_REPO:-}" ]] || nz_cfg "" repo >/dev/null || repo_set=0
printf '\nNext steps\n'
[[ $repo_set -eq 1 ]] || printf -- '- No report repo yet: run bash "%s/config.sh". Until then the hooks do nothing.\n' "$NZ_SCRIPTS"
case "$installed" in *claude*) cat <<'EOF'
- Claude Code: the Stop hook loads at the next session start; /hooks lists it.
EOF
esac
case "$installed" in *codex*) cat <<'EOF'
- Codex: when Codex asks you to review new hooks, choose "Trust all and continue", or run /hooks and
  press t. Codex skips an untrusted or changed hook, so trust it again after install.sh changes it.
EOF
esac
case "$installed" in *grok*) cat <<'EOF'
- Grok: your ~/.grok hooks run only in folders you trust, and each worktree counts as its own
  folder. Accept Grok's trust prompt, or run /hooks-trust, once per worktree.
EOF
esac
case "$installed" in *omp*) cat <<'EOF'
- Oh My Pi: the hook loads at the next session start; there is no trust step.
EOF
esac
cat <<EOF
- Every worktree of this repo, including new ones, is covered; nothing was written inside the repo.
  To undo: bash "$NZ_SCRIPTS/install.sh" --unenroll
EOF
