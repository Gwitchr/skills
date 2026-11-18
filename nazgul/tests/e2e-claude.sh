#!/usr/bin/env bash
# nazgul end-to-end with a real headless Claude Code session and the fake gh.
# Usage: bash tests/e2e-claude.sh [model]      (default model: haiku; spends a few cents of tokens)
# Checks: the Stop hook asks for a report and Claude pushes 001; a continue reply (002) makes Claude
# resume and do what it says; the next report is 003; a stop reply (004) ends the session.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skill_src="$(dirname "$here")"
model="${1:-haiku}"
T="$(mktemp -d "${TMPDIR:-/tmp}/nazgul-e2e.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT
cd "$T" || exit 1
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found"; exit 1; }

export PATH="$here/bin:$PATH" FAKE_GH_ROOT="$T/remote" NAZGUL_CONFIG="$T/config"
export NAZGUL_POLL_INTERVAL=3 NAZGUL_POLL_TRIES=10
mkdir -p "$FAKE_GH_ROOT/owner/reports"
printf 'repo=owner/reports\n' >"$NAZGUL_CONFIG"

P="$T/widget"
git init -q -b main "$P"
mkdir -p "$P/.agents/skills"
cp -R "$skill_src" "$P/.agents/skills/nazgul"; rm -rf "$P/.agents/skills/nazgul/tests"
printf 'widget\n' >"$P/README.md"
git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@example.invalid commit -qm init
git -C "$P" remote add origin https://github.com/owner/widget.git
bash "$P/.agents/skills/nazgul/scripts/install.sh" --project-dir "$P" --only claude >/dev/null
THREADS="$FAKE_GH_ROOT/owner/reports/projects/widget/threads"

# The responder: continue after 001, stop after 003.
(
  for _ in $(seq 1 200); do f="$(ls "$THREADS"/*/001_claude.md 2>/dev/null | head -n 1)"; [[ -n "$f" ]] && break; sleep 1; done
  [[ -n "${f:-}" ]] || exit 0
  d="$(dirname "$f")"
  printf -- '---\nfrom: tester\nin_reply_to: 1\naction: continue\n---\n\nCreate a file named continued.txt whose only content is the word ok. Do not commit it. Then end your turn.\n' >"$d/002_tester.md"
  for _ in $(seq 1 200); do [[ -f "$d/003_claude.md" ]] && break; sleep 1; done
  printf -- '---\nfrom: tester\nin_reply_to: 3\naction: stop\n---\n\nThanks, that is all.\n' >"$d/004_tester.md"
) &
responder=$!

start=$(date +%s)
(cd "$P" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p \
  "Create a file hello.txt containing hi and commit it with the message 'add hello'. Then end your turn." \
  --model "$model" --setting-sources project --permission-mode acceptEdits \
  --allowedTools "Bash,Write,Read,Edit" --output-format json >"$T/out.json" 2>"$T/err.txt")
rc=$?
kill "$responder" 2>/dev/null; wait "$responder" 2>/dev/null
echo "claude exit $rc after $(( $(date +%s) - start ))s"

d="$(dirname "$(ls "$THREADS"/*/001_claude.md 2>/dev/null | head -n 1)")"
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); printf '  ok    %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; fi; }
ok "001 pushed by Claude" '[[ -f "$d/001_claude.md" ]]'
ok "001 was written by the agent, not built" '! grep -q "did not write this report" "$d/001_claude.md"'
ok "Claude resumed with the reply: continued.txt exists" '[[ "$(tr -d "[:space:]" <"$P/continued.txt" 2>/dev/null)" == ok ]]'
ok "003 pushed after the continue round" '[[ -f "$d/003_claude.md" ]]'
ok "nothing after the stop reply" '[[ ! -f "$d/005_claude.md" ]]'
ok "hello.txt committed" 'git -C "$P" log --format=%s | grep -q "add hello"'
echo "--- 001"; cat "$d/001_claude.md" 2>/dev/null
echo "--- 003"; cat "$d/003_claude.md" 2>/dev/null
echo "--- result"; jq -r '.result // .' "$T/out.json" 2>/dev/null | head -n 20
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
