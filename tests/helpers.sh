# shellcheck shell=bash
# Shared helpers for the Sandshell test suite.
#
# Sourced by tests/test_*.sh. The suite runs every test file under both Bash
# and Zsh, so this file sticks to the common shell subset: no arrays, no
# `read -a`, no shell-specific expansions.
#
# Safety model:
#   - scripts/test.sh runs the whole suite with a throwaway HOME, ZDOTDIR, and
#     TMPDIR, so no user configuration or state is ever read or written.
#   - setup_test_env gives every test its own temporary directory, a mock
#     `sbx` in $TEST_TMP/bin, and a restricted PATH ($TEST_TMP/bin:/usr/bin:/bin).
#     The user's original PATH is deliberately not on it, so Homebrew binaries
#     (/opt/homebrew/bin/sbx, /usr/local/bin/sbx, ...) are unreachable by
#     construction. A test that needs another executable creates a stub in
#     $TEST_TMP/bin.
#   - Git identity is pinned and Git configuration is disabled, so no test
#     touches the user's Git configuration; Git runs only inside temporary
#     repositories.
#   - Each test runs in a subshell (see run_test); the per-file temporary root
#     is removed when the test file's shell exits.

# --- repository anchors ------------------------------------------------------

SANDSHELL_ROOT=$(cd "${0%/*}/.." && pwd)
SANDSHELL_SH="$SANDSHELL_ROOT/sandshell.sh"

# Per-file temporary root, canonicalized to a physical path so Git's
# /private/var spelling on macOS matches test expectations. The trap is set at
# the top level of this sourced file (not inside a function) so it fires when
# the test file's shell exits in both Bash and Zsh; Zsh runs function-scoped
# EXIT traps at function return. run_test additionally removes each test's
# tree right after the test.
SANDSHELL_TESTS_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sandshell-tests.XXXXXX")
SANDSHELL_TESTS_ROOT=$(cd "$SANDSHELL_TESTS_ROOT" && pwd -P)
trap 'rm -rf "$SANDSHELL_TESTS_ROOT"' EXIT

# --- assertions ---------------------------------------------------------------
# Assertions print a diagnostic and exit the current subshell. run_test runs
# every test function inside a subshell, so a failure fails exactly one test
# and the EXIT trap still cleans up.

assert_fail() {
  printf '    %s\n' "$1"
  exit 1
}

assert_eq() { # EXPECTED ACTUAL [MESSAGE]
  if [ "$1" != "$2" ]; then
    printf '    expected: [%s]\n    actual:   [%s]\n    %s\n' "$1" "$2" "${3:-values differ}"
    exit 1
  fi
}

assert_contains() { # HAYSTACK NEEDLE [MESSAGE]
  case $1 in
    *"$2"*) ;;
    *)
      printf '    expected to contain: [%s]\n    actual: [%s]\n    %s\n' "$2" "$1" "${3:-substring missing}"
      exit 1
      ;;
  esac
}

assert_not_contains() { # HAYSTACK NEEDLE [MESSAGE]
  case $1 in
    *"$2"*)
      printf '    expected not to contain: [%s]\n    actual: [%s]\n    %s\n' "$2" "$1" "${3:-unexpected substring}"
      exit 1
      ;;
  esac
}

assert_rc() { # EXPECTED_RC [MESSAGE] — compares against $RC
  if [ "$RC" != "$1" ]; then
    printf '    expected rc: %s\n    actual rc:   %s\n    %s\n' "$1" "$RC" "${3:-exit code differs}"
    exit 1
  fi
}

assert_match() { # REGEX VALUE [MESSAGE]
  if [[ ! $2 =~ $1 ]]; then
    printf '    expected to match: %s\n    actual: [%s]\n    %s\n' "$1" "$2" "${3:-no match}"
    exit 1
  fi
}

assert_comp() { # EXPECTED_SPACE_JOINED ACTUAL_NEWLINE_JOINED [MESSAGE]
  # Compare completion candidates: the harness prints one candidate per line,
  # expectations read naturally space-joined. Parameter expansion (not tr) so
  # the helper works when PATH is restricted (hide_git).
  local joined=${2//$'\n'/ }
  assert_eq "$1" "${joined% }" "${3:-completion candidates differ}"
}

assert_file_exists() {
  [ -e "$1" ] || assert_fail "expected file to exist: $1"
}

assert_file_missing() {
  if [ -e "$1" ]; then assert_fail "expected file to be missing: $1"; fi
}

assert_dir_exists() {
  [ -d "$1" ] || assert_fail "expected directory to exist: $1"
}

assert_file_eq() { # FILE_A FILE_B [MESSAGE]
  if ! diff -u "$1" "$2" >"$TEST_TMP/.diff" 2>&1; then
    sed 's/^/    /' "$TEST_TMP/.diff"
    assert_fail "${3:-files differ}: $1 vs $2"
  fi
}

# --- command capture ----------------------------------------------------------

# run FUNC ARGS... — invoke a Sandshell function with stdin detached from any
# terminal. Sets OUT (stdout), ERR (stderr), RC (exit code).
run() {
  "$@" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err" </dev/null
  RC=$?
  # OUT and ERR are read by test assertions through $OUT/$ERR.
  # shellcheck disable=SC2034
  OUT=$(cat "$TEST_TMP/.out")
  # shellcheck disable=SC2034
  ERR=$(cat "$TEST_TMP/.err")
}

# --- test environment ---------------------------------------------------------

# setup_test_env — fresh temporary HOME, mock sbx on a restricted PATH, pinned
# Git identity, and sandshell.sh sourced. Every test calls this first.
setup_test_env() {
  TEST_TMP=$(mktemp -d "$SANDSHELL_TESTS_ROOT/test.XXXXXX")
  export TEST_TMP
  mkdir -p "$TEST_TMP/home" "$TEST_TMP/bin" "$TEST_TMP/state"
  export HOME="$TEST_TMP/home"
  export XDG_STATE_HOME="$TEST_TMP/xdg-state"
  export SBX_MOCK_STATE="$TEST_TMP/state"
  # Restricted test PATH: per-test mocks first, then only the system
  # directories. The user's original PATH is not included, so Homebrew
  # binaries (/opt/homebrew/bin/sbx, /usr/local/bin/sbx, ...) are unreachable.
  export PATH="$TEST_TMP/bin:/usr/bin:/bin"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME="Sandshell Test"
  export GIT_AUTHOR_EMAIL="sandshell-test@example.com"
  export GIT_COMMITTER_NAME="Sandshell Test"
  export GIT_COMMITTER_EMAIL="sandshell-test@example.com"
  export VISUAL=/usr/bin/false
  export EDITOR=/usr/bin/false
  export GIT_EDITOR=/usr/bin/false
  export GIT_TERMINAL_PROMPT=0
  unset MCP_GATEWAY_URL MCP_SENTINEL_TOKEN_NAME VIBE_HOME
  unset XDG_CONFIG_HOME SANDSHELL_CONFIG_HOME
  unset BASH_ENV ENV BROWSER
  ln -s "$SANDSHELL_ROOT/tests/mocks/sbx" "$TEST_TMP/bin/sbx"
  # SANDSHELL_SH is computed from the repository root at runtime.
  # shellcheck disable=SC1090
  . "$SANDSHELL_SH"
  # Automated tests must opt in to a confirmation decision explicitly.
  _sbx_confirm() {
    printf 'TEST ERROR: unexpected confirmation: %s\n' "$*" >&2
    return 99
  }
}

# hide_sbx — make `command -v sbx` fail: remove the per-test mock. Nothing
# else on the restricted PATH provides sbx.
hide_sbx() {
  rm -f "$TEST_TMP/bin/sbx"
}

# hide_git — make `command -v git` fail. PATH is replaced with a minimal bin
# dir holding only what the test harness itself needs (cat), so no real git
# (or anything else) is reachable.
hide_git() {
  mkdir -p "$TEST_TMP/nogit-bin"
  ln -s "$(command -v cat)" "$TEST_TMP/nogit-bin/cat"
  export PATH="$TEST_TMP/nogit-bin"
}

# --- mock fixtures ------------------------------------------------------------

# make_sandbox NAME AGENT STATUS WORKSPACE — register a sandbox in mock state.
make_sandbox() {
  mkdir -p "$SBX_MOCK_STATE/sandboxes" "$SBX_MOCK_STATE/fs/$1"
  printf 'agent\t%s\nworkspace\t%s\nstatus\t%s\n' "$2" "$4" "$3" >"$SBX_MOCK_STATE/sandboxes/$1"
}

mock_calls() {
  cat "$SBX_MOCK_STATE/calls.log" 2>/dev/null
}

mock_sandbox_status() {
  awk -F '\t' '$1 == "status" { print substr($0, index($0, "\t") + 1); exit }' "$SBX_MOCK_STATE/sandboxes/$1"
}

mock_sandbox_names() {
  local f
  for f in "$SBX_MOCK_STATE/sandboxes"/*; do
    [ -f "$f" ] && basename "$f"
  done
}

mock_sandbox_count() {
  mock_sandbox_names | grep -c . || true
}

# mock_sandbox_vibe_config NAME — in-sandbox Vibe config path in mock state.
mock_sandbox_vibe_config() {
  printf '%s/fs/%s/home/agent/.vibe/config.toml\n' "$SBX_MOCK_STATE" "$1"
}

# mock_sandbox_vibe_marker NAME — Sandshell-managed marker path in mock state.
mock_sandbox_vibe_marker() {
  printf '%s/fs/%s/home/agent/.vibe/.sandshell-config-managed\n' "$SBX_MOCK_STATE" "$1"
}

# mock_launched_config NAME — the sandbox Vibe config snapshot the mock took
# when it launched the agent; empty when the sandbox had no Vibe config.
mock_launched_config() {
  if [ -f "$SBX_MOCK_STATE/launched/$1.config" ]; then
    cat "$SBX_MOCK_STATE/launched/$1.config"
  fi
}

# make_stub NAME — executable on PATH that logs its arguments, one line per
# invocation (arguments space-joined).
make_stub() {
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/stub-%s.log"\n' "$TEST_TMP" "$1" >"$TEST_TMP/bin/$1"
  chmod +x "$TEST_TMP/bin/$1"
}

stub_log() {
  if [ -f "$TEST_TMP/stub-$1.log" ]; then cat "$TEST_TMP/stub-$1.log"; fi
}

# make_mcp_server NAME JSON — register a server in the mock MCP registry.
make_mcp_server() {
  mkdir -p "$SBX_MOCK_STATE/mcp-registry"
  printf '%s\n' "$2" >"$SBX_MOCK_STATE/mcp-registry/$1.json"
}

# make_skill NAME [DESCRIPTION] — create a skill in the shared store.
make_skill() {
  local store
  store=$(_sbx_skill_store)
  mkdir -p "$store/$1"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n' "$1" "${2:-A test skill}" "$1" >"$store/$1/SKILL.md"
}

# init_skill_state SANDBOX — create the per-sandbox skill tracking file the
# way sbxc does after creating a sandbox.
init_skill_state() {
  mkdir -p "$(_sbx_config_dir)/skills"
  : >"$(_sbx_config_dir)/skills/$1.skills"
}

# store_fingerprint — content+layout fingerprint of the shared skill store,
# used to prove host skill sources are never modified.
store_fingerprint() {
  local store f
  store=$(_sbx_skill_store)
  (cd "$store" && find . \( -type f -o -type l \) | sort | while IFS= read -r f; do
    if [ -L "$f" ]; then
      printf '%s -> %s\n' "$f" "$(readlink "$f")"
    else
      printf '%s ' "$f"
      cksum <"$f"
    fi
  done)
}

# tree_fingerprint — content+layout fingerprint of a directory tree (empty
# output when the directory does not exist), used to prove completion never
# creates or modifies configuration state.
tree_fingerprint() {
  if [ -d "$1" ]; then
    (cd "$1" && find . | sort | while IFS= read -r f; do
      if [ -f "$f" ]; then
        printf '%s ' "$f"
        cksum <"$f"
      else
        printf '%s\n' "$f"
      fi
    done)
  fi
}

# --- git fixtures -------------------------------------------------------------

# make_git_repo PATH — throwaway repo with one commit on branch main.
make_git_repo() {
  mkdir -p "$1"
  if ! git -C "$1" init -b main >/dev/null 2>&1; then
    git -C "$1" init >/dev/null 2>&1
    git -C "$1" symbolic-ref HEAD refs/heads/main
  fi
  git -C "$1" commit --allow-empty -m "initial commit" >/dev/null
}

git_repo_has_branch() { # PATH BRANCH
  git -C "$1" show-ref --verify --quiet "refs/heads/$2"
}

# --- misc ---------------------------------------------------------------------

file_mode() { # portable permission bits, e.g. 600
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

# --- test runner ----------------------------------------------------------------

TESTS_RUN=0
TESTS_FAILED=0

run_test() {
  local name
  for name in "$@"; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if ( "$name" ); then
      printf 'ok %s\n' "$name"
    else
      printf 'FAIL %s\n' "$name"
      TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    # Remove this test's temporary tree (find avoids Zsh's unmatched-glob error).
    find "$SANDSHELL_TESTS_ROOT" -maxdepth 1 -name 'test.*' -type d -exec rm -rf {} + 2>/dev/null
  done
  return 0
}

# run_tests NAME... — final line of every test file; the file's exit status is
# zero only when every test passed.
run_tests() {
  run_test "$@"
  [ "$TESTS_FAILED" -eq 0 ]
}
