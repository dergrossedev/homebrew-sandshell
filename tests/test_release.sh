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

# copy_release_tree DEST — copy current working-tree inputs into a clean,
# disposable repository. The explicit file list excludes .git and temp/output
# directories. Include shell compatibility and formula validation tests for the
# real quality gate; copying release tests would recurse into this suite.
copy_release_tree() {
  mkdir -p "$1/scripts" "$1/src" "$1/completions" "$1/examples" "$1/Formula" "$1/tests/mocks"
  cp -r "$SANDSHELL_ROOT"/scripts/*.sh "$1/scripts/"
  chmod +x "$1"/scripts/*.sh
  cp -r "$SANDSHELL_ROOT"/src/*.sh "$1/src/"
  cp "$SANDSHELL_ROOT"/sandshell.sh "$1/"
  cp "$SANDSHELL_ROOT"/completions/sandshell.bash "$1/completions/"
  cp "$SANDSHELL_ROOT"/completions/_sandshell "$1/completions/"
  cp "$SANDSHELL_ROOT"/examples/vibe.toml "$1/examples/"
  cp "$SANDSHELL_ROOT"/README.md "$1/"
  cp "$SANDSHELL_ROOT"/LICENSE "$1/"
  cp "$SANDSHELL_ROOT"/CHANGELOG.md "$1/"
  cp "$SANDSHELL_ROOT"/.gitignore "$1/"
  cp -r "$SANDSHELL_ROOT"/packaging "$1/"
  cp "$SANDSHELL_ROOT"/Formula/sandshell.rb "$1/Formula/"
  cp "$SANDSHELL_ROOT"/tests/helpers.sh "$SANDSHELL_ROOT"/tests/test_shell_compat.sh \
    "$SANDSHELL_ROOT"/tests/test_homebrew_formula_generated.sh "$1/tests/"
  cp "$SANDSHELL_ROOT"/tests/mocks/sbx "$1/tests/mocks/"
  # Give release tests a dated entry independent of the source changelog.
  if ! grep -q '^## \[2099\.12\.0\] - ' "$1/CHANGELOG.md"; then
    printf '\n## [2099.12.0] - 2099.12.01\n\n- Fixture release.\n' >> "$1/CHANGELOG.md"
  fi
  git -C "$1" init -q || assert_fail 'fixture git init failed'
  git -C "$1" config user.name 'Sandshell Test' || assert_fail 'fixture Git identity failed'
  git -C "$1" config user.email 'sandshell-test@example.com' || assert_fail 'fixture Git identity failed'
  git -C "$1" add -A || assert_fail 'fixture git add failed'
  git -C "$1" commit -q -m "Initial commit" || assert_fail 'fixture baseline commit failed'
  assert_eq '' "$(git -C "$1" status --porcelain)" 'fixture baseline must be clean'
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

test_release_fixture_is_clean_and_copies_working_tree() {
  setup_test_env
  copy_release_tree "$TEST_TMP/source"
  git -C "$TEST_TMP/source" tag source-only
  printf '\nUncommitted fixture source change\n' >> "$TEST_TMP/source/README.md"
  printf '#!/usr/bin/env bash\n# Untracked fixture source file\n' > "$TEST_TMP/source/src/fixture.sh"
  mkdir -p "$TEST_TMP/source/dist"
  printf 'generated archive\n' > "$TEST_TMP/source/dist/generated.tar.gz"

  SANDSHELL_ROOT="$TEST_TMP/source"
  copy_release_tree "$TEST_TMP/repo"

  assert_file_eq "$SANDSHELL_ROOT/README.md" "$TEST_TMP/repo/README.md"
  assert_file_eq "$SANDSHELL_ROOT/src/fixture.sh" "$TEST_TMP/repo/src/fixture.sh"
  assert_eq "$TEST_TMP/repo" "$(git -C "$TEST_TMP/repo" rev-parse --show-toplevel)"
  assert_eq '' "$(git -C "$TEST_TMP/repo" status --porcelain)"
  assert_eq '1' "$(git -C "$TEST_TMP/repo" rev-list --count HEAD)"
  assert_eq '' "$(git -C "$TEST_TMP/repo" tag -l)"
  assert_file_missing "$TEST_TMP/repo/dist"
  run "$TEST_TMP/repo/scripts/check.sh"
  assert_rc 0
}

test_release_fixture_includes_formula_validation() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  assert_file_eq "$SANDSHELL_ROOT/tests/test_homebrew_formula_generated.sh" \
    "$TEST_TMP/repo/tests/test_homebrew_formula_generated.sh"
  assert_file_eq "$SANDSHELL_ROOT/Formula/sandshell.rb" "$TEST_TMP/repo/Formula/sandshell.rb"
  run "$TEST_TMP/repo/tests/test_homebrew_formula_generated.sh"
  assert_rc 0 "$ERR"
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
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0 extra
  assert_rc 2
  assert_contains "$ERR" 'usage:'
}

test_release_rejects_leading_v() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" v2026.10.0
  assert_rc 2
  assert_contains "$ERR" 'must not start with "v"'
}

test_release_rejects_malformed_versions() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  before=$(tree_fingerprint "$TEST_TMP/repo")
  for v in '0.2.0' '26.10.0' '2026.01.0' '2026.0.0' '2026.13.0' '2026.10' '2026.10.0-beta' '2026.10.0+build' '2026.10.00' '1.0.0' 'abc' ''; do
    run "$TEST_TMP/repo/scripts/release.sh" "$v"
    assert_rc 2 "version [$v] must be rejected"
    assert_contains "$ERR" 'invalid version'
  done
  assert_eq "$before" "$(tree_fingerprint "$TEST_TMP/repo")" 'invalid versions must not mutate the repository'
}

test_release_accepts_calendar_versions() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Stop at the existing dirty-tree precondition after version validation.
  printf '\nDirty fixture\n' >> "$TEST_TMP/repo/README.md"
  for version in 2026.10.0 2026.10.1 2027.1.0; do
    run "$TEST_TMP/repo/scripts/release.sh" "$version"
    assert_rc 1
    assert_contains "$ERR" 'working tree is dirty'
  done
  assert_file_missing "$TEST_TMP/repo/dist"
}

test_release_rejects_dirty_working_tree() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Make working tree dirty
  echo "# change" >> "$TEST_TMP/repo/README.md"
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'working tree is dirty'
}

test_release_rejects_missing_changelog_entry() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Update CHANGELOG to remove the 2099.12.0 entry
  sed '/^## \[2099\.12\.0\] - /d' "$TEST_TMP/repo/CHANGELOG.md" > "$TEST_TMP/changelog"
  mv "$TEST_TMP/changelog" "$TEST_TMP/repo/CHANGELOG.md"
  git -C "$TEST_TMP/repo" add -A
  git -C "$TEST_TMP/repo" commit -q -m 'Remove fixture release entry' || assert_fail 'fixture commit failed'
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'CHANGELOG.md must contain a release entry'
}

test_release_rejects_unreleased_changelog_entry() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Keep the notes under Unreleased instead of a versioned release entry.
  sed 's/^## \[2099\.12\.0\] - .*/## [Unreleased]/' "$TEST_TMP/repo/CHANGELOG.md" > "$TEST_TMP/changelog"
  mv "$TEST_TMP/changelog" "$TEST_TMP/repo/CHANGELOG.md"
  git -C "$TEST_TMP/repo" add -A
  git -C "$TEST_TMP/repo" commit -q -m 'Mark fixture notes Unreleased' || assert_fail 'fixture commit failed'
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'CHANGELOG.md must contain a release entry'
}

test_release_valid_version_passes_preconditions() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 0
  # Script should complete all preconditions successfully
  assert_not_contains "$ERR" 'working tree is dirty'
  assert_not_contains "$ERR" 'CHANGELOG.md must contain'
}

test_release_generates_formula_with_correct_sha() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 0
  # Formula should be generated
  assert_file_exists "$TEST_TMP/repo/Formula/sandshell.rb"
  # Verify formula contains the correct version and owner
  assert_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'homepage "https://github.com/dergrossedev/homebrew-sandshell"'
  # Verify formula references the correct download URL
  assert_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'url "https://github.com/dergrossedev/homebrew-sandshell/releases/download/v2099.12.0/sandshell-2099.12.0.tar.gz"'
  # Verify formula does NOT contain explicit Ruby version declaration
  assert_not_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'version "'
}

test_release_formula_receives_package_sha() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 0
  formula_content=$(cat "$TEST_TMP/repo/Formula/sandshell.rb")
  package_sha=$(awk '{print $1}' "$TEST_TMP/repo/dist/sandshell-2099.12.0.tar.gz.sha256")
  assert_contains "$formula_content" "sha256 \"$package_sha\""
}

test_release_formula_url_and_sha_validation() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 0
  # Verify URL contains the version
  assert_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'url "https://github.com/dergrossedev/homebrew-sandshell/releases/download/v2099.12.0/sandshell-2099.12.0.tar.gz"'
  # Verify SHA matches the package
  package_sha=$(awk '{print $1}' "$TEST_TMP/repo/dist/sandshell-2099.12.0.tar.gz.sha256")
  assert_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" "sha256 \"$package_sha\""
  # Verify no explicit version declaration
  assert_not_contains "$(cat "$TEST_TMP/repo/Formula/sandshell.rb")" 'version "'
}

test_release_fails_on_quality_gate() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  # Make sandshell.sh stale to fail the quality gate
  echo "# stale" >> "$TEST_TMP/repo/src/core.sh"
  git -C "$TEST_TMP/repo" add -A
  git -C "$TEST_TMP/repo" commit -q -m 'Make fixture artifact stale' || assert_fail 'fixture commit failed'
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'quality gate failed'
}

test_release_outputs_compact_summary() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 0
  assert_contains "$OUT" 'Prepared v2099.12.0'
  assert_contains "$OUT" 'Package:'
  assert_contains "$OUT" 'SHA256:'
  assert_contains "$OUT" 'Formula:'
  assert_contains "$OUT" 'Next:'
}

# Wrap a fixture script and log each invocation outside its Git working tree.
_sandshell_track_release_script() {
  mv "$1/scripts/$2" "$1/scripts/$2.original"
  cat > "$1/scripts/$2" << 'INNER_EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_TMP/${0##*/}.calls"
exec "$0.original" "$@"
INNER_EOF
  chmod +x "$1/scripts/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "Track $2 calls" || assert_fail 'fixture instrumentation commit failed'
  assert_eq '' "$(git -C "$1" status --porcelain)" 'instrumented fixture must be clean'
}

test_release_runs_quality_gate_exactly_once() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  _sandshell_track_release_script "$TEST_TMP/repo" check.sh
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 0 "$ERR"
  assert_file_exists "$TEST_TMP/check.sh.calls"
  assert_eq '1' "$(awk 'END {print NR}' "$TEST_TMP/check.sh.calls")" 'check.sh must run exactly once'
}

test_release_packages_exactly_once() {
  setup_test_env
  copy_release_tree "$TEST_TMP/repo"
  _sandshell_track_release_script "$TEST_TMP/repo" package.sh
  run "$TEST_TMP/repo/scripts/release.sh" 2099.12.0
  assert_rc 0 "$ERR"
  assert_file_exists "$TEST_TMP/repo/dist/sandshell-2099.12.0.tar.gz"
  assert_file_exists "$TEST_TMP/repo/dist/sandshell-2099.12.0.tar.gz.sha256"
  assert_file_exists "$TEST_TMP/package.sh.calls"
  assert_eq '1' "$(awk 'END {print NR}' "$TEST_TMP/package.sh.calls")" 'package.sh must run exactly once'
  assert_eq '2099.12.0' "$(cat "$TEST_TMP/package.sh.calls")"
}

run_tests \
  test_release_script_is_executable \
  test_release_fixture_is_clean_and_copies_working_tree \
  test_release_fixture_includes_formula_validation \
  test_release_rejects_missing_version \
  test_release_rejects_extra_arguments \
  test_release_rejects_leading_v \
  test_release_rejects_malformed_versions \
  test_release_accepts_calendar_versions \
  test_release_rejects_dirty_working_tree \
  test_release_rejects_missing_changelog_entry \
  test_release_rejects_unreleased_changelog_entry \
  test_release_valid_version_passes_preconditions \
  test_release_generates_formula_with_correct_sha \
  test_release_formula_receives_package_sha \
  test_release_formula_url_and_sha_validation \
  test_release_fails_on_quality_gate \
  test_release_outputs_compact_summary \
  test_release_runs_quality_gate_exactly_once \
  test_release_packages_exactly_once
