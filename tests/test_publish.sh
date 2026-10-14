#!/usr/bin/env bash
# Publish contracts: disposable repositories, fake remote Git and GitHub only.
_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

setup_publish() {
  setup_test_env
  export PUBLISH_REPO="$TEST_TMP/repo with spaces"
  export REAL_GIT
  REAL_GIT=$(command -v git)
  mkdir -p "$PUBLISH_REPO/scripts" "$PUBLISH_REPO/dist" "$PUBLISH_REPO/Formula"
  cp "$SANDSHELL_ROOT/scripts/publish.sh" "$PUBLISH_REPO/scripts/" || assert_fail 'missing publish.sh'
  chmod +x "$PUBLISH_REPO/scripts/publish.sh"
  printf 'dist/\n' >"$PUBLISH_REPO/.gitignore"
  printf '## [2099.12.0] - 2099.12.01\n' >"$PUBLISH_REPO/CHANGELOG.md"
  printf 'fixture package\n' >"$PUBLISH_REPO/dist/sandshell-2099.12.0.tar.gz"
  if command -v sha256sum >/dev/null 2>&1; then
    package_sha=$(sha256sum "$PUBLISH_REPO/dist/sandshell-2099.12.0.tar.gz" | awk '{print $1}')
  else
    package_sha=$(shasum -a 256 "$PUBLISH_REPO/dist/sandshell-2099.12.0.tar.gz" | awk '{print $1}')
  fi
  printf '%s  sandshell-2099.12.0.tar.gz\n' "$package_sha" >"$PUBLISH_REPO/dist/sandshell-2099.12.0.tar.gz.sha256"
  printf '  url "https://github.com/dergrossedev/homebrew-sandshell/releases/download/v2099.12.0/sandshell-2099.12.0.tar.gz"\n  sha256 "%s"\n' "$package_sha" >"$PUBLISH_REPO/Formula/sandshell.rb"
  make_git_repo "$PUBLISH_REPO"
  git -C "$PUBLISH_REPO" add .
  git -C "$PUBLISH_REPO" commit -qm 'Prepare fixture release'
  export REMOTE_MAIN
  REMOTE_MAIN=$(git -C "$PUBLISH_REPO" rev-parse HEAD)
  # Delegate only local commands. Remote commands cannot reach the network.
  cat >"$TEST_TMP/bin/git" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_TMP/git-calls"
case $1 in
  fetch)
    [ "$*" = 'fetch origin main' ] || exit 99
    [ ! -f "$TEST_TMP/fail-fetch" ] || exit 1
    exec "$REAL_GIT" update-ref refs/remotes/origin/main "$REMOTE_MAIN" ;;
  ls-remote)
    [ "$*" = 'ls-remote --exit-code --tags origin refs/tags/v2099.12.0' ] || exit 99
    [ ! -f "$TEST_TMP/fail-remote" ] || exit 1
    [ -f "$TEST_TMP/remote-tag" ] || exit 2
    printf '%s\trefs/tags/v2099.12.0\n' "$REMOTE_MAIN" ;;
  push)
    [ "$*" = 'push origin v2099.12.0' ] || exit 99
    [ ! -f "$TEST_TMP/fail-push" ] || exit 1
    "$REAL_GIT" rev-parse refs/tags/v2099.12.0 >"$TEST_TMP/remote-tag" ;;
  *) exec "$REAL_GIT" "$@" ;;
esac
MOCK
  cat >"$TEST_TMP/bin/gh" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_TMP/gh-calls"
case "$1 $2" in
  'auth status') [ ! -f "$TEST_TMP/fail-auth" ] ;;
  'api repos/dergrossedev/homebrew-sandshell/releases')
    [ ! -f "$TEST_TMP/fail-releases" ] || exit 1
    if [ -f "$TEST_TMP/existing-release" ]; then printf 'v2099.12.0\n'; fi ;;
  'release create')
    [ -f "$TEST_TMP/remote-tag" ] || exit 99
    [ ! -f "$TEST_TMP/fail-release" ] || exit 1
    printf 'https://github.com/dergrossedev/homebrew-sandshell/releases/tag/v2099.12.0\n' ;;
  *) exit 99 ;;
esac
MOCK
  chmod +x "$TEST_TMP/bin/git" "$TEST_TMP/bin/gh"
}

publish() { run "$PUBLISH_REPO/scripts/publish.sh" "$@"; }

assert_no_publish() {
  assert_file_missing "$TEST_TMP/remote-tag"
  assert_not_contains "$(cat "$TEST_TMP/git-calls" 2>/dev/null)" 'tag -a'
  assert_not_contains "$(cat "$TEST_TMP/git-calls" 2>/dev/null)" 'push '
  assert_not_contains "$(cat "$TEST_TMP/gh-calls" 2>/dev/null)" 'release create'
}

test_publish_invalid_versions() {
  setup_publish
  publish
  assert_rc 2
  publish 2099.12.0 extra
  assert_rc 2
  before=$(tree_fingerprint "$PUBLISH_REPO")
  for version in '' 0.2.0 26.10.0 2026.01.0 2026.0.0 2026.13.0 v2026.10.0 2026.10 2026.10.0-beta 2026.10.0+build 2026.10.00 2099.12.0.1 abc; do
    publish "$version"
    assert_rc 2
  done
  assert_eq "$before" "$(tree_fingerprint "$PUBLISH_REPO")" 'invalid versions must not mutate the repository'
  assert_no_publish
  assert_file_missing "$TEST_TMP/git-calls"
  assert_file_missing "$TEST_TMP/gh-calls"
}

test_publish_calendar_versions() {
  setup_publish
  for version in 2026.10.0 2026.10.1 2027.1.0; do
    publish "$version"
    assert_rc 1
    assert_contains "$ERR" "missing required file: dist/sandshell-$version.tar.gz"
    assert_no_publish
  done
}

test_publish_missing_tools() {
  setup_publish
  mkdir "$TEST_TMP/tools"
  ln -s "$(command -v bash)" "$TEST_TMP/tools/bash"
  # Invoke Bash directly so a missing env utility cannot mask the result.
  run env PATH="$TEST_TMP/tools" bash "$PUBLISH_REPO/scripts/publish.sh" 2099.12.0
  assert_rc 127
  assert_contains "$ERR" 'required executable not found: git'
  ln -s "$REAL_GIT" "$TEST_TMP/tools/git"
  run env PATH="$TEST_TMP/tools" bash "$PUBLISH_REPO/scripts/publish.sh" 2099.12.0
  assert_rc 127
  assert_contains "$ERR" 'required executable not found: gh'
  assert_no_publish
}

test_publish_dirty_tree() {
  setup_publish
  printf 'dirty\n' >>"$PUBLISH_REPO/CHANGELOG.md"
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'working tree is dirty'
  assert_no_publish
}

test_publish_wrong_branch() {
  setup_publish
  git -C "$PUBLISH_REPO" checkout -qb feature
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'main'
  assert_no_publish
}

test_publish_head_differs() {
  setup_publish
  git -C "$PUBLISH_REPO" commit -q --allow-empty -m 'Unpushed commit'
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'HEAD differs from origin/main'
  assert_contains "$ERR" 'git push'
  assert_no_publish
}

test_publish_existing_local_tag() {
  setup_publish
  git -C "$PUBLISH_REPO" tag v2099.12.0
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'already exists locally'
  assert_no_publish
}

test_publish_existing_remote_tag() {
  setup_publish
  touch "$TEST_TMP/remote-tag"
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'already exists on origin'
  assert_eq '' "$(git -C "$PUBLISH_REPO" tag -l)"
  assert_not_contains "$(cat "$TEST_TMP/gh-calls")" 'release create'
}

test_publish_existing_release() {
  setup_publish
  touch "$TEST_TMP/existing-release"
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'Release v2099.12.0 already exists'
  assert_no_publish
}

test_publish_sha_mismatch() {
  setup_publish
  printf 'corrupt\n' >>"$PUBLISH_REPO/dist/sandshell-2099.12.0.tar.gz"
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'checksum'
  assert_no_publish
}

test_publish_formula_mismatch() {
  setup_publish
  printf '  sha256 "%064d"\n' 0 >"$TEST_TMP/wrong-sha"
  sed '/sha256/d' "$PUBLISH_REPO/Formula/sandshell.rb" >"$TEST_TMP/formula"
  cat "$TEST_TMP/formula" "$TEST_TMP/wrong-sha" >"$PUBLISH_REPO/Formula/sandshell.rb"
  git -C "$PUBLISH_REPO" add .
  git -C "$PUBLISH_REPO" commit -qm 'Wrong formula SHA'
  REMOTE_MAIN=$(git -C "$PUBLISH_REPO" rev-parse HEAD)
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'Formula/sandshell.rb'
  assert_no_publish
}

test_publish_formula_wrong_url() {
  setup_publish
  printf '  url "https://github.com/dergrossedev/homebrew-sandshell/archive/refs/tags/v2099.12.0.tar.gz"\n  sha256 "%s"\n' "$package_sha" >"$PUBLISH_REPO/Formula/sandshell.rb"
  git -C "$PUBLISH_REPO" add .
  git -C "$PUBLISH_REPO" commit -qm 'Wrong formula URL'
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'Formula/sandshell.rb'
  assert_no_publish
}

test_publish_missing_assets() {
  for asset in dist/sandshell-2099.12.0.tar.gz dist/sandshell-2099.12.0.tar.gz.sha256 Formula/sandshell.rb CHANGELOG.md; do
    setup_publish
    rm "$PUBLISH_REPO/$asset"
    git -C "$PUBLISH_REPO" add -u
    git -C "$PUBLISH_REPO" diff --cached --quiet || git -C "$PUBLISH_REPO" commit -qm 'Remove asset'
    publish 2099.12.0
    assert_rc 1
    assert_contains "$ERR" "missing required file: $asset"
    assert_no_publish
  done
}

test_publish_undated_changelog() {
  setup_publish
  printf '## [2099.12.0] - Unreleased\n' >"$PUBLISH_REPO/CHANGELOG.md"
  git -C "$PUBLISH_REPO" add .
  git -C "$PUBLISH_REPO" commit -qm 'Undated notes'
  publish 2099.12.0
  assert_rc 1
  assert_contains "$ERR" 'dated'
  assert_no_publish
}

test_publish_lookup_failures() {
  for failure in auth fetch remote releases; do
    setup_publish
    touch "$TEST_TMP/fail-$failure"
    publish 2099.12.0
    assert_rc 1
    assert_no_publish
  done
}

test_publish_success() {
  setup_publish
  publish 2099.12.0
  assert_rc 0
  assert_eq 'tag' "$(git -C "$PUBLISH_REPO" cat-file -t refs/tags/v2099.12.0)"
  assert_eq 'v2099.12.0' "$(git -C "$PUBLISH_REPO" for-each-ref --format='%(contents:subject)' refs/tags/v2099.12.0)"
  assert_eq "$(git -C "$PUBLISH_REPO" rev-parse refs/tags/v2099.12.0)" "$(cat "$TEST_TMP/remote-tag")"
  assert_contains "$(cat "$TEST_TMP/git-calls")" 'fetch origin main'
  assert_contains "$(cat "$TEST_TMP/git-calls")" 'push origin v2099.12.0'
  assert_contains "$(cat "$TEST_TMP/gh-calls")" 'release create v2099.12.0 dist/sandshell-2099.12.0.tar.gz dist/sandshell-2099.12.0.tar.gz.sha256 --repo dergrossedev/homebrew-sandshell --verify-tag --title v2099.12.0 --generate-notes'
  assert_contains "$OUT" 'Published v2099.12.0'
  assert_contains "$OUT" 'Release: https://github.com/dergrossedev/homebrew-sandshell/releases/tag/v2099.12.0'
}

test_publish_release_failure() {
  setup_publish
  touch "$TEST_TMP/fail-release"
  publish 2099.12.0
  assert_rc 1
  assert_file_exists "$TEST_TMP/remote-tag"
  assert_eq "$(git -C "$PUBLISH_REPO" rev-parse refs/tags/v2099.12.0)" "$(cat "$TEST_TMP/remote-tag")"
  assert_contains "$ERR" 'gh release create v2099.12.0 dist/sandshell-2099.12.0.tar.gz dist/sandshell-2099.12.0.tar.gz.sha256 --repo dergrossedev/homebrew-sandshell --verify-tag --title "v2099.12.0" --generate-notes'
  assert_not_contains "$OUT" 'Published'
}

test_publish_push_failure() {
  setup_publish
  touch "$TEST_TMP/fail-push"
  publish 2099.12.0
  assert_rc 1
  assert_eq 'v2099.12.0' "$(git -C "$PUBLISH_REPO" tag -l)"
  assert_contains "$ERR" 'git push origin v2099.12.0'
  assert_file_missing "$TEST_TMP/remote-tag"
  assert_not_contains "$(cat "$TEST_TMP/gh-calls")" 'release create'
}

run_tests \
  test_publish_invalid_versions test_publish_calendar_versions \
  test_publish_missing_tools test_publish_dirty_tree \
  test_publish_wrong_branch test_publish_head_differs \
  test_publish_existing_local_tag test_publish_existing_remote_tag \
  test_publish_existing_release test_publish_sha_mismatch \
  test_publish_formula_mismatch test_publish_formula_wrong_url test_publish_missing_assets \
  test_publish_undated_changelog test_publish_lookup_failures \
  test_publish_success test_publish_release_failure test_publish_push_failure
