#!/usr/bin/env bash
# Tests for scripts/build.sh and the generated sandshell.sh artifact.
#
# Public command behavior is characterized by the other test files, which
# exercise the generated artifact. This file covers the build itself:
# determinism, freshness, stale-artifact detection, and artifact properties.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

# copy_build_tree DEST — copy scripts/build.sh, src/, examples/, and
# sandshell.sh into a throwaway tree so build tests never modify the real
# repository. examples/vibe.toml is a build input: the build embeds it into
# the artifact as the bundled Vibe preset.
copy_build_tree() {
  mkdir -p "$1/scripts" "$1/src" "$1/examples"
  cp "$SANDSHELL_ROOT/scripts/build.sh" "$1/scripts/build.sh"
  chmod +x "$1/scripts/build.sh"
  cp "$SANDSHELL_ROOT"/src/*.sh "$1/src/"
  cp "$SANDSHELL_ROOT/examples/vibe.toml" "$1/examples/"
  cp "$SANDSHELL_SH" "$1/sandshell.sh"
}

test_build_check_passes_on_committed_artifact() {
  setup_test_env
  before=$(cksum <"$SANDSHELL_SH")
  run "$SANDSHELL_ROOT/scripts/build.sh" --check
  assert_rc 0
  assert_contains "$OUT" 'up to date'
  # The build script also runs under Zsh.
  run zsh "$SANDSHELL_ROOT/scripts/build.sh" --check
  assert_rc 0
  # --check never modifies the committed artifact.
  assert_eq "$before" "$(cksum <"$SANDSHELL_SH")"
}

test_build_regenerates_byte_identical_artifact() {
  setup_test_env
  copy_build_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/build.sh"
  assert_rc 0
  assert_file_eq "$SANDSHELL_SH" "$TEST_TMP/repo/sandshell.sh"
  # Running the build twice produces byte-identical output.
  run "$TEST_TMP/repo/scripts/build.sh"
  assert_rc 0
  assert_file_eq "$SANDSHELL_SH" "$TEST_TMP/repo/sandshell.sh"
}

test_build_check_fails_when_stale_without_modifying_artifact() {
  setup_test_env
  copy_build_tree "$TEST_TMP/repo"
  before=$(cksum <"$TEST_TMP/repo/sandshell.sh")
  printf '\n# stale marker\n' >>"$TEST_TMP/repo/src/core.sh"
  run "$TEST_TMP/repo/scripts/build.sh" --check
  assert_rc 1
  assert_contains "$ERR" 'stale'
  # The committed artifact is untouched and no temporary build file remains.
  assert_eq "$before" "$(cksum <"$TEST_TMP/repo/sandshell.sh")"
  assert_eq '' "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'sandshell-build.*' 2>/dev/null)"
}

test_build_check_detects_stale_embedded_vibe_preset() {
  setup_test_env
  copy_build_tree "$TEST_TMP/repo"
  before=$(cksum <"$TEST_TMP/repo/sandshell.sh")
  # Changing the canonical Vibe preset must make the committed artifact stale.
  printf '\n# preset change\n' >>"$TEST_TMP/repo/examples/vibe.toml"
  run "$TEST_TMP/repo/scripts/build.sh" --check
  assert_rc 1
  assert_contains "$ERR" 'stale'
  assert_eq "$before" "$(cksum <"$TEST_TMP/repo/sandshell.sh")"
  # Regenerating embeds the changed preset.
  run "$TEST_TMP/repo/scripts/build.sh"
  assert_rc 0
  assert_contains "$(cat "$TEST_TMP/repo/sandshell.sh")" '# preset change'
}

test_build_fails_fast_on_missing_vibe_preset() {
  setup_test_env
  copy_build_tree "$TEST_TMP/repo"
  rm "$TEST_TMP/repo/examples/vibe.toml"
  before=$(cksum <"$TEST_TMP/repo/sandshell.sh")
  run "$TEST_TMP/repo/scripts/build.sh"
  assert_rc 1
  assert_contains "$ERR" 'missing Vibe preset'
  assert_eq "$before" "$(cksum <"$TEST_TMP/repo/sandshell.sh")"
}

test_build_fails_fast_on_missing_module() {
  setup_test_env
  copy_build_tree "$TEST_TMP/repo"
  rm "$TEST_TMP/repo/src/commands.sh"
  before=$(cksum <"$TEST_TMP/repo/sandshell.sh")
  run "$TEST_TMP/repo/scripts/build.sh"
  assert_rc 1
  assert_contains "$ERR" 'missing source module'
  assert_eq "$before" "$(cksum <"$TEST_TMP/repo/sandshell.sh")"
  assert_eq '' "$(find "$TEST_TMP/repo" -maxdepth 1 -name '.sandshell.sh.*' 2>/dev/null)"
}

test_build_artifact_has_generated_header() {
  setup_test_env
  header=$(head -n 2 "$SANDSHELL_SH")
  assert_contains "$header" 'generated file'
  assert_contains "$header" 'Do not edit'
}

test_build_artifact_is_standalone() {
  setup_test_env
  # The artifact must not source anything; it is self-contained.
  if grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$SANDSHELL_SH"; then
    assert_fail 'artifact sources external files'
  fi
}

test_build_artifact_is_valid_in_bash_and_zsh() {
  setup_test_env
  run bash -n "$SANDSHELL_SH"
  assert_rc 0
  run zsh -n "$SANDSHELL_SH"
  assert_rc 0
  run bash -c '. "$1" && sbxcmd' sh "$SANDSHELL_SH"
  assert_rc 0
  assert_contains "$OUT" 'Docker Sandbox helpers:'
  run zsh -c '. "$1" && sbxcmd' sh "$SANDSHELL_SH"
  assert_rc 0
  assert_contains "$OUT" 'Docker Sandbox helpers:'
}

run_tests \
  test_build_check_passes_on_committed_artifact \
  test_build_regenerates_byte_identical_artifact \
  test_build_check_fails_when_stale_without_modifying_artifact \
  test_build_check_detects_stale_embedded_vibe_preset \
  test_build_fails_fast_on_missing_vibe_preset \
  test_build_fails_fast_on_missing_module \
  test_build_artifact_has_generated_header \
  test_build_artifact_is_standalone \
  test_build_artifact_is_valid_in_bash_and_zsh
