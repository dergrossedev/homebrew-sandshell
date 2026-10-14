#!/usr/bin/env bash
# Tests for scripts/release.sh, the release preparation automation.
#
# Every test runs in a throwaway Git repository so the real working tree is never
# modified. The test suite exercises only the local preparation steps that
# release.sh performs before any public action.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

# copy_release_tree DEST — copy the repository tree needed by release.sh into a
# throwaway directory.
copy_release_tree() {
  mkdir -p "$1/scripts" "$1/src" "$1/completions" "$1/examples" "$1/Formula"
  cp -r "$SANDSHELL_ROOT"/scripts/*.sh "$1/scripts/"
  chmod +x "$1"/scripts/*.sh
  cp -r "$SANDSHELL_ROOT"/src/*.sh "$1/src/"
  cp "$SANDSHELL_SH" "$1/sandshell.sh"
  cp "$SANDSHELL_ROOT"/completions/sandshell.bash "$1/completions/"
  cp "$SANDSHELL_ROOT"/completions/_sandshell "$1/completions/"
  cp "$SANDSHELL_ROOT"/examples/vibe.toml "$1/examples/"
  cp "$SANDSHELL_ROOT"/README.md "$1/"
  cp "$SANDSHELL_ROOT"/LICENSE "$1/"
  cp "$SANDSHELL_ROOT"/CHANGELOG.md "$1/"
  cp -r "$SANDSHELL_ROOT"/packaging "$1/"
  # Create an initial commit so git status is clean
  git -C "$1" init -q
  git -C "$1" add .
  git -C "$1" commit -q -m "Initial commit"
}

# touch_file FILE — update file mtime to force stale artifact checks
# (no-op on platforms without touch)
touch_file() {
  if command -v touch >/dev/null 2>&1; then
    touch "$1"
  fi
}

test_release_script_is_executable() {
  setup_test_env
  [ -x "$SANDSHELL_ROOT/scripts/release.sh" ] || assert_fail 'scripts/release.sh is not executable'
}

test_release_rejects_missing_version() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh"
  assert_rc 2
  assert_contains "$ERR" 'usage:'
}

test_release_rejects_extra_arguments() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0 extra
  assert_rc 2
  assert_contains "$ERR" 'usage:'
}

test_release_rejects_leading_v() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" v0.2.0
  assert_rc 2
  assert_contains "$ERR" 'must not start with "v"'
}

test_release_rejects_malformed_versions() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  for v in '1.0.0' '0.1' '0.1.0.1' 'abc' '0.x.0' '0.1.0-rc.1' '0.1.2.3' ''; do
    run "$TEST_TMP/repo/scripts/release.sh" "$v"
    assert_rc 2 "version [$v] must be rejected"
    assert_contains "$ERR" 'invalid version'
  done
}

test_release_rejects_dirty_working_tree() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Make working tree dirty
  echo "# change" >> "$TEST_TMP/repo/README.md"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 1
  assert_contains "$ERR" 'working tree is dirty'
}

test_release_rejects_missing_changelog_entry() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Update CHANGELOG to remove the 0.2.0 entry
  sed -i.bak '/^\[0\.2\.0\]/d' "$TEST_TMP/repo/CHANGELOG.md" || sed -i '' '/^\[0\.2\.0\]/d' "$TEST_TMP/repo/CHANGELOG.md"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 1
  assert_contains "$ERR" 'CHANGELOG.md must contain a release entry'
}

test_release_rejects_unreleased_changelog_entry() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Change the date to "Unreleased" for 0.2.0
  sed -i.bak 's/\[0\.2\.0\] - .*/[0.2.0] - Unreleased/' "$TEST_TMP/repo/CHANGELOG.md" || \
    sed -i '' 's/\[0\.2\.0\] - .*/[0.2.0] - Unreleased/' "$TEST_TMP/repo/CHANGELOG.md"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 1
  assert_contains "$ERR" 'CHANGELOG.md must contain a release entry'
}

test_release_valid_version_passes_preconditions() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 0
  # Script should complete all preconditions successfully
  assert_not_contains "$ERR" 'working tree is dirty'
  assert_not_contains "$ERR" 'CHANGELOG.md must contain'
}

test_release_generates_formula_with_correct_sha() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 0
  # Formula should be generated
  assert_file_exists "$TEST_TMP/repo/Formula/sandshell.rb"
  # Verify formula contains the correct version and owner
  assert_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'owner: dergrossedev'
  assert_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'version: 0.2.0'
  # Verify formula references the correct download URL
  assert_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'https://github.com/dergrossedev/homebrew-sandshell/releases/download/v0.2.0/sandshell-0.2.0.tar.gz'
  # Verify formula does NOT contain explicit Ruby version declaration
  assert_not_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'version '"'"'ruby'"'"''
}

test_release_formula_receives_package_sha() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 0
  formula_content=$(cat "$TEST_TMP/repo/Formula/sandshell.rb")
  package_sha=$(awk '{print $1}' "$TEST_TMP/repo/dist/sandshell-0.2.0.tar.gz.sha256")
  assert_contains "$formula_content" "sha256: $package_sha"
}

test_release_sha_consistency_guard() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 0
  # Verify package/formula SHA is consistent
  original_sha=$(awk '{print $1}' "$TEST_TMP/repo/dist/sandshell-0.2.0.tar.gz.sha256")
  # Package again to get new SHA
  run "$TEST_TMP/repo/scripts/package.sh" 0.2.0
  new_sha=$(awk '{print $1}' "$TEST_TMP/repo/dist/sandshell-0.2.0.tar.gz.sha256")
  # They should match since we didn't change anything
  assert_eq "$original_sha" "$new_sha"
}

test_release_fails_on_quality_gate() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Make sandshell.sh stale to fail the quality gate
  echo "# stale" >> "$TEST_TMP/repo/src/core.sh"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 1
  assert_contains "$ERR" 'quality gate failed'
}

test_release_outputs_compact_summary() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 0.2.0
  assert_rc 0
  assert_contains "$OUT" 'Prepared v0.2.0'
  assert_contains "$OUT" 'Package:'
  assert_contains "$OUT" 'SHA256:'
  assert_contains "$OUT" 'Formula:'
  assert_contains "$OUT" 'Next:'
}

run_tests \
  test_release_script_is_executable \
  test_release_rejects_missing_version \
  test_release_rejects_extra_arguments \
  test_release_rejects_leading_v \
  test_release_rejects_malformed_versions \
  test_release_rejects_dirty_working_tree \
  test_release_rejects_missing_changelog_entry \
  test_release_rejects_unreleased_changelog_entry \
  test_release_valid_version_passes_preconditions \
  test_release_generates_formula_with_correct_sha \
  test_release_formula_receives_package_sha \
  test_release_sha_consistency_guard \
  test_release_fails_on_quality_gate \
  test_release_outputs_compact_summary
