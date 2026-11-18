#!/usr/bin/env bash
# nazgul tests: every script against a fake gh that keeps the report repo in a temp folder.
# Usage: bash tests/run.sh      (no network, no real GitHub, no change outside a temp folder)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skill_src="$(dirname "$here")"
T="$(mktemp -d "${TMPDIR:-/tmp}/nazgul-test.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT
cd "$T" || exit 1

export PATH="$here/bin:$PATH"
export HOME="$T/home"; mkdir -p "$HOME"
export FAKE_GH_ROOT="$T/remote" FAKE_GH_LOG="$T/gh.log"
export NAZGUL_POLL_INTERVAL=1 NAZGUL_POLL_TRIES=2
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset XDG_CONFIG_HOME NAZGUL_REPO NAZGUL_CONFIG NAZGUL_OFF NAZGUL_SESSION NAZGUL_AGENT CLAUDECODE \
  CODEX_THREAD_ID CODEX_SESSION_ID GROK_HOOK_EVENT GROK_SESSION_ID GROK_WORKSPACE_ROOT CURSOR_AGENT
mkdir -p "$FAKE_GH_ROOT/owner/reports"

pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); printf '  ok    %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; fi; }

# The skill lives outside every repo, as a user-level skill.
SK="$HOME/.agents/skills/nazgul"
mkdir -p "$(dirname "$SK")" && cp -R "$skill_src" "$SK" && rm -rf "$SK/tests"
S="$(cd "$SK/scripts" && pwd -P)"
CFG="$HOME/.config/nazgul/config"
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.grok"     # tools "installed"; Oh My Pi is not

# A plain project repo with a committed .gitignore.
P="$T/work/widget"
git -C "$T" init -q -b main work/widget
printf 'hello\n' >"$P/README.md"; printf 'node_modules/\n' >"$P/.gitignore"
git -C "$P" add -A && git -C "$P" commit -qm init
git -C "$P" remote add origin https://github.com/owner/widget.git
git -C "$P" update-ref refs/remotes/origin/main HEAD
git -C "$P" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
PC="$(cd "$P/.git" && pwd -P)"
THREADS="$FAKE_GH_ROOT/owner/reports/projects/widget/threads"

pl() { # session active message [cwd]
  jq -nc --arg s "$1" --argjson a "${2:-false}" --arg m "${3:-Done.}" --arg c "${4:-$P}" \
    '{hook_event_name:"Stop",session_id:$s,cwd:$c,stop_hook_active:$a,last_assistant_message:$m}'
}
check() { bash "$S/check.sh" "$@" 2>"$T/err"; }
body() {
  printf '## Changed\nAdded a widget.\n\n## Why\nThe owner asked.\n\n## Where\n- https://github.com/owner/widget/tree/feat/x\n\n## Left\nnothing\n\n## Needs owner\nnothing\n'
}
reply() { # thread number action text [in_reply_to] [threads dir]
  printf -- '---\nfrom: owner-bot\nin_reply_to: %s\naction: %s\n---\n\n%s\n' "${5:-$(( $2 - 1 ))}" "$3" "$4" \
    >"${6:-$THREADS}/$1/$(printf '%03d' "$2")_owner-bot.md"
}
tid_of() { head -n 1 "${2:-$PC}/nazgul/sessions/$1.thread"; }
cfg() { (. "$S/lib.sh"; nz_cfg_edit "$@"); }
# snap <dir>: every path and file hash under dir, minus files git rewrites on its own (index, logs).
snap() {
  (cd "$1" && find . \( -name index -o -name logs \) -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
    if [[ -f "$p" ]]; then printf '%s %s\n' "$(shasum <"$p" | cut -c1-40)" "$p"; else printf 'dir %s\n' "$p"; fi
  done)
}
clean() { [[ -z "$(git -C "$1" status --porcelain --ignored)" && -z "$(git -C "$1" diff)" ]]; }

echo "no config"
out="$(pl s0 | check --agent claude)"; rc=$?
ok "check.sh prints nothing and exits 0" '[[ $rc -eq 0 && -z "$out" && ! -s "$T/err" ]]'
out="$(cd "$P" && body | bash "$S/report.sh" --agent claude 2>&1)"; rc=$?
ok "report.sh is silent" '[[ $rc -eq 0 && -z "$out" ]]'
out="$(cd "$P" && bash "$S/poll.sh" --now 2>&1)"; rc=$?
ok "poll.sh is silent" '[[ $rc -eq 0 && -z "$out" ]]'
ok "no call reached gh" '[[ ! -s "$FAKE_GH_LOG" ]]'

echo "config.sh"
out="$(cd "$P" && bash "$S/config.sh" --repo owner/reports --skip-paths "$T/skipme" </dev/null 2>&1)"; rc=$?
ok "writes user config" '[[ $rc -eq 0 && "$(grep ^repo= "$CFG")" == repo=owner/reports ]]'
ok "user config is mode 600" '[[ "$(ls -l "$CFG" | cut -c1-10)" == -rw------- ]]'
ok "reports push access" '[[ "$out" == *"you can push"* ]]'
ok "says the repo is not enrolled yet" '[[ "$out" == *"not enrolled"*"install.sh\" --enroll"* ]]'
ok "writes nothing in the repo" 'clean "$P" && [[ ! -e "$P/.nazgul" ]]'
out="$(cd "$P" && bash "$S/config.sh" </dev/null 2>&1)"; rc=$?
ok "keeps the repo without a terminal" '[[ $rc -eq 0 && "$(grep ^repo= "$CFG")" == repo=owner/reports ]]'
out="$(cd "$P" && bash "$S/config.sh" --repo 'not a repo' </dev/null 2>&1)"; rc=$?
ok "rejects a bad repo name" '[[ $rc -eq 2 ]]'

echo "configured but not enrolled"
: >"$FAKE_GH_LOG"
out="$(pl s0 | check --agent claude)"; rc=$?
ok "check.sh prints nothing" '[[ $rc -eq 0 && -z "$out" && ! -s "$T/err" ]]'
out="$(cd "$P" && body | bash "$S/report.sh" --agent claude 2>&1)"
ok "report.sh is silent" '[[ -z "$out" ]]'
ok "no call reached gh" '[[ ! -s "$FAKE_GH_LOG" ]]'

echo "install.sh --enroll"
printf '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}\n' \
  >"$HOME/.claude/settings.json"
gi_before="$(shasum <"$P/.gitignore")"; ex_before="$(shasum <"$P/.git/info/exclude")"
out="$(cd "$P" && bash "$S/install.sh" --enroll </dev/null 2>"$T/ierr")"; rc=$?
ok "exits 0 with nothing on stderr" '[[ $rc -eq 0 && ! -s "$T/ierr" ]]'
ok "adds a [project] section keyed by the git common dir" 'grep -qxF "[project \"$PC\"]" "$CFG"'
ok "slug defaults to the repo name and is not written" '[[ "$out" == *"project    widget"* ]] && ! grep -q "^slug=" "$CFG"'
ok "git status and git diff stay empty" 'clean "$P"'
ok ".gitignore and info/exclude unchanged" '[[ "$(shasum <"$P/.gitignore")" == "$gi_before" && "$(shasum <"$P/.git/info/exclude")" == "$ex_before" ]]'
ok "keeps other Claude settings" '[[ "$(jq -r ".permissions.allow[0]" "$HOME/.claude/settings.json")" == "Bash(ls)" ]]'
ok "keeps the other Stop hook and adds one with an absolute path" '[[ "$(jq -r "[.hooks.Stop[].hooks[].command] | join(\"|\")" "$HOME/.claude/settings.json")" == "echo other|[ ! -f \"$S/check.sh\" ] || bash \"$S/check.sh\" --agent claude" ]]'
ok "Claude timeout 660" '[[ "$(jq -r ".hooks.Stop[1].hooks[0].timeout" "$HOME/.claude/settings.json")" == 660 ]]'
ok "Codex ~/.codex/hooks.json" '[[ "$(jq -r ".hooks.Stop[0].hooks[0].timeout" "$HOME/.codex/hooks.json")" == 660 ]]'
ok "Grok ~/.grok/hooks/nazgul.json" '[[ "$(jq -r ".hooks.Stop[0].hooks[0].timeout" "$HOME/.grok/hooks/nazgul.json")" == 660 ]]'
ok "Oh My Pi skipped: no ~/.omp" '[[ ! -e "$HOME/.omp" && "$out" == *"skipped    omp"* ]]'
ok "commit-msg backstop in the git common dir" '[[ -x "$PC/hooks/commit-msg" ]] && grep -q "nazgul backstop" "$PC/hooks/commit-msg"'
ok "prints the Codex /hooks step" '[[ "$out" == *"/hooks and"*"press t"* ]]'
ok "prints the Grok trust step" '[[ "$out" == *"/hooks-trust"* ]]'
out="$(cd "$P" && bash "$S/install.sh" --only omp </dev/null 2>&1)"
ok "--only omp writes ~/.omp/agent/hooks/post/nazgul.ts" 'grep -qF "const SCRIPTS = \"$S\"" "$HOME/.omp/agent/hooks/post/nazgul.ts"'
ok "no placeholder left" '! grep -rq "__NAZGUL_" "$HOME/.claude" "$HOME/.codex" "$HOME/.grok" "$HOME/.omp" "$PC/hooks/commit-msg"'
out="$(cd "$P" && bash "$S/install.sh" </dev/null 2>&1)"
ok "second run changes nothing" '[[ "$out" != *created* && "$out" != *merged* && "$out" != *updated* && "$out" != *added* ]]'
ok "second run adds no duplicate" '[[ "$(jq "[.hooks.Stop[]] | length" "$HOME/.claude/settings.json")" == 2 ]]'
hookcmd="$(jq -r '.hooks.Stop[1].hooks[0].command' "$HOME/.claude/settings.json")"
mkdir -p "$P/sub"
out="$(cd "$P/sub" && pl s0 false Done. "$P/sub" | sh -c "$hookcmd")"; rc=$?
ok "the hook command works from a subfolder" '[[ $rc -eq 0 && "$out" == *"\"decision\": \"block\""* ]]'
rmdir "$P/sub"; rm -f "$PC/nazgul/sessions/s0".*
out="$(cd "$P" && pl s0 | sh -c "${hookcmd//$S//nowhere/scripts}" 2>&1)"; rc=$?
ok "the hook command is a no-op when the skill folder is gone" '[[ $rc -eq 0 && -z "$out" ]]'
mkdir -p "$T/work/other" && git -C "$T/work/other" init -q
out="$(pl s0 false Done. "$T/work/other" | sh -c "$hookcmd")"; rc=$?
ok "the user-level hook does nothing in a repo that is not enrolled" '[[ $rc -eq 0 && -z "$out" ]]'
mkdir -p "$T/work/inside" && git -C "$T/work/inside" init -q && cp -R "$SK" "$T/work/inside/nazgul"
out="$(bash "$T/work/inside/nazgul/scripts/install.sh" --cwd "$T/work/inside" 2>&1)"; rc=$?
ok "refuses a skill that sits inside the repo" '[[ $rc -eq 1 && "$out" == *"inside a work tree"* ]]'
rm -rf "$T/work/inside"

echo "skip path and NAZGUL_OFF"
mkdir -p "$T/skipme/proj" && git -C "$T/skipme/proj" init -q
bash "$S/install.sh" --enroll --only git --cwd "$T/skipme/proj" >/dev/null 2>&1
out="$(pl s9 false Done. "$T/skipme/proj" | check --agent claude)"; rc=$?
ok "nothing inside a skip path, even when enrolled" '[[ $rc -eq 0 && -z "$out" && ! -s "$T/err" ]]'
out="$(pl s9 | NAZGUL_OFF=1 check --agent claude)"
ok "nothing with NAZGUL_OFF=1" '[[ -z "$out" ]]'

echo "Claude: ask, report, no reply"
git -C "$P" checkout -qb feat/x
printf 'x\n' >"$P/x.txt" && git -C "$P" add x.txt && git -C "$P" commit -qm "add x"
out="$(pl sess-1 | check --agent claude)"
ok "first Stop blocks and asks for a report" '[[ "$(printf "%s" "$out" | jq -r .decision)" == block ]]'
reason="$(printf '%s' "$out" | jq -r .reason)"
ok "the ask carries this session id" '[[ "$reason" == *"--session sess-1"* ]]'
ok "the ask carries the branch link" '[[ "$reason" == *"https://github.com/owner/widget/tree/feat/x"* ]]'
cmd="$(printf '%s\n' "$reason" | awk '/^bash "/{on=1} on{print}')"
cmd="${cmd//<one line: what this session did>/Added x}"
out="$(cd "$P" && bash -c "$cmd" 2>&1)"; rc=$?
ok "the agent runs the command from the ask" '[[ $rc -eq 0 && "$out" == *"pushed projects/widget/threads/"*"/001_claude.md"* ]]'
tid="$(tid_of sess-1)"
ok "thread id is date_time_agent_branch" '[[ "$tid" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}_claude_feat-x$ ]]'
f="$THREADS/$tid/001_claude.md"
ok "001 frontmatter" '[[ "$(sed -n 2,7p "$f" | cut -d: -f1 | tr "\n" " ")" == "project agent repo branch date thread " ]]'
ok "001 repo is the project origin" 'grep -q "^repo: owner/widget$" "$f"'
ok "commit message" 'grep -q "001_claude.md	nazgul(widget): Added x" "$FAKE_GH_ROOT/commits.log"'
start=$(date +%s)
out="$(pl sess-1 true | check --agent claude)"
ok "second Stop polls, then ends with a note" '[[ "$(printf "%s" "$out" | jq -r .systemMessage)" == *"no reply after 2 checks"* ]]'
ok "polling waited tries x interval" '[[ $(( $(date +%s) - start )) -ge 2 ]]'

echo "Claude: continue, then stop"
reply "$tid" 2 continue "Now add tests for x."
out="$(pl sess-1 | check --agent claude)"
ok "a new turn asks for a report again" '[[ "$(printf "%s" "$out" | jq -r .reason)" == *"report.sh"* ]]'
out="$(cd "$P" && body | bash "$S/report.sh" --agent claude --session sess-1 --summary "second" 2>&1)"
ok "report goes after the reply, as 003" '[[ -f "$THREADS/$tid/003_claude.md" ]]'
reply "$tid" 4 continue "Now add tests for x."
out="$(pl sess-1 true | check --agent claude)"
ok "continue blocks with the reply body" '[[ "$(printf "%s" "$out" | jq -r .decision)" == block && "$(printf "%s" "$out" | jq -r .reason)" == *"Now add tests for x."* ]]'
ok "continue names round 1" '[[ "$out" == *"round 1 of 3"* ]]'
out="$(pl sess-1 true | check --agent claude)"
ok "after the continue round it asks for the next report" '[[ "$(printf "%s" "$out" | jq -r .reason)" == *"report.sh"* ]]'
(cd "$P" && body | bash "$S/report.sh" --agent claude --session sess-1 --summary third >/dev/null 2>&1)
reply "$tid" 6 stop "Good. Stop here."
out="$(pl sess-1 true | check --agent claude)"
ok "stop ends the session with the body shown" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$(printf "%s" "$out" | jq -r .systemMessage)" == *"says stop"*"Stop here."* ]]'

echo "replies that do not count"
out="$(pl sess-2 | check --agent claude)"
(cd "$P" && body | bash "$S/report.sh" --agent claude --session sess-2 --summary s2 >/dev/null 2>&1)
tid2="$(tid_of sess-2)"
ok "a second session in the same minute gets its own thread" '[[ "$tid2" == "$tid-2" ]]'
n2="$(head -n 1 "$PC/nazgul/sessions/sess-2.last")"
reply "$tid2" $((n2 + 1)) continue "stale" 999
mkdir -p "$THREADS/other-thread" && printf -- '---\naction: continue\n---\nwrong thread\n' >"$THREADS/other-thread/099_x.md"
printf -- '---\naction: continue\n---\nwrong project\n' >"$FAKE_GH_ROOT/owner/reports/forum-reply.md"
out="$(pl sess-2 true | check --agent claude)"
ok "ignores a reply to another message and other folders" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" ]]'
reply "$tid2" $((n2 + 2)) wait-for-owner "Needs a pricing call."
out="$(pl sess-2 | check --agent claude)"
(cd "$P" && body | bash "$S/report.sh" --agent claude --session sess-2 --summary s2b >/dev/null 2>&1)
n2="$(head -n 1 "$PC/nazgul/sessions/sess-2.last")"
reply "$tid2" $((n2 + 1)) wait-for-owner "Needs a pricing call."
out="$(pl sess-2 true | check --agent claude)"
ok "wait-for-owner ends and says the owner decides" '[[ "$(printf "%s" "$out" | jq -r .systemMessage)" == *"owner has to decide"*"pricing call"* ]]'

echo "agent ignores the ask: nazgul builds the report"
printf 'dirty\n' >"$P/dirty.txt"
out="$(pl sess-3 false $'Finished the parser.\n\nAll green.' | check --agent claude)"
out="$(pl sess-3 true $'Finished the parser.\n\nAll green.' | check --agent claude)"
tid3="$(tid_of sess-3)"; f="$THREADS/$tid3/001_claude.md"
ok "built report pushed" '[[ -f "$f" ]]'
ok "built report has all sections" '[[ "$(grep -c "^## \(Changed\|Why\|Where\|Left\|Needs owner\)$" "$f")" == 5 ]]'
ok "built report lists the branch commit" 'grep -q "add x" "$f" && grep -q "https://github.com/owner/widget/commit/" "$f"'
ok "built report lists uncommitted paths" 'grep -q "dirty.txt" "$f"'
ok "built report quotes the last message" 'grep -q "^> Finished the parser." "$f"'
ok "built report summary from the last message" 'grep -q "nazgul(widget): Finished the parser." "$FAKE_GH_ROOT/commits.log"'
rm -f "$P/dirty.txt"

echo "loop guard and round cap"
out="$(pl sess-4 true | check --agent claude)"
ok "stop_hook_active from another hook: silent" '[[ -z "$out" ]]'
cfg set "$PC" max_rounds 1
out="$(pl sess-5 | check --agent claude)"
(cd "$P" && body | bash "$S/report.sh" --agent claude --session sess-5 --summary r >/dev/null 2>&1)
tid5="$(tid_of sess-5)"; reply "$tid5" 2 continue "once"
out="$(pl sess-5 true | check --agent claude)"
ok "round 1 of 1 continues" '[[ "$out" == *"round 1 of 1"* ]]'
out="$(pl sess-5 true | check --agent claude)"
(cd "$P" && body | bash "$S/report.sh" --agent claude --session sess-5 --summary r2 >/dev/null 2>&1)
reply "$tid5" 4 continue "twice"
out="$(pl sess-5 true | check --agent claude)"
ok "cap reached: no block, a note instead" '[[ "$(printf "%s" "$out" | jq -r ".decision // empty")" == "" && "$out" == *"continue rounds"* ]]'
cfg unset "$PC" max_rounds

echo "report.sh input checks"
out="$(cd "$P" && printf '## Changed\nx\n## Why\ny\n' | bash "$S/report.sh" --agent codex --session v1 2>&1)"; rc=$?
ok "missing sections: exit 2 and a list" '[[ $rc -eq 2 && "$out" == *"## Where (missing)"* && "$out" == *"## Needs owner (missing)"* ]]'
out="$(cd "$P" && printf '## Changed\n\n## Why\ny\n## Where\nz\n## Left\nnothing\n## Needs owner\nnothing\n' | bash "$S/report.sh" --agent codex --session v1 2>&1)"; rc=$?
ok "empty section: exit 2" '[[ $rc -eq 2 && "$out" == *"## Changed (empty"* ]]'
for secret in "ghp_$(printf 'a%.0s' {1..36})" "AKIA$(printf 'B%.0s' {1..16})" "api_key = 0123456789abcdef0123" "-----BEGIN RSA PRIVATE KEY-----" "https://bob:hunter2@example.com/x"; do
  out="$(cd "$P" && body | sed "s|Added a widget.|Added a widget. $secret|" | bash "$S/report.sh" --agent codex --session v2 2>&1)"; rc=$?
  ok "secret refused: ${secret:0:12}..." '[[ $rc -eq 3 && "$out" == *"refusing to push"* && "$out" != *"$secret"* ]]'
done
ok "nothing pushed for refused reports" '[[ ! -f "$PC/nazgul/sessions/v2.thread" ]]'

echo "network failure fails open"
out="$(pl sess-6 | FAKE_GH_FAIL=1 check --agent claude)"
out="$(pl sess-6 true | FAKE_GH_FAIL=1 check --agent claude)"; rc=$?
ok "exit 0 with a warning and a note" '[[ $rc -eq 0 && "$(cat "$T/err")" == *"could not read the report repo"* && "$out" == *"no report was pushed"* ]]'
out="$(cd "$P" && body | FAKE_GH_FAIL=1 bash "$S/report.sh" --agent claude --session sess-6 2>&1)"; rc=$?
ok "report.sh exit 0 with a warning" '[[ $rc -eq 0 && "$out" == *"report not pushed"* ]]'

echo "Codex"
out="$(jq -nc --arg c "$P" '{session_id:"cx-1",turn_id:"t1",cwd:$c,hook_event_name:"Stop",model:"m",permission_mode:"default",stop_hook_active:false,last_assistant_message:"ok",transcript_path:null}' | check --agent codex)"
ok "Codex Stop asks with --agent codex" '[[ "$(printf "%s" "$out" | jq -r .reason)" == *"--agent codex --session cx-1"* ]]'
ok "Codex output holds only allowed keys" '[[ "$(printf "%s" "$out" | jq -c "keys")" == "[\"decision\",\"reason\"]" ]]'

echo "Grok"
gp() { jq -nc --arg c "$P" --arg r "$1" --argjson a "$2" '{hookEventName:"stop",hook_event_name:"Stop",sessionId:"gk-1",cwd:$c,workspaceRoot:$c,reason:$r,stopHookActive:$a,lastAssistantMessage:"grok done"}'; }
out="$(gp channel_closed false | check --agent grok)"
ok "session-close Stop is ignored" '[[ -z "$out" ]]'
out="$(gp end_turn false | check --agent grok)"
ok "camelCase payload: asks for the report" '[[ "$(printf "%s" "$out" | jq -r .reason)" == *"--agent grok --session gk-1"* ]]'
out="$(gp end_turn true | check --agent grok)"
ok "agent ignored the ask: built report pushed" '[[ -f "$THREADS/$(tid_of gk-1)/001_grok.md" ]]'
out="$(pl sess-7 | GROK_HOOK_EVENT=stop check --agent claude)"
ok "Claude hook run by Grok does nothing" '[[ -z "$out" ]]'

echo "Oh My Pi background"
inbox="$PC/nazgul/inbox/omp-1.md"
pf="$T/payload.json"; jq -nc --arg c "$P" '{session_id:"omp-1",cwd:$c,last_assistant_message:"omp did a thing"}' >"$pf"
out="$(bash "$S/check.sh" --agent omp --background --payload "$pf" --inbox "$inbox" 2>"$T/err")"
tid8="$(tid_of omp-1)"
ok "built report pushed, nothing on stdout" '[[ -z "$out" && -f "$THREADS/$tid8/001_omp.md" ]]'
ok "payload file removed" '[[ ! -f "$pf" ]]'
ok "no inbox without a reply" '[[ ! -f "$inbox" ]]'
jq -nc --arg c "$P" '{session_id:"omp-1",cwd:$c,last_assistant_message:"omp again"}' >"$pf"
bash "$S/check.sh" --agent omp --background --payload "$pf" --inbox "$inbox" >/dev/null 2>&1 &
bg=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$THREADS/$tid8/002_omp.md" ]] && break; sleep 0.2; done
reply "$tid8" 3 continue "Do the next thing."
wait $bg
ok "a reply that lands while polling goes to the inbox" '[[ -f "$inbox" ]] && grep -q "Do the next thing." "$inbox"'
ok "the inbox names the round" 'grep -q "round 1 of 3" "$inbox"'
jq -nc --arg c "$P" '{session_id:"omp-1",cwd:$c,last_assistant_message:"x"}' >"$pf"
NAZGUL_POLL_INTERVAL=3 bash "$S/check.sh" --agent omp --background --payload "$pf" --inbox "$T/old-inbox" >/dev/null 2>&1 &
old=$!
sleep 1
jq -nc --arg c "$P" '{session_id:"omp-1",cwd:$c,last_assistant_message:"y"}' >"$pf"
bash "$S/check.sh" --agent omp --background --payload "$pf" --inbox "$T/new-inbox" >/dev/null 2>&1 &
new=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$THREADS/$tid8/005_omp.md" ]] && break; sleep 0.2; done
reply "$tid8" 6 stop "Enough."
wait $old $new
ok "a newer background run takes over from an older one" '[[ ! -f "$T/old-inbox" && -f "$T/new-inbox" ]]'

echo "commit-msg backstop"
git -C "$P" checkout -qb feat/new-thing
printf 'y\n' >"$P/y.txt" && git -C "$P" add y.txt
out="$(cd "$P" && CLAUDECODE=1 git commit -qm "add y" 2>&1)"; rc=$?
ok "agent commit on an unreported branch warns" '[[ $rc -eq 0 && "$out" == *"has no session report yet"* ]]'
printf 'z\n' >"$P/z.txt" && git -C "$P" add z.txt
out="$(cd "$P" && git commit -qm "add z" 2>&1)"
ok "human commit: no warning" '[[ -z "$out" ]]'
git -C "$P" checkout -q feat/x
printf 'w\n' >"$P/w.txt" && git -C "$P" add w.txt
out="$(cd "$P" && CLAUDECODE=1 git commit -qm "add w" 2>&1)"
ok "agent commit on a reported branch: no warning" '[[ -z "$out" ]]'

echo "bare repo with worktrees"
B="$T/bare"; mkdir -p "$B"
git clone -q --bare "$P" "$B/gadget.git"
git -C "$B/gadget.git" remote set-url origin https://github.com/owner/gadget.git
git -C "$B/gadget.git" worktree add -q "$B/main" main 2>/dev/null
BC="$(cd "$B/gadget.git" && pwd -P)"
OT="$FAKE_GH_ROOT/owner/reports/projects/gadget/threads"
snap "$B" >"$T/bare.before"
out="$(cd "$B/main" && bash "$S/install.sh" --enroll </dev/null 2>&1)"; rc=$?
ok "enroll from a worktree: the section is the bare repo" '[[ $rc -eq 0 ]] && grep -qxF "[project \"$BC\"]" "$CFG"'
ok "slug defaults to the bare repo name without .git" '[[ "$out" == *"project    gadget"* ]]'
ok "backstop in the bare repo hooks folder" 'grep -q "nazgul backstop" "$BC/hooks/commit-msg"'
ok "worktree: git status and git diff empty, .gitignore unchanged" 'clean "$B/main" && [[ "$(cat "$B/main/.gitignore")" == "node_modules/" ]]'
out="$(pl bw-1 false Done. "$B/main" | check --agent claude)"
cmd="$(printf '%s' "$out" | jq -r .reason | awk '/^bash "/{on=1} on{print}')"
out="$(cd "$B/main" && bash -c "${cmd//<one line: what this session did>/gadget work}" 2>&1)"
ok "a session in the worktree reports under projects/gadget" '[[ "$out" == *"pushed projects/gadget/threads/"*"_claude_main/001_claude.md"* ]]'
ok "session state sits in the bare repo, the worktree stays clean" '[[ -f "$BC/nazgul/sessions/bw-1.thread" ]] && clean "$B/main"'
out="$(cd "$B/main" && bash "$S/install.sh" --unenroll 2>&1)"; rc=$?
ok "unenroll exits 0 and drops the section" '[[ $rc -eq 0 ]] && ! grep -qF "$BC" "$CFG"'
ok "unenroll keeps the user-level hooks while other repos are enrolled" '[[ -f "$HOME/.grok/hooks/nazgul.json" ]]'
snap "$B" >"$T/bare.after"
ok "unenroll leaves the repo byte-for-byte as before" 'diff "$T/bare.before" "$T/bare.after" >/dev/null'
out="$(cd "$B/gadget.git" && bash "$S/install.sh" --enroll --slug "Gadget App" </dev/null 2>&1)"; rc=$?
ok "enroll from inside the bare repo itself, with a slug" '[[ $rc -eq 0 && "$(sed -n "/$(printf %s "$BC" | sed "s|/|\\\\/|g")/,\$p" "$CFG" | grep ^slug=)" == slug=Gadget-App ]]'
git -C "$B/gadget.git" worktree add -q -b feat/y "$B/feat-y" main 2>/dev/null
out="$(pl bw-2 false Done. "$B/feat-y" | check --agent claude)"
ok "a fresh worktree is covered with no setup: the Stop hook asks" '[[ "$(printf "%s" "$out" | jq -r .reason)" == *"--session bw-2"* ]]'
cmd="$(printf '%s' "$out" | jq -r .reason | awk '/^bash "/{on=1} on{print}')"
out="$(cd "$B/feat-y" && bash -c "${cmd//<one line: what this session did>/feature y}" 2>&1)"
ok "the fresh worktree reports under the slug, on its branch" '[[ "$out" == *"pushed projects/Gadget-App/threads/"*"_claude_feat-y/001_claude.md"* ]]'
ok "the fresh worktree stays clean" 'clean "$B/feat-y"'
printf 'q\n' >"$B/feat-y/q.txt" && git -C "$B/feat-y" add q.txt
out="$(cd "$B/feat-y" && CLAUDECODE=1 git commit -qm "add q" 2>&1)"
ok "the backstop runs in every worktree (reported branch: quiet)" '[[ -z "$out" ]]'

echo "core.hooksPath and other commit-msg hooks"
H="$T/work/husky"; git -C "$T/work" init -q husky; git -C "$H" config core.hooksPath .husky
out="$(bash "$S/install.sh" --enroll --cwd "$H" </dev/null 2>&1)"
ok "core.hooksPath set: backstop skipped and said so" '[[ "$out" == *"core.hooksPath is set (.husky)"* && ! -e "$H/.husky" && ! -e "$H/.git/hooks/commit-msg" ]]'
ok "core.hooksPath repo stays clean" 'clean "$H"'
F="$T/work/foreign"; git -C "$T/work" init -q foreign
printf '#!/bin/sh\necho mine\n' >"$F/.git/hooks/commit-msg"; chmod 755 "$F/.git/hooks/commit-msg"
out="$(bash "$S/install.sh" --enroll --cwd "$F" </dev/null 2>&1)"
ok "another commit-msg hook: skipped and left alone" '[[ "$out" == *"another commit-msg hook"* && "$(cat "$F/.git/hooks/commit-msg")" == *"echo mine"* ]]'
bash "$S/install.sh" --unenroll --cwd "$F" >/dev/null 2>&1
ok "unenroll leaves the other commit-msg hook" '[[ "$(cat "$F/.git/hooks/commit-msg")" == *"echo mine"* ]]'

echo "only adds files"
ok "every PUT created a new path" '[[ "$(cut -f1 "$FAKE_GH_ROOT/commits.log" | sort | uniq -d | wc -l | tr -d " ")" == 0 ]]'
ok "every write is under projects/<slug>/threads" '[[ -z "$(cut -f1 "$FAKE_GH_ROOT/commits.log" | grep -vE "^projects/(widget|gadget|Gadget-App)/threads/")" ]]'
ok "no PUT sent a sha" '! grep -q "fake gh: sha sent" "$T/err"'

echo "unenroll the last repo"
for r in "$P" "$T/skipme/proj" "$B/main" "$H"; do bash "$S/install.sh" --unenroll --cwd "$r" >"$T/unenroll.out" 2>&1; done
ok "no [project] section left" '! grep -q "^\[project" "$CFG" && grep -q "^repo=owner/reports" "$CFG"'
ok "says the user-level hooks go" 'grep -q "user-level hooks go too" "$T/unenroll.out"'
ok "Claude settings keep everything but nazgul" '[[ "$(jq -c . "$HOME/.claude/settings.json")" == "{\"permissions\":{\"allow\":[\"Bash(ls)\"]},\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo other\"}]}]}}" ]]'
ok "Codex, Grok and Oh My Pi hook files removed" '[[ ! -e "$HOME/.codex/hooks.json" && ! -e "$HOME/.grok/hooks/nazgul.json" && ! -e "$HOME/.omp/agent/hooks/post/nazgul.ts" ]]'
ok "backstop and state removed from the plain repo" '[[ ! -e "$PC/hooks/commit-msg" && ! -e "$PC/nazgul" ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
