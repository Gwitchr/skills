#!/usr/bin/env bash
# nazgul tests: the scripts against a fake gh, no network. bash tests/run.sh
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skill_src="$(dirname "$here")"
T="$(mktemp -d "${TMPDIR:-/tmp}/nazgul-test.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT
cd "$T" || exit 1

export PATH="$here/bin:$PATH"
export HOME="$T/home"; mkdir -p "$HOME"
export FAKE_GH_ROOT="$T/remote" FAKE_GH_LOG="$T/gh.log"
export NAZGUL_POLL_INTERVAL=0 NAZGUL_POLL_TRIES=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset XDG_CONFIG_HOME NAZGUL_REPO NAZGUL_CONFIG NAZGUL_OFF NAZGUL_SESSION NAZGUL_AGENT CLAUDECODE \
  CODEX_THREAD_ID CODEX_SESSION_ID GROK_HOOK_EVENT GROK_SESSION_ID GROK_WORKSPACE_ROOT CURSOR_AGENT
mkdir -p "$FAKE_GH_ROOT/owner/reports"

pass=0; fail=0
ok() {
  if eval "$2"; then pass=$((pass + 1)); printf '  ok    %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; printf '        out=%s\n        err=%s\n' "${out:-}" "$(cat "$T/err" 2>/dev/null)" >&2; fi
}

SK="$HOME/.agents/skills/nazgul"
mkdir -p "$(dirname "$SK")" && cp -R "$skill_src" "$SK" && rm -rf "$SK/tests"
S="$(cd "$SK/scripts" && pwd -P)"
CFG="$HOME/.config/nazgul/config"
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.grok" "$HOME/.omp"

P="$T/work/widget"
git -C "$T" init -q -b main work/widget
printf 'hello\n' >"$P/README.md"; printf 'node_modules/\n' >"$P/.gitignore"
git -C "$P" add -A && git -C "$P" commit -qm init
git -C "$P" remote add origin https://github.com/owner/widget.git
PC="$(cd "$P/.git" && pwd -P)"
THREADS="$FAKE_GH_ROOT/owner/reports/projects/widget/threads"

pl() { # session [active] [message] [cwd]
  jq -nc --arg s "$1" --argjson a "${2:-false}" --arg m "${3:-Done.}" --arg c "${4:-$P}" \
    '{hook_event_name:"Stop",session_id:$s,cwd:$c,stop_hook_active:$a,last_assistant_message:$m}'
}
check() { bash "$S/check.sh" "$@" 2>"$T/err"; }
body() {
  printf '## Changed\nAdded a widget.\n\n## Why\nAsked for.\n\n## Where\n- https://github.com/owner/widget/tree/main\n\n## Left\nnothing\n\n## Needs owner\nnothing\n'
}
clean() { [[ -z "$(git -C "$1" status --porcelain --ignored)" && -z "$(git -C "$1" diff)" ]]; }
setcfg() { (. "$S/lib.sh"; nz_cfg_edit set "" "$1" "$2"); }
unsetcfg() { (. "$S/lib.sh"; nz_cfg_edit unset "" "$1"); }
arm() { # <auto_continue> <authors or -> <require_verified>
  setcfg auto_continue "$1"
  if [[ "$2" == "-" ]]; then unsetcfg reply_authors; else setcfg reply_authors "$2"; fi
  setcfg require_verified "$3"
}
report_session() {
  # A branch per session, so threads opened in the same minute do not share an id.
  git -C "$P" checkout -q -b "t-$1"
  pl "$1" | check --agent claude >/dev/null
  (cd "$P" && body | bash "$S/report.sh" --agent claude --session "$1" --summary "$1" >/dev/null 2>&1)
}
poll_session() { pl "$1" true | check --agent claude; }
plant() { # <session> <action> <body> [author] [verified] [committer]
  local sid="$1" action="$2" text="$3" author="${4:-responder}" verified="${5:-true}" committer="${6:-}"
  local tid last n name rel reason
  [[ -n "$committer" ]] || committer="$author"
  tid="$(head -n 1 "$PC/nazgul/sessions/$sid.thread")"
  last="$(head -n 1 "$PC/nazgul/sessions/$sid.last")"
  n=$((last + 1))
  name="$(printf '%03d_%s.md' "$n" "$author")"
  rel="projects/widget/threads/$tid/$name"
  mkdir -p "$THREADS/$tid"
  printf -- '---\nfrom: %s\nin_reply_to: %s\naction: %s\n---\n\n%s\n' "$author" "$last" "$action" "$text" >"$THREADS/$tid/$name"
  if [[ "$verified" == true ]]; then reason=valid; else reason=unsigned; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$author" "$committer" "$verified" "$reason" >>"$FAKE_GH_ROOT/commit-meta.tsv"
}

echo "unenrolled"
bash "$S/config.sh" --repo owner/reports --skip-paths "$T/skipme" </dev/null >/dev/null
: >"$FAKE_GH_LOG"
out="$(pl s0 | check --agent claude)"; rc=$?
out2="$(cd "$P" && body | bash "$S/report.sh" --agent claude --session s0 2>&1)"; rc2=$?
ok "unenrolled repo does nothing" '[[ $rc -eq 0 && $rc2 -eq 0 && -z "$out" && -z "$out2" && ! -s "$FAKE_GH_LOG" ]]'

echo "enroll"
out="$(cd "$P" && bash "$S/install.sh" --enroll </dev/null 2>"$T/err")"; rc=$?
ok "plain clone stays clean after enroll" '[[ $rc -eq 0 && -z "$(cat "$T/err")" ]] && clean "$P"'
B="$T/bare"; mkdir -p "$B"
git clone -q --bare "$P" "$B/gadget.git"
git -C "$B/gadget.git" worktree add -q "$B/main" main
out="$(cd "$B/main" && bash "$S/install.sh" --enroll </dev/null 2>"$T/err")"; rc=$?
ok "bare-repo worktree stays clean after enroll" '[[ $rc -eq 0 ]] && clean "$B/main"'
ok "each tool hook JSON is valid" 'jq -e ".hooks.Stop[0].hooks[0].timeout == 660 and (.hooks.Stop[0].hooks[0].command | contains(\"check.sh\") and contains(\"--agent claude\"))" "$HOME/.claude/settings.json" >/dev/null && jq -e ".hooks.Stop[0].hooks[0].timeout == 660 and (.hooks.Stop[0].hooks[0].command | contains(\"--agent codex\"))" "$HOME/.codex/hooks.json" >/dev/null && jq -e ".hooks.Stop[0].hooks[0].timeout == 660 and (.hooks.Stop[0].hooks[0].command | contains(\"--agent grok\"))" "$HOME/.grok/hooks/nazgul.json" >/dev/null && grep -q "nazgul-deliver: inject" "$HOME/.omp/agent/hooks/post/nazgul.ts" && grep -q "mode === \"inject\"" "$HOME/.omp/agent/hooks/post/nazgul.ts"'

echo "skip path"
mkdir -p "$T/skipme/proj" && git -C "$T/skipme/proj" init -q -b main
bash "$S/install.sh" --enroll --only git --cwd "$T/skipme/proj" </dev/null >/dev/null 2>&1
out="$(pl s9 false Done. "$T/skipme/proj" | check --agent claude)"; rc=$?
ok "skip path does nothing" '[[ $rc -eq 0 && -z "$out" && ! -s "$T/err" ]]'

echo "report"
secret="ghp_$(printf 'a%.0s' {1..36})"
out="$(cd "$P" && body | sed "s/Added a widget./Added a widget. $secret/" | bash "$S/report.sh" --agent claude --session secret 2>&1)"; rc=$?
ok "secret scan blocks a push" '[[ $rc -eq 3 && "$out" == *"refusing to push"* && "$out" != *"$secret"* && ! -f "$PC/nazgul/sessions/secret.thread" ]]'
out="$(cd "$P" && body | bash "$S/report.sh" --agent claude --session pushed --summary "Added the widget" 2>&1)"; rc=$?
ok "report gets pushed" '[[ $rc -eq 0 && "$out" == *"pushed projects/widget/threads/"*"/001_claude.md"* ]] && grep -q "nazgul(widget): Added the widget" "$FAKE_GH_ROOT/commits.log"'

echo "replies"
arm true - true
report_session no-authors
plant no-authors continue "STEER the agent from an unsigned stranger."
out="$(poll_session no-authors)"
ok "no reply_authors: a continue reply is not acted on" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"reply_authors is not set"* && "$out" != *STEER* && "$(cat "$T/err")" != *STEER* ]]'

arm true responder true
report_session no-reply
out="$(poll_session no-reply)"
ok "no reply ends the session" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"no reply"* ]]'

arm false responder true
report_session c-off
plant c-off continue "Add the off-switch tests."
out="$(poll_session c-off)"
ok "continue with auto_continue off is shown and does not steer" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"auto_continue is off"* && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"Add the off-switch tests."* && "$out" != *"next instructions"* ]]'

arm true responder true
report_session c-on
plant c-on continue "Add the on-switch tests."
out="$(poll_session c-on)"
ok "continue with auto_continue on blocks with the reply" '[[ "$(printf "%s" "$out" | jq -r .decision)" == block && "$(printf "%s" "$out" | jq -r .reason)" == *"next instructions"* && "$(printf "%s" "$out" | jq -r .reason)" == *"Add the on-switch tests."* ]]'

arm false responder true
report_session s-off
plant s-off stop "Stop off."
out="$(poll_session s-off)"
ok "stop with auto_continue off ends and shows the body" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"says stop"* && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"Stop off."* ]]'

arm true responder true
report_session s-on
plant s-on stop "Stop on."
out="$(poll_session s-on)"
ok "stop with auto_continue on ends and shows the body" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"says stop"* && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"Stop on."* ]]'

arm false responder true
report_session w-off
plant w-off wait-for-owner "Needs a decision off."
out="$(poll_session w-off)"
ok "wait-for-owner with auto_continue off ends" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"owner has to decide"* && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"Needs a decision off."* ]]'

arm true responder true
report_session w-on
plant w-on wait-for-owner "Needs a decision on."
out="$(poll_session w-on)"
ok "wait-for-owner with auto_continue on ends" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"owner has to decide"* && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"Needs a decision on."* ]]'

arm true responder true
report_session stranger
plant stranger continue "PWN from a stranger." eve true eve
out="$(poll_session stranger)"
ok "non-allowlisted reply is ignored" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$out" != *PWN* && "$(cat "$T/err")" == *"not in reply_authors"* ]]'

arm true responder true
report_session unsigned
plant unsigned continue "PWN from an unsigned commit." responder false responder
out="$(poll_session unsigned)"
ok "unverified reply is ignored" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$out" != *PWN* && "$(cat "$T/err")" == *"not verified"* ]]'

arm true responder true
report_session signer
plant signer continue "PWN signed by someone else." responder true other
out="$(poll_session signer)"
ok "verified reply signed by someone else is ignored" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$out" != *PWN* && "$(cat "$T/err")" == *"committer"* ]]'

arm true responder false
report_session unsigned-ok
plant unsigned-ok continue "Unsigned but allowlisted." responder false responder
out="$(poll_session unsigned-ok)"
ok "require_verified false accepts an allowlisted unsigned continue" '[[ "$(printf "%s" "$out" | jq -r .decision)" == block && "$(printf "%s" "$out" | jq -r .reason)" == *"Unsigned but allowlisted."* ]]'

echo "background"
arm false responder true
inbox="$PC/nazgul/inbox/omp-show.md"
pf="$T/omp.json"
jq -nc --arg c "$P" '{session_id:"omp-show",cwd:$c,last_assistant_message:"omp did a thing"}' >"$pf"
NAZGUL_POLL_TRIES=4 NAZGUL_POLL_INTERVAL=1 bash "$S/check.sh" --agent omp --background --payload "$pf" --inbox "$inbox" >/dev/null 2>"$T/err" &
bg=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$PC/nazgul/sessions/omp-show.thread" ]] && break
  sleep 0.2
done
plant omp-show continue "Shown, not injected."
wait "$bg"
out="$(cat "$inbox" 2>/dev/null)"
ok "background continue is shown and not injected when auto_continue is off" '[[ "$(head -n 1 "$inbox")" == "nazgul-deliver: show" && "$out" == *"Shown, not injected."* && "$out" != *"next instructions"* ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
