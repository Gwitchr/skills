#!/usr/bin/env bash
# nazgul install.sh: wire nazgul's hooks into a project repo.
#
#   install.sh [--project-dir <dir>] [--only claude,codex,grok,omp,git]
#
# From the skill's hooks/ folder it creates or updates:
#   .claude/settings.json       Stop -> check.sh --agent claude   (merged: other settings and hooks kept)
#   .codex/hooks.json           Stop -> check.sh --agent codex    (merged: other hooks kept)
#   .grok/hooks/nazgul.json     Stop -> check.sh --agent grok
#   .omp/hooks/post/nazgul.ts   agent_end -> check.sh --agent omp --background
#   <git hooks dir>/commit-msg  backstop warning (left alone when a commit-msg hook of another tool exists)
# and adds .nazgul to .gitignore. Running it again replaces nazgul's own entries and nothing else.
# Hooks find the scripts from the git root at run time when the skill sits inside the repo, and by
# absolute path (this machine only) when it does not.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { nz_warn "$*"; exit 1; }

project_dir="$PWD"; only="claude,codex,grok,omp,git"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --project-dir|--only)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      [[ "$1" == --only ]] && only="$2" || project_dir="$2"
      shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
want() { [[ ",$only," == *",$1,"* ]]; }

command -v jq >/dev/null 2>&1 || die "jq is required"
root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git work tree: $project_dir"
root="$(cd "$root" && pwd -P)"
safe='^[A-Za-z0-9._/@+~ -]+$'
[[ "$NZ_SKILL" =~ $safe ]] || die "the skill path holds characters a hook command cannot quote safely: $NZ_SKILL"

case "$NZ_SKILL/" in
  "$root"/*)
    rel="${NZ_SKILL#"$root"/}"
    sh_dir="\$(git rev-parse --show-toplevel)/$rel/scripts"
    plain_dir="$rel/scripts" ;;
  *)
    sh_dir="$NZ_SKILL/scripts"
    plain_dir="$NZ_SKILL/scripts"
    nz_warn "the skill sits outside this repo, so the hooks use $NZ_SKILL/scripts, which only exists on this machine" ;;
esac

# render <template>: the template with both placeholders filled in. Plain string replacement, so no
# character of the path is read as a pattern.
render() {
  NZ_SH="$sh_dir" NZ_PATH="$plain_dir" awk '
    function rep(s, from, to,   out, i) {
      out = ""
      while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) }
      return out s
    }
    { line = rep($0, "__NAZGUL_SH__", ENVIRON["NZ_SH"]); print rep(line, "__NAZGUL_PATH__", ENVIRON["NZ_PATH"]) }' "$1"
}

# place <template> <dest> [mode]: writes nazgul's own file, reporting created / updated / unchanged.
place() {
  local tpl="$NZ_SKILL/hooks/$1" dest="$root/$2" tmp
  tmp="$(nz_tmp)" || die "no temp file"
  render "$tpl" >"$tmp"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; printf '  unchanged  %s\n' "$2"; return; fi
  [[ -f "$dest" ]] && printf '  updated    %s\n' "$2" || printf '  created    %s\n' "$2"
  mv "$tmp" "$dest"
  chmod "${3:-644}" "$dest"
}

# merge <template> <dest> <agent>: puts nazgul's Stop entry into a JSON hooks file. Entries that run
# check.sh --agent <agent> are replaced; everything else in the file stays as it was.
merge() {
  local tpl="$NZ_SKILL/hooks/$1" dest="$root/$2" agent="$3" new tmp
  new="$(render "$tpl")"
  tmp="$(nz_tmp)" || die "no temp file"
  if [[ -f "$dest" ]]; then
    jq -e 'type == "object"' "$dest" >/dev/null 2>&1 || { nz_warn "$2 is not a JSON object; left alone"; rm -f "$tmp"; return; }
    jq --argjson new "$new" --arg re 'scripts/check\.sh" --agent '"$agent"'( |$)' '
      .hooks = ((.hooks // {}) | .Stop = ([.Stop[]? | select([.hooks[]?.command // "" | test($re)] | any | not)] + $new.hooks.Stop))
    ' "$dest" >"$tmp" || { nz_warn "could not merge into $2; left alone"; rm -f "$tmp"; return; }
    if cmp -s "$tmp" "$dest"; then rm -f "$tmp"; printf '  unchanged  %s\n' "$2"; return; fi
    printf '  merged     %s\n' "$2"
  else
    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$new" | jq . >"$tmp"
    printf '  created    %s\n' "$2"
  fi
  mv "$tmp" "$dest"
  chmod 644 "$dest"
}

printf 'nazgul: installing into %s\n' "$root"
want claude && merge claude.settings.json .claude/settings.json claude
want codex && merge codex.hooks.json .codex/hooks.json codex
want grok && place grok.hooks.json .grok/hooks/nazgul.json
want omp && place omp/post/nazgul.ts .omp/hooks/post/nazgul.ts

if want git; then
  hooks_dir="$(cd "$root" && git rev-parse --git-path hooks)"
  case "$hooks_dir" in /*) ;; *) hooks_dir="$root/$hooks_dir" ;; esac
  dest="$hooks_dir/commit-msg"
  if [[ -f "$dest" ]] && ! grep -q 'nazgul backstop' "$dest"; then
    printf '  skipped    %s (another commit-msg hook is there; add this line to it:)\n' "$dest"
    printf '             bash "%s/check.sh" --commit-msg "$1" || true\n' "$sh_dir"
  else
    tmp="$(nz_tmp)" || die "no temp file"
    render "$NZ_SKILL/hooks/commit-msg" >"$tmp"
    mkdir -p "$hooks_dir"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; printf '  unchanged  %s\n' "$dest"
    else
      [[ -f "$dest" ]] && printf '  updated    %s\n' "$dest" || printf '  created    %s\n' "$dest"
      mv "$tmp" "$dest"
    fi
    chmod 755 "$dest"
  fi
fi

if ! git -C "$root" check-ignore -q .nazgul 2>/dev/null; then
  [[ -s "$root/.gitignore" && -n "$(tail -c 1 "$root/.gitignore")" ]] && printf '\n' >>"$root/.gitignore"
  printf '.nazgul\n' >>"$root/.gitignore"
  printf '  updated    .gitignore (.nazgul)\n'
fi

cat <<EOF

Next steps
- Config: when ${NZ_USER_CONFIG/#$HOME/~} has no repo= line yet, run: bash "$NZ_SKILL/scripts/config.sh"
  Until then every hook exits at once and does nothing.
EOF
want claude && cat <<'EOF'
- Claude Code: the Stop hook loads at the next session start; /hooks shows it.
EOF
want codex && cat <<'EOF'
- Codex: trust the project when Codex asks. Then trust the hook: choose "Trust all and continue"
  at the "Hooks need review" prompt, or run /hooks and press t. Codex runs an untrusted or changed
  hook not at all, so trust it again after install.sh changes the hook command.
EOF
want grok && cat <<'EOF'
- Grok: run /hooks-trust in a session inside this repo (or start it with grok --trust), then run
  /hooks and press r to reload, or start a new session.
EOF
want omp && cat <<'EOF'
- Oh My Pi: no trust step. Start omp from the repo root; it reads .omp/ only in its start folder.
EOF
cat <<'EOF'
- Commit the hook files and the skill folder when teammates should get them. On a machine with no
  nazgul config the hooks do nothing.
EOF
