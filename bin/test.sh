#!/usr/bin/env bash
#
# test.sh — fixture-based tests for is-readonly.sh
#
# Each test: a command string and an expected decision (allow|prompt).
# "allow" means the classifier outputs an allow JSON decision.
# "prompt" means the classifier outputs nothing (falls through).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFIER="$SCRIPT_DIR/is-readonly.sh"

PASS=0
FAIL=0
FAILED_CASES=()

run_case() {
  local expected="$1"
  local cmd="$2"

  local input
  input=$(jq -cn --arg c "$cmd" '{tool_input: {command: $c}}')
  local output
  output=$(printf '%s' "$input" | "$CLASSIFIER" 2>/dev/null || true)

  local actual
  if [[ -n "$output" ]] && echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1; then
    actual="allow"
  else
    actual="prompt"
  fi

  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$expected (got $actual): $cmd")
  fi
}

# ── Simple read-only ───────────────────────────────────────────────
run_case allow  'ls'
run_case allow  'ls -la'
run_case allow  'pwd'
run_case allow  'cat file.txt'
run_case allow  'grep -r foo .'
run_case allow  'echo hello'
run_case allow  'find . -name "*.md"'
run_case allow  'jq . data.json'

# ── Dangerous bases ────────────────────────────────────────────────
run_case prompt 'rm file'
run_case prompt 'rm -rf /tmp/foo'
run_case prompt 'mv a b'
run_case prompt 'cp a b'
run_case prompt 'mkdir foo'
run_case prompt 'touch newfile'
run_case prompt 'chmod +x script.sh'
run_case prompt 'sudo ls'
run_case prompt 'kill 1234'

# ── Pipe chains ────────────────────────────────────────────────────
run_case allow  'ls | grep foo'
run_case allow  'git log --oneline | head -10'
run_case allow  'cat file | grep pattern | wc -l'
run_case prompt 'ls | rm -rf /tmp/foo'
run_case prompt 'echo hi | tee output.txt'

# ── Chained with && / || / ; ──────────────────────────────────────
run_case allow  'ls && pwd'
run_case allow  'ls || echo fail'
run_case allow  'ls; pwd; echo done'
run_case prompt 'ls && rm file'
run_case prompt 'pwd; mkdir x'

# ── Redirections ───────────────────────────────────────────────────
run_case prompt 'echo data > file.txt'
run_case prompt 'echo data >> file.txt'
run_case allow  'echo data > /dev/null'
run_case prompt 'some_cmd 2>/dev/null' # unknown base → prompt
run_case allow  'ls 2>/dev/null'        # known base, redirect to /dev/null
run_case prompt 'echo data 2> /tmp/err'
run_case allow  'ls 2>&1'

# ── Env var prefixes ───────────────────────────────────────────────
run_case allow  'GH_HOST=foo gh pr list'
run_case allow  'NODE_ENV=prod npm list'
run_case allow  'FOO=bar ls'

# ── Subshells / command substitution ──────────────────────────────
run_case allow  'cat $(find . -name "*.md")'
run_case allow  'ls `which git`'
run_case prompt 'cat $(rm file; echo file)'

# ── Control flow (if / for / while) ───────────────────────────────
run_case allow  'if git diff --quiet; then echo clean; fi'
run_case allow  'for f in a b c; do echo $f; done'
run_case prompt 'if true; then rm file; fi'

# ── Git subcommand + flag awareness ───────────────────────────────
run_case allow  'git log'
run_case allow  'git log --oneline -20'
run_case allow  'git diff HEAD~1'
run_case allow  'git status'
run_case allow  'git show abc123'
run_case allow  'git blame file.c'
run_case allow  'git branch'
run_case allow  'git branch -a'
run_case allow  'git branch -vv'
run_case allow  'git branch --contains abc123'
run_case allow  'git branch --merged main'
run_case prompt 'git branch -D feature'
run_case prompt 'git branch new-feature'
run_case prompt 'git branch -d old-branch'
run_case allow  'git tag'
run_case allow  'git tag -l'
run_case allow  'git tag --contains abc'
run_case prompt 'git tag v1.0.0'
run_case prompt 'git tag -d old-tag'
run_case prompt 'git tag -a v1.0 -m "release"'
run_case allow  'git remote'
run_case allow  'git remote -v'
run_case allow  'git remote show origin'
run_case allow  'git remote get-url origin'
run_case prompt 'git remote add foo https://example.com/repo.git'
run_case prompt 'git remote rm origin'
run_case allow  'git stash list'
run_case allow  'git stash show'
run_case prompt 'git stash'
run_case prompt 'git stash pop'
run_case allow  'git config --list'
run_case allow  'git config --get user.email'
run_case prompt 'git config user.email foo@bar.com'
run_case allow  'git fetch'
run_case allow  'git fetch --all'
run_case prompt 'git push origin main'
run_case prompt 'git commit -m foo'
run_case prompt 'git merge feature'
run_case prompt 'git rebase main'
run_case prompt 'git reset --hard'
run_case prompt 'git add .'
run_case prompt 'git checkout main'

# ── Git global flags ───────────────────────────────────────────────
run_case allow  'git -C /tmp/repo log'
run_case allow  'git --no-pager log'
run_case allow  'git -c color.ui=always log'
run_case prompt 'git -C /tmp/repo push'

# ── gh ─────────────────────────────────────────────────────────────
run_case allow  'gh pr view 123'
run_case allow  'gh pr list --state open'
run_case allow  'gh issue view 42'
run_case allow  'gh api /user'
run_case allow  'gh auth status'
run_case prompt 'gh pr create --title foo'
run_case prompt 'gh pr merge 123'
run_case prompt 'gh issue close 42'

# ── Unknown commands ───────────────────────────────────────────────
run_case prompt 'some_random_tool --flag'
run_case prompt 'docker run ubuntu'
run_case prompt 'kubectl apply -f foo.yaml'

# ── Edge cases ─────────────────────────────────────────────────────
run_case allow  'ls -la; pwd && git status | head'
run_case prompt 'ls; rm file; pwd'    # middle one is bad
run_case allow  'echo "hello | world"' # pipe is inside string, shouldn't split
run_case allow  'echo "a && b"'        # && inside string

# ── Malformed / adversarial input ─────────────────────────────────
# These MUST prompt (fall through). Auto-approving unparseable input
# would be a serious safety bug.
run_case prompt 'if true; then'              # unterminated if
run_case prompt 'echo $(( 1 + '              # unterminated arithmetic
run_case prompt '((('                        # pure garbage
run_case prompt 'echo hi | ; ls'             # truly unparseable syntax
run_case prompt 'cat <(rm file)'              # process subst hiding a write

# ── Raw-stdin safety (bypassing run_case) ─────────────────────────
# These test the script's behavior on edge-case *stdin*, not well-formed
# hook JSON. They MUST exit 0 with no output (fall through), never crash.
check_silent_zero() {
  local label="$1"
  local input="$2"
  local output exit_code
  output=$(printf '%s' "$input" | "$CLASSIFIER" 2>/dev/null)
  exit_code=$?
  if [[ "$exit_code" -eq 0 && -z "$output" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("stdin-safety [$label]: exit=$exit_code output=$output")
  fi
}

check_silent_zero 'empty stdin'              ''
check_silent_zero 'invalid JSON'             'not even json'
check_silent_zero 'JSON with no tool_input'  '{}'
check_silent_zero 'JSON with null command'   '{"tool_input":{"command":null}}'
check_silent_zero 'JSON with empty command'  '{"tool_input":{"command":""}}'
check_silent_zero 'JSON missing command'     '{"tool_input":{}}'

# ── Dependency-check hook (SessionStart) ──────────────────────────
# Verify that check-deps.sh behaves correctly in all four states:
# both deps present; each dep individually missing; both missing.
CHECK_DEPS="$SCRIPT_DIR/check-deps.sh"

if [[ -x "$CHECK_DEPS" ]]; then
  # Use a temp HOME so the stamp file doesn't persist between cases.
  run_deps_case() {
    local label="$1"
    local fake_path="$2"
    local expect_warn="$3"
    local tmp_home
    tmp_home=$(mktemp -d)
    local output
    output=$(CLAUDE_PLUGIN_DATA="$tmp_home/data" PATH="$fake_path" "$CHECK_DEPS" <<< '{}' 2>&1)
    local has_warn=no
    [[ "$output" == *"missing required dependencies"* ]] && has_warn=yes
    rm -rf "$tmp_home"
    if [[ "$has_warn" == "$expect_warn" ]]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      FAILED_CASES+=("check-deps [$label]: expected warn=$expect_warn, got warn=$has_warn")
    fi
  }

  # Stage fake versions of each dep in a tmpdir so we can control what's on PATH.
  DEPS_TMP=$(mktemp -d)
  # Only create the link if the real binary exists on this machine.
  [[ -x "$(command -v jq    2>/dev/null)" ]] && ln -s "$(command -v jq)"    "$DEPS_TMP/jq"
  [[ -x "$(command -v shfmt 2>/dev/null)" ]] && ln -s "$(command -v shfmt)" "$DEPS_TMP/shfmt"

  # Minimal PATH with basic OS tools but no jq/shfmt — realistic
  # "fresh machine" simulation.
  MIN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

  # jq is in /usr/bin on macOS by default, so "both missing" requires
  # a PATH that excludes both /usr/bin/jq and any shfmt location.
  # We use an isolated minimal PATH that is empty of both.
  EMPTY_DEPS=$(mktemp -d)

  if [[ -e "$DEPS_TMP/jq" && -e "$DEPS_TMP/shfmt" ]]; then
    run_deps_case 'both present'        "$DEPS_TMP:$MIN_PATH"      'no'
  fi
  run_deps_case 'both missing'          "$EMPTY_DEPS:/bin"          'yes'
  if [[ -e "$DEPS_TMP/jq" ]]; then
    JQ_ONLY=$(mktemp -d)
    ln -s "$DEPS_TMP/jq" "$JQ_ONLY/jq"
    run_deps_case 'only shfmt missing'  "$JQ_ONLY:/bin"             'yes'
    rm -rf "$JQ_ONLY"
  fi
  rm -rf "$EMPTY_DEPS"

  rm -rf "$DEPS_TMP"
fi

# ── Summary ────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if (( FAIL > 0 )); then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  $c"
  done
  exit 1
fi
