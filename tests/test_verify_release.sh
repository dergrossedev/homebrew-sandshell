#!/usr/bin/env bash
# Post-publish verification uses only disposable assets and mocked brew/zsh.
_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

setup_verify_release() {
  setup_test_env
  export VERIFY_PREFIX="$TEST_TMP/homebrew with spaces"
  export VERIFY_FORMULA_PREFIX="$VERIFY_PREFIX/opt/sandshell"
  mkdir -p "$VERIFY_PREFIX/opt" "$VERIFY_PREFIX/Cellar/sandshell/2026.9.0" \
    "$VERIFY_PREFIX/Cellar/sandshell/2026.10.0/libexec" \
    "$VERIFY_PREFIX/Cellar/sandshell/2026.10.0/share/sandshell/examples" \
    "$VERIFY_PREFIX/share/zsh/site-functions" "$VERIFY_PREFIX/etc/bash_completion.d"
  ln -s "$VERIFY_PREFIX/Cellar/sandshell/2026.10.0" "$VERIFY_FORMULA_PREFIX"
  cp "$SANDSHELL_SH" "$VERIFY_FORMULA_PREFIX/libexec/sandshell.sh"
  cp "$SANDSHELL_ROOT/examples/vibe.toml" "$VERIFY_FORMULA_PREFIX/share/sandshell/examples/"
  cp "$SANDSHELL_ROOT/completions/_sandshell" "$VERIFY_PREFIX/share/zsh/site-functions/"
  cp "$SANDSHELL_ROOT/completions/sandshell.bash" "$VERIFY_PREFIX/etc/bash_completion.d/"
  cat >"$TEST_TMP/bin/brew" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_TMP/verify-calls"
case "$*" in
  update|"audit --strict dergrossedev/sandshell/sandshell"|"test dergrossedev/sandshell/sandshell")
    [ ! -f "$TEST_TMP/fail-$1" ] || { printf 'mock %s failure\n' "$1" >&2; exit 1; }
    printf 'Homebrew progress output\n' ;;
  'list --formula')
    [ ! -f "$TEST_TMP/fail-list" ] || { printf 'mock list failure\n' >&2; exit 1; }
    printf 'other-formula\n'
    if [ -f "$TEST_TMP/installed-version" ]; then printf 'sandshell\n'; fi ;;
  'list --versions sandshell')
    [ ! -f "$TEST_TMP/fail-list" ] || { printf 'mock list failure\n' >&2; exit 1; }
    # Homebrew exits 1 with no output for an absent installation.
    [ -f "$TEST_TMP/installed-version" ] || exit 1
    if [ -f "$TEST_TMP/retained-keg" ]; then
      printf 'sandshell 2026.9.0 2026.10.0\n'
    else
      printf 'sandshell %s\n' "$(cat "$TEST_TMP/installed-version")"
    fi ;;
  'install dergrossedev/sandshell/sandshell'|'upgrade sandshell')
    [ ! -f "$TEST_TMP/fail-$1" ] || { printf 'mock %s failure\n' "$1" >&2; exit 1; }
    if [ -f "$TEST_TMP/already-current" ]; then
      printf 'Warning: sandshell 2026.10.0 already installed\n' >&2
      exit 1
    fi
    if [ -f "$TEST_TMP/wrong-version" ]; then
      printf '2026.9.0\n' >"$TEST_TMP/installed-version"
    else
      printf '2026.10.0\n' >"$TEST_TMP/installed-version"
    fi
    rm "$VERIFY_FORMULA_PREFIX"
    ln -s "$VERIFY_PREFIX/Cellar/sandshell/$(cat "$TEST_TMP/installed-version")" "$VERIFY_FORMULA_PREFIX" ;;
  '--prefix sandshell') printf '%s\n' "$VERIFY_FORMULA_PREFIX" ;;
  '--prefix') printf '%s\n' "$VERIFY_PREFIX" ;;
  *) printf 'unexpected brew invocation: %s\n' "$*" >&2; exit 99 ;;
esac
MOCK
  cat >"$TEST_TMP/bin/zsh" <<'MOCK'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = -f ] && [ "$2" = -c ] || exit 99
printf 'runtime\n' >>"$TEST_TMP/verify-calls"
[ ! -f "$TEST_TMP/fail-runtime" ] || { printf 'mock runtime failure\n' >&2; exit 1; }
# Exercise the smoke command against the installed fixture without real Zsh.
exec /bin/bash --noprofile --norc -c "$3"
MOCK
  # Any backend invocation fails and is recorded, even inside the smoke test.
  rm "$TEST_TMP/bin/sbx"
  cat >"$TEST_TMP/bin/sbx" <<'MOCK'
#!/bin/sh
printf 'unexpected sbx invocation\n' >>"$TEST_TMP/sbx-called"
exit 99
MOCK
  chmod +x "$TEST_TMP/bin/brew" "$TEST_TMP/bin/zsh" "$TEST_TMP/bin/sbx"
}

verify_release() { run bash "$SANDSHELL_ROOT/scripts/verify-release.sh" "$@"; }

assert_verify_success() {
  assert_rc 0
  assert_eq 'Verified v2026.10.0

Homebrew audit: pass
Installed:       2026.10.0
Formula test:    pass
Runtime:         pass' "$OUT"
  assert_eq '' "$ERR"
  assert_file_missing "$TEST_TMP/sbx-called"
}

test_verify_invalid_versions() {
  setup_verify_release
  verify_release
  assert_rc 2
  verify_release 2026.10.0 extra
  assert_rc 2
  for version in '' 0.1.0 v2026.10.0 26.10.0 2026.01.0 2026.0.0 2026.13.0 2026.10.00 2026.10.0-beta; do
    verify_release "$version"
    assert_rc 2
    assert_contains "$ERR" 'YYYY.M.PATCH'
  done
  assert_file_missing "$TEST_TMP/verify-calls"
}

test_verify_missing_tools() {
  setup_verify_release
  mkdir "$TEST_TMP/tools"
  ln -s "$(command -v bash)" "$TEST_TMP/tools/bash"
  run env PATH="$TEST_TMP/tools" bash "$SANDSHELL_ROOT/scripts/verify-release.sh" 2026.10.0
  assert_rc 127
  assert_contains "$ERR" 'brew'
  ln -s "$TEST_TMP/bin/brew" "$TEST_TMP/tools/brew"
  run env PATH="$TEST_TMP/tools" bash "$SANDSHELL_ROOT/scripts/verify-release.sh" 2026.10.0
  assert_rc 127
  assert_contains "$ERR" 'zsh'
  assert_file_missing "$TEST_TMP/verify-calls"
}

test_verify_install_success() {
  setup_verify_release
  verify_release 2026.10.0
  assert_verify_success
  assert_eq 'update
audit --strict dergrossedev/sandshell/sandshell
list --formula
install dergrossedev/sandshell/sandshell
--prefix sandshell
test dergrossedev/sandshell/sandshell
--prefix
runtime
--prefix sandshell' "$(cat "$TEST_TMP/verify-calls")"
}

test_verify_upgrade_success() {
  setup_verify_release
  printf '2026.9.0\n' >"$TEST_TMP/installed-version"
  verify_release 2026.10.0
  assert_verify_success
  assert_contains "$(cat "$TEST_TMP/verify-calls")" 'upgrade sandshell'
  assert_not_contains "$(cat "$TEST_TMP/verify-calls")" 'install dergrossedev'
}

test_verify_already_current() {
  setup_verify_release
  printf '2026.10.0\n' >"$TEST_TMP/installed-version"
  touch "$TEST_TMP/already-current"
  verify_release 2026.10.0
  assert_verify_success
  assert_contains "$(cat "$TEST_TMP/verify-calls")" 'upgrade sandshell'
}

test_verify_retained_kegs_success() {
  setup_verify_release
  printf '2026.9.0\n' >"$TEST_TMP/installed-version"
  touch "$TEST_TMP/retained-keg"
  verify_release 2026.10.0
  assert_verify_success
  assert_dir_exists "$VERIFY_PREFIX/Cellar/sandshell/2026.9.0"
  assert_contains "$(cat "$TEST_TMP/verify-calls")" 'upgrade sandshell'
}

test_verify_retained_requested_version_inactive() {
  setup_verify_release
  printf '2026.9.0\n' >"$TEST_TMP/installed-version"
  touch "$TEST_TMP/retained-keg" "$TEST_TMP/wrong-version"
  verify_release 2026.10.0
  assert_rc 1
  assert_contains "$ERR" 'installed version is 2026.9.0; expected 2026.10.0'
  assert_not_contains "$(cat "$TEST_TMP/verify-calls")" 'test dergrossedev'
  assert_not_contains "$OUT" 'Verified'
}

test_verify_version_mismatch() {
  setup_verify_release
  touch "$TEST_TMP/wrong-version"
  verify_release 2026.10.0
  assert_rc 1
  assert_contains "$ERR" '2026.9.0'
  assert_contains "$ERR" 'expected 2026.10.0'
  assert_not_contains "$(cat "$TEST_TMP/verify-calls")" 'test dergrossedev'
  assert_not_contains "$OUT" 'Verified'
}

test_verify_brew_failures_stop() {
  for step in update audit list install upgrade test; do
    setup_verify_release
    if [ "$step" = upgrade ]; then printf '2026.9.0\n' >"$TEST_TMP/installed-version"; fi
    touch "$TEST_TMP/fail-$step"
    verify_release 2026.10.0
    assert_rc 1
    assert_contains "$ERR" 'verify-release.sh:'
    calls=$(cat "$TEST_TMP/verify-calls")
    case $step in
      update) assert_eq update "$calls" ;;
      audit) assert_not_contains "$calls" 'list --formula' ;;
      list) assert_not_contains "$calls" 'install dergrossedev' ;;
      install|upgrade) assert_not_contains "$calls" 'test dergrossedev' ;;
      test) assert_not_contains "$calls" runtime ;;
    esac
    assert_not_contains "$calls" runtime
    assert_not_contains "$OUT" 'Verified'
  done
}

test_verify_missing_assets() {
  for asset in opt/sandshell/libexec/sandshell.sh opt/sandshell/share/sandshell/examples/vibe.toml \
    share/zsh/site-functions/_sandshell etc/bash_completion.d/sandshell.bash; do
    setup_verify_release
    rm "$VERIFY_PREFIX/$asset"
    verify_release 2026.10.0
    assert_rc 1
    assert_contains "$ERR" "missing installed asset: $VERIFY_PREFIX/$asset"
    assert_not_contains "$(cat "$TEST_TMP/verify-calls")" runtime
  done
}

test_verify_runtime_failure() {
  setup_verify_release
  touch "$TEST_TMP/fail-runtime"
  verify_release 2026.10.0
  assert_rc 1
  assert_contains "$ERR" 'runtime smoke test failed'
  assert_not_contains "$OUT" 'Verified'
  assert_file_missing "$TEST_TMP/sbx-called"
}

test_verify_runtime_missing_function() {
  setup_verify_release
  # A successful final sbxcmd must not hide a missing earlier public function.
  printf 'sbxcmd() { return 0; }\n' >"$VERIFY_FORMULA_PREFIX/libexec/sandshell.sh"
  verify_release 2026.10.0
  assert_rc 1
  assert_contains "$ERR" 'runtime smoke test failed'
  assert_not_contains "$OUT" 'Verified'
  assert_file_missing "$TEST_TMP/sbx-called"
}

run_tests test_verify_invalid_versions test_verify_missing_tools \
  test_verify_install_success test_verify_upgrade_success test_verify_already_current \
  test_verify_retained_kegs_success test_verify_retained_requested_version_inactive \
  test_verify_version_mismatch test_verify_brew_failures_stop test_verify_missing_assets \
  test_verify_runtime_failure test_verify_runtime_missing_function
