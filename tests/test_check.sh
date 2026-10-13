#!/usr/bin/env bash
# Tests for scripts/check.sh, the local quality gate. Each test runs
# check.sh against a throwaway copy of the repository tree, so the real
# working tree is never modified and the suite never recurses into itself.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

# copy_repo DEST — a minimal copy of the repository tree (scripts, sources,
# artifact, completions, test helpers, the sbx mock, and the examples/ build
# input) for check.sh runs.
copy_repo() {
  mkdir -p "$1/scripts" "$1/src" "$1/tests/mocks" "$1/completions" "$1/examples"
  cp "$SANDSHELL_ROOT"/scripts/*.sh "$1/scripts/"
  cp "$SANDSHELL_ROOT"/src/*.sh "$1/src/"
  cp "$SANDSHELL_ROOT/sandshell.sh" "$1/sandshell.sh"
  cp "$SANDSHELL_ROOT/completions/sandshell.bash" "$1/completions/"
  cp "$SANDSHELL_ROOT/completions/_sandshell" "$1/completions/"
  cp "$SANDSHELL_ROOT/examples/vibe.toml" "$1/examples/"
  cp "$SANDSHELL_ROOT/tests/helpers.sh" "$1/tests/"
  cp "$SANDSHELL_ROOT/tests/mocks/sbx" "$1/tests/mocks/"
  chmod +x "$1"/scripts/*.sh "$1/tests/mocks/sbx"
}

# write_minimal_test DEST EXPECTED_RC — a minimal test file for the copied
# tree's test stage. EXPECTED_RC 0 passes; any other value fails on purpose.
write_minimal_test() {
  cat >"$1/tests/test_minimal.sh" <<EOF
#!/usr/bin/env bash
# Minimal test used by test_check.sh's copied-tree checks.

_helpers_dir=\${0%/*}
[ "\$_helpers_dir" = "\$0" ] && _helpers_dir=.
. "\$_helpers_dir/helpers.sh"
unset _helpers_dir

test_minimal_passes() {
  setup_test_env
  run sbxcmd
  assert_rc $2
  assert_contains "\$OUT" 'Docker Sandbox helpers:'
}

run_tests test_minimal_passes
EOF
  chmod +x "$1/tests/test_minimal.sh"
}

# make_noshellcheck_bin — an explicit allowlist bin directory holding the
# tools the check chain needs, with shellcheck deliberately absent.
make_noshellcheck_bin() {
  mkdir -p "$TEST_TMP/nosc-bin"
  local tool src
  for tool in bash zsh sh env dirname cat cmp mktemp chmod mv ln mkdir rm \
    basename grep sed awk cksum readlink stat uname find diff sort git tr; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$src" "$TEST_TMP/nosc-bin/$tool"
  done
}

test_check_script_is_executable() {
  setup_test_env
  [ -x "$SANDSHELL_ROOT/scripts/check.sh" ] || assert_fail 'scripts/check.sh is not executable'
}

test_check_clean_tree_passes() {
  setup_test_env
  tree=$TEST_TMP/repo
  copy_repo "$tree"
  write_minimal_test "$tree" 0
  run "$tree/scripts/check.sh"
  assert_rc 0
  assert_contains "$OUT" 'all checks passed'
}

test_check_stale_artifact_fails() {
  setup_test_env
  tree=$TEST_TMP/repo
  copy_repo "$tree"
  printf '\n# stale\n' >>"$tree/src/core.sh"
  run "$tree/scripts/check.sh"
  assert_rc 1
  assert_contains "$ERR" 'stale'
  assert_contains "$ERR" './scripts/build.sh'
}

test_check_bash_syntax_error_fails() {
  setup_test_env
  tree=$TEST_TMP/repo
  copy_repo "$tree"
  printf '\nif true; then\n' >>"$tree/src/core.sh"
  run "$tree/scripts/check.sh"
  assert_rc 1
  assert_contains "$ERR" 'bash -n failed'
  assert_contains "$ERR" 'src/core.sh'
}

test_check_zsh_syntax_error_fails() {
  setup_test_env
  tree=$TEST_TMP/repo
  copy_repo "$tree"
  printf '\nif true; then\n' >>"$tree/completions/_sandshell"
  run "$tree/scripts/check.sh"
  assert_rc 1
  assert_contains "$ERR" 'zsh -n failed'
  assert_contains "$ERR" 'completions/_sandshell'
}

test_check_skips_shellcheck_when_absent() {
  setup_test_env
  tree=$TEST_TMP/repo
  copy_repo "$tree"
  write_minimal_test "$tree" 0
  make_noshellcheck_bin
  run env PATH="$TEST_TMP/bin:$TEST_TMP/nosc-bin" "$tree/scripts/check.sh"
  assert_rc 0
  assert_contains "$OUT" 'shellcheck not found; skipping'
  assert_contains "$OUT" 'all checks passed'
}

test_check_failing_test_fails() {
  setup_test_env
  tree=$TEST_TMP/repo
  copy_repo "$tree"
  write_minimal_test "$tree" 1
  run "$tree/scripts/check.sh"
  assert_rc 1
  assert_contains "$ERR" 'test suite failed'
}

run_tests \
  test_check_script_is_executable \
  test_check_clean_tree_passes \
  test_check_stale_artifact_fails \
  test_check_bash_syntax_error_fails \
  test_check_zsh_syntax_error_fails \
  test_check_skips_shellcheck_when_absent \
  test_check_failing_test_fails
