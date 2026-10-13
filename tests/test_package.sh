#!/usr/bin/env bash
# Tests for scripts/package.sh, the release archive builder.
#
# Every test packages a throwaway copy of the repository tree, so the real
# working tree and its real dist/ directory are never touched.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

# copy_package_tree DEST — copy the files scripts/package.sh needs into a
# throwaway tree: the build inputs (src/, sandshell.sh, scripts/build.sh),
# the packaging script itself, and the public release assets.
copy_package_tree() {
  mkdir -p "$1/scripts" "$1/src" "$1/completions" "$1/examples"
  cp "$SANDSHELL_ROOT/scripts/build.sh" "$SANDSHELL_ROOT/scripts/package.sh" "$1/scripts/"
  chmod +x "$1/scripts/build.sh" "$1/scripts/package.sh"
  cp "$SANDSHELL_ROOT"/src/*.sh "$1/src/"
  cp "$SANDSHELL_SH" "$1/sandshell.sh"
  cp "$SANDSHELL_ROOT/completions/sandshell.bash" "$SANDSHELL_ROOT/completions/_sandshell" "$1/completions/"
  cp "$SANDSHELL_ROOT/examples/vibe.toml" "$1/examples/"
  cp "$SANDSHELL_ROOT/README.md" "$SANDSHELL_ROOT/LICENSE" "$1/"
}

# tree_fingerprint_no_dist — content+layout fingerprint of a copied tree,
# excluding the generated dist/ directory.
tree_fingerprint_no_dist() {
  (cd "$1" && find . -name dist -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -f "$f" ]; then
      printf '%s ' "$f"
      cksum <"$f"
    else
      printf '%s\n' "$f"
    fi
  done)
}

# archive_members ARCHIVE — sorted member list, one per line.
archive_members() {
  tar -tzf "$1" | LC_ALL=C sort
}

# archive_sha256 ARCHIVE — recompute the archive checksum.
archive_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

test_package_script_is_executable() {
  setup_test_env
  [ -x "$SANDSHELL_ROOT/scripts/package.sh" ] || assert_fail 'scripts/package.sh is not executable'
}

test_package_valid_version_succeeds() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/package.sh" 0.1.0
  assert_rc 0
  assert_contains "$OUT" 'sandshell-0.1.0.tar.gz'
  assert_file_exists "$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz"
  assert_file_exists "$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz.sha256"
}

test_package_usage_errors_exit_2() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/package.sh"
  assert_rc 2
  assert_contains "$ERR" 'usage:'
  run "$TEST_TMP/repo/scripts/package.sh" --bogus
  assert_rc 2
  run "$TEST_TMP/repo/scripts/package.sh" 0.1.0 extra
  assert_rc 2
  run "$TEST_TMP/repo/scripts/package.sh" --help
  assert_rc 0
  assert_contains "$OUT" 'usage:'
  assert_file_missing "$TEST_TMP/repo/dist"
}

test_package_rejects_invalid_versions() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  for v in '1.0.0' '0.1' '0.1.0.1' 'v0.1.0' 'abc' '0.x.0' '0.1.0-rc.1' '0.1.2.3' ''; do
    run "$TEST_TMP/repo/scripts/package.sh" "$v"
    assert_rc 2 "version [$v] must be rejected"
    assert_contains "$ERR" 'invalid version'
  done
  assert_file_missing "$TEST_TMP/repo/dist"
}

test_package_refuses_stale_artifact() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  printf '\n# stale marker\n' >>"$TEST_TMP/repo/src/core.sh"
  run "$TEST_TMP/repo/scripts/package.sh" 0.1.0
  assert_rc 1
  assert_contains "$ERR" './scripts/build.sh'
  assert_file_missing "$TEST_TMP/repo/dist"
}

test_package_archive_contains_exactly_public_assets() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/package.sh" 0.1.0
  assert_rc 0
  members=$(archive_members "$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz")
  expected='sandshell-0.1.0/LICENSE
sandshell-0.1.0/README.md
sandshell-0.1.0/completions/_sandshell
sandshell-0.1.0/completions/sandshell.bash
sandshell-0.1.0/examples/vibe.toml
sandshell-0.1.0/sandshell.sh'
  assert_eq "$expected" "$members"
  # One versioned top-level directory only.
  outside=$(printf '%s\n' "$members" | grep -v '^sandshell-0\.1\.0/' || true)
  assert_eq '' "$outside"
  # No development or repository files.
  for excluded in 'src/' 'tests/' 'scripts/' '.github/' 'AGENTS.md' 'CONTRIBUTING.md' 'CHANGELOG.md' 'RELEASING.md' '.git'; do
    assert_not_contains "$members" "$excluded"
  done
}

test_package_archive_files_match_repository() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/package.sh" 0.1.0
  assert_rc 0
  mkdir "$TEST_TMP/extract"
  tar -xzf "$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz" -C "$TEST_TMP/extract"
  assert_file_eq "$SANDSHELL_SH" "$TEST_TMP/extract/sandshell-0.1.0/sandshell.sh"
  assert_file_eq "$SANDSHELL_ROOT/README.md" "$TEST_TMP/extract/sandshell-0.1.0/README.md"
  assert_file_eq "$SANDSHELL_ROOT/LICENSE" "$TEST_TMP/extract/sandshell-0.1.0/LICENSE"
  assert_file_eq "$SANDSHELL_ROOT/completions/sandshell.bash" "$TEST_TMP/extract/sandshell-0.1.0/completions/sandshell.bash"
  assert_file_eq "$SANDSHELL_ROOT/completions/_sandshell" "$TEST_TMP/extract/sandshell-0.1.0/completions/_sandshell"
  assert_file_eq "$SANDSHELL_ROOT/examples/vibe.toml" "$TEST_TMP/extract/sandshell-0.1.0/examples/vibe.toml"
}

test_package_example_matches_embedded_runtime_preset() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/package.sh" 0.1.0
  assert_rc 0
  mkdir "$TEST_TMP/extract"
  tar -xzf "$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz" -C "$TEST_TMP/extract"
  # The packaged example (installed by Homebrew under pkgshare) and the
  # preset embedded in the packaged runtime cannot drift: both come from the
  # one canonical examples/vibe.toml.
  run bash -c '. "$1" && _sbx_vibe_default_config' sh \
    "$TEST_TMP/extract/sandshell-0.1.0/sandshell.sh"
  assert_rc 0
  assert_eq "$(cat "$TEST_TMP/extract/sandshell-0.1.0/examples/vibe.toml")" "$OUT"
}

test_package_sha256_file_matches_archive() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  run "$TEST_TMP/repo/scripts/package.sh" 0.1.0
  assert_rc 0
  archive="$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz"
  recorded=$(cut -d' ' -f1 "$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz.sha256")
  assert_eq "$(archive_sha256 "$archive")" "$recorded"
  # The checksum file references the archive by basename.
  assert_contains "$(cat "$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz.sha256")" 'sandshell-0.1.0.tar.gz'
}

test_package_is_deterministic() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo-a"
  copy_package_tree "$TEST_TMP/repo-b"
  run "$TEST_TMP/repo-a/scripts/package.sh" 0.1.0
  assert_rc 0
  run "$TEST_TMP/repo-b/scripts/package.sh" 0.1.0
  assert_rc 0
  assert_file_eq "$TEST_TMP/repo-a/dist/sandshell-0.1.0.tar.gz" "$TEST_TMP/repo-b/dist/sandshell-0.1.0.tar.gz"
  assert_file_eq "$TEST_TMP/repo-a/dist/sandshell-0.1.0.tar.gz.sha256" "$TEST_TMP/repo-b/dist/sandshell-0.1.0.tar.gz.sha256"
  # Repeated packaging in the same tree is byte-identical too.
  run "$TEST_TMP/repo-a/scripts/package.sh" 0.1.0
  assert_rc 0
  assert_file_eq "$TEST_TMP/repo-a/dist/sandshell-0.1.0.tar.gz" "$TEST_TMP/repo-b/dist/sandshell-0.1.0.tar.gz"
}

test_package_works_from_path_with_spaces() {
  setup_test_env
  tree="$TEST_TMP/repo with spaces"
  copy_package_tree "$tree"
  run "$tree/scripts/package.sh" 0.1.0
  assert_rc 0
  assert_file_exists "$tree/dist/sandshell-0.1.0.tar.gz"
  # No absolute path is embedded: the archive is identical to one built
  # from a plain path.
  copy_package_tree "$TEST_TMP/repo-plain"
  run "$TEST_TMP/repo-plain/scripts/package.sh" 0.1.0
  assert_rc 0
  assert_file_eq "$TEST_TMP/repo-plain/dist/sandshell-0.1.0.tar.gz" "$tree/dist/sandshell-0.1.0.tar.gz"
}

test_package_modifies_only_dist() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  before=$(tree_fingerprint_no_dist "$TEST_TMP/repo")
  run "$TEST_TMP/repo/scripts/package.sh" 0.1.0
  assert_rc 0
  after=$(tree_fingerprint_no_dist "$TEST_TMP/repo")
  assert_eq "$before" "$after"
}

test_package_runs_under_zsh() {
  setup_test_env
  copy_package_tree "$TEST_TMP/repo"
  run zsh "$TEST_TMP/repo/scripts/package.sh" 0.1.0
  assert_rc 0
  assert_file_exists "$TEST_TMP/repo/dist/sandshell-0.1.0.tar.gz"
}

test_dist_is_gitignored() {
  setup_test_env
  if git -C "$SANDSHELL_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    run git -C "$SANDSHELL_ROOT" check-ignore dist/sandshell-0.1.0.tar.gz
    assert_rc 0
  else
    assert_contains "$(cat "$SANDSHELL_ROOT/.gitignore")" 'dist/'
  fi
}

run_tests \
  test_package_script_is_executable \
  test_package_valid_version_succeeds \
  test_package_usage_errors_exit_2 \
  test_package_rejects_invalid_versions \
  test_package_refuses_stale_artifact \
  test_package_archive_contains_exactly_public_assets \
  test_package_archive_files_match_repository \
  test_package_example_matches_embedded_runtime_preset \
  test_package_sha256_file_matches_archive \
  test_package_is_deterministic \
  test_package_works_from_path_with_spaces \
  test_package_modifies_only_dist \
  test_package_runs_under_zsh \
  test_dist_is_gitignored
