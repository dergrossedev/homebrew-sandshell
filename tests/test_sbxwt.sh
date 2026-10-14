#!/usr/bin/env bash
# Characterization tests for sbxwt (host Git worktrees paired with sandboxes).
#
# Git operations run against real throwaway repositories created under the
# test's temporary directory; sbx is mocked, so no real Docker/SBX state is
# touched. Tests of destructive operations replace confirmation with an
# explicit deterministic decision; terminal interaction itself is not tested.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

# --- sbxwt fixtures -----------------------------------------------------------

# wt_repo — create the throwaway repo and cd into it. Sets REPO.
wt_repo() {
  REPO="$TEST_TMP/repos/myrepo"
  make_git_repo "$REPO"
  cd "$REPO" || exit 1
}

# wt_create BRANCH [ARGS...] — run `sbxwt create` and set WT/SANDBOX from its
# output. Fails the test if creation does not succeed.
wt_create() {
  local branch=$1
  shift
  run sbxwt create "$branch" "$@"
  assert_rc 0
  SANDBOX=$(printf '%s\n' "$OUT" | sed -n 's/^Sandbox:  //p')
  WT=$(printf '%s\n' "$OUT" | sed -n 's/^Worktree: //p')
}

# wt_feature_change MESSAGE — modify and commit directly in the feature worktree.
wt_feature_change() {
  echo "$1" >"$WT/feature-file.txt"
  git -C "$WT" add -A
  git -C "$WT" commit -m "$1" >/dev/null
}

# --- help / dispatch ----------------------------------------------------------

test_sbxwt_help() {
  setup_test_env
  run sbxwt --help
  assert_rc 0
  assert_contains "$OUT" 'sbxwt create BRANCH [-a AGENT] [-s SIZE] [--base BRANCH] [--env-file FILE]'
  assert_contains "$OUT" 'sbxwt ls'
  assert_contains "$OUT" 'sbxwt commit SANDBOX [-m MESSAGE]'
  assert_contains "$OUT" 'sbxwt merge SANDBOX [--into BRANCH]'
  assert_contains "$OUT" 'sbxwt done SANDBOX'
  assert_contains "$OUT" "Metadata: $HOME/.config/sandshell/worktrees/<sandbox>.meta"
}

test_sbxwt_rejects_unknown_command() {
  setup_test_env
  run sbxwt frobnicate
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: unknown command: frobnicate'
  assert_contains "$ERR" 'Run sbxwt --help for usage.'
}

test_sbxwt_subcommand_help_shows_usage() {
  setup_test_env
  for sub in create ls commit merge 'done'; do
    run sbxwt "$sub" --help
    assert_rc 0 "subcommand: $sub"
    assert_contains "$OUT" 'Usage:' "subcommand: $sub"
    run sbxwt "$sub" -h
    assert_rc 0 "subcommand: $sub"
    assert_contains "$OUT" 'Usage:' "subcommand: $sub"
  done
}

test_sbxwt_subcommand_help_does_not_perform_the_operation() {
  setup_test_env
  wt_repo
  wt_create feature
  run sbxwt 'done' --help
  assert_rc 0
  # Nothing was removed: the help flag never reaches the destructive path.
  assert_eq "$SANDBOX" "$(mock_sandbox_names)"
  assert_dir_exists "$WT"
  assert_file_exists "$HOME/.config/sandshell/worktrees/$SANDBOX.meta"
}

test_sbxwt_missing_git_returns_127() {
  setup_test_env
  hide_git
  run sbxwt ls
  assert_rc 127
  assert_contains "$ERR" 'sbxwt: git not found'
}

# --- create -------------------------------------------------------------------

test_sbxwt_create_requires_git_worktree() {
  setup_test_env
  cd "$TEST_TMP" || exit 1
  run sbxwt create feature
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: current directory is not inside a Git working tree'
}

test_sbxwt_create_validates_arguments() {
  setup_test_env
  wt_repo
  run sbxwt create
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt create BRANCH'
  run sbxwt create 'bad..branch'
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: invalid branch name: bad..branch'
  run sbxwt create feature -a nosuch
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: unsupported agent: nosuch'
  run sbxwt create feature -s huge
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: invalid size: huge'
  run sbxwt create feature --bogus
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: unknown option: --bogus'
  run sbxwt create feature -a
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: missing value for -a'
  run sbxwt create main
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: worktree branch must differ from its base branch'
  run sbxwt create feature --base nosuch
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: base must be an existing local branch: nosuch'
  run sbxwt create feature --env-file "$TEST_TMP/nope.env"
  assert_rc 2
  assert_contains "$ERR" "sbxwt: env file not readable: $TEST_TMP/nope.env"
  # Nothing was created.
  assert_eq 0 "$(mock_sandbox_count)"
  assert_file_missing "$REPO.worktrees"
}

test_sbxwt_create_detached_head_requires_base() {
  setup_test_env
  wt_repo
  git -C "$REPO" checkout --detach HEAD >/dev/null 2>&1
  run sbxwt create feature
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: detached HEAD; specify --base BRANCH'
  run sbxwt create feature --base main
  assert_rc 0
  assert_eq 'feature' "$(git -C "$REPO.worktrees/feature" branch --show-current)"
}

test_sbxwt_create_creates_worktree_and_sandbox() {
  setup_test_env
  wt_repo
  wt_create feature
  assert_match '^sbx-myrepo-feature-opencode-[0-9a-f]{8}$' "$SANDBOX"
  assert_eq "$REPO.worktrees/feature" "$WT"
  # git worktree add also prints a "HEAD is now at ..." line to stdout; the
  # sandshell summary lines are what we pin down.
  assert_contains "$OUT" "Worktree: $WT"
  assert_contains "$OUT" 'Branch:   feature'
  assert_contains "$OUT" "Sandbox:  $SANDBOX"
  # The worktree is registered and on the new branch.
  assert_eq 'feature' "$(git -C "$WT" branch --show-current)"
  git -C "$REPO" worktree list --porcelain | grep -qF "worktree $WT" ||
    assert_fail "worktree not registered: $WT"
  # The sandbox was created through sbxc with the expected arguments.
  assert_contains "$(mock_calls)" "create --name $SANDBOX"
  assert_contains "$(mock_calls)" '--cpus 2 --memory 2g'
  assert_contains "$(mock_calls)" " opencode $WT"
  assert_eq 'stopped' "$(mock_sandbox_status "$SANDBOX")"
  # Metadata records repository/worktree/branch/base_branch, mode 0600.
  printf 'repository\t%s\nworktree\t%s\nbranch\tfeature\nbase_branch\tmain\n' \
    "$REPO" "$WT" >"$TEST_TMP/.expected-meta"
  assert_file_eq "$TEST_TMP/.expected-meta" "$HOME/.config/sandshell/worktrees/$SANDBOX.meta"
  assert_eq 600 "$(file_mode "$HOME/.config/sandshell/worktrees/$SANDBOX.meta")"
  # sbxc initialized per-sandbox skill state.
  assert_file_exists "$HOME/.config/sandshell/skills/$SANDBOX.skills"
  # The summary ends with the exact command to start the sandbox.
  assert_contains "$ERR" "Resume with: sbxr $SANDBOX"
}

test_sbxwt_create_prints_resume_hint_exactly_once() {
  setup_test_env
  wt_repo
  wt_create feature
  # sbxwt create delegates to sbxc, which prints the same hint; the composite
  # output must not repeat it.
  count=$(printf '%s\n%s\n' "$OUT" "$ERR" | grep -c "Resume with: sbxr $SANDBOX")
  assert_eq 1 "$count"
}

test_sbxwt_create_slugifies_branch_names() {
  setup_test_env
  wt_repo
  wt_create feature/nested
  assert_eq "$REPO.worktrees/feature-nested" "$WT"
  assert_match '^sbx-myrepo-feature-nested-opencode-[0-9a-f]{8}$' "$SANDBOX"
  assert_eq 'feature/nested' "$(git -C "$WT" branch --show-current)"
}

test_sbxwt_create_from_subdirectory() {
  setup_test_env
  wt_repo
  mkdir -p "$REPO/sub"
  cd "$REPO/sub" || exit 1
  wt_create feature
  assert_eq "$REPO.worktrees/feature" "$WT"
  assert_match '^sbx-myrepo-feature-opencode-[0-9a-f]{8}$' "$SANDBOX"
}

test_sbxwt_create_uses_default_project_env() {
  setup_test_env
  wt_repo
  mkdir -p "$HOME/.config/sandshell/envs"
  echo 'DEFAULT=1' >"$HOME/.config/sandshell/envs/myrepo.env"
  wt_create feature
  assert_contains "$(mock_calls)" "--env-file $HOME/.config/sandshell/envs/myrepo.env"
}

test_sbxwt_create_explicit_env_wins() {
  setup_test_env
  wt_repo
  mkdir -p "$HOME/.config/sandshell/envs"
  echo 'DEFAULT=1' >"$HOME/.config/sandshell/envs/myrepo.env"
  echo 'CUSTOM=1' >"$TEST_TMP/custom.env"
  wt_create feature --env-file "$TEST_TMP/custom.env"
  assert_contains "$(mock_calls)" "--env-file $TEST_TMP/custom.env"
  assert_not_contains "$(mock_calls)" 'myrepo.env'
}

test_sbxwt_create_attaches_existing_branch() {
  setup_test_env
  wt_repo
  git -C "$REPO" branch existing
  git -C "$REPO" worktree add "$TEST_TMP/tmpwt" existing >/dev/null 2>&1
  echo x >"$TEST_TMP/tmpwt/f.txt"
  git -C "$TEST_TMP/tmpwt" add -A
  git -C "$TEST_TMP/tmpwt" commit -m 'existing commit' >/dev/null
  git -C "$REPO" worktree remove "$TEST_TMP/tmpwt"
  wt_create existing
  # The worktree is on the pre-existing branch, with its commit — not a fresh
  # branch created at the base.
  assert_eq 'existing commit' "$(git -C "$WT" log -1 --pretty=%s)"
  assert_eq "$(git -C "$REPO" rev-parse existing)" "$(git -C "$WT" rev-parse HEAD)"
}

test_sbxwt_create_refuses_existing_worktree_path() {
  setup_test_env
  wt_repo
  wt_create feature
  run sbxwt create feature
  assert_rc 2
  assert_contains "$ERR" "sbxwt: worktree path already exists or is unsafe: $WT"
  assert_eq 1 "$(mock_sandbox_count)"
  # A symlinked worktree root is refused too.
  REPO="$TEST_TMP/repos/otherrepo"
  make_git_repo "$REPO"
  cd "$REPO" || exit 1
  ln -s "$TEST_TMP" "$REPO.worktrees"
  run sbxwt create feature
  assert_rc 2
  assert_contains "$ERR" "sbxwt: worktree path already exists or is unsafe: $REPO.worktrees/feature"
}

test_sbxwt_create_leaves_worktree_when_sandbox_creation_fails() {
  setup_test_env
  wt_repo
  hide_sbx
  run sbxwt create feature
  assert_rc 1
  assert_contains "$ERR" 'sbxc: sbx CLI not found'
  assert_contains "$ERR" "sbxwt: sandbox creation failed; worktree was left intact at $REPO.worktrees/feature"
  assert_dir_exists "$REPO.worktrees/feature"
  assert_file_missing "$HOME/.config/sandshell/worktrees"
  assert_eq 0 "$(mock_sandbox_count)"
}

# --- ls -----------------------------------------------------------------------

test_sbxwt_ls_lists_worktrees_and_sandboxes() {
  setup_test_env
  wt_repo
  wt_create feature
  make_sandbox sbx-main claude stopped "$REPO"
  {
    printf 'BRANCH\tWORKTREE\tSANDBOX\tSTATE\n'
    printf 'main\t%s\tsbx-main\tstopped\n' "$REPO"
    printf 'feature\t%s\t%s\tstopped\n' "$WT" "$SANDBOX"
  } >"$TEST_TMP/.expected-ls"
  run sbxwt ls
  assert_rc 0
  assert_eq "$(cat "$TEST_TMP/.expected-ls")" "$OUT"
  # Same listing from inside a linked worktree.
  cd "$WT" || exit 1
  run sbxwt ls
  assert_rc 0
  assert_eq "$(cat "$TEST_TMP/.expected-ls")" "$OUT"
  # Outside a repository, and with extra arguments.
  cd "$TEST_TMP" || exit 1
  run sbxwt ls
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: current directory is not inside a Git working tree'
  run sbxwt ls extra
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt ls'
}

# --- commit -------------------------------------------------------------------

test_unexpected_confirmation_fails_fast() {
  setup_test_env
  # Keep the regression independent of the process's controlling terminal.
  _sandshell_tty_available() { return 1; }
  run _sbx_confirm sbxwt 'tripwire regression'
  assert_rc 99
  assert_eq 'TEST ERROR: unexpected confirmation: sbxwt tripwire regression' "$ERR"
}

test_sbxwt_commit_commits_after_approval() {
  setup_test_env
  wt_repo
  wt_create feature
  echo change >"$WT/file.txt"
  _sbx_confirm() {
    printf '%s\n' "$*" >"$TEST_TMP/confirmation"
    return 0
  }
  run sbxwt commit "$SANDBOX" -m 'feature work'
  assert_rc 0
  assert_eq 'sbxwt Stage all changes and commit on feature?' "$(cat "$TEST_TMP/confirmation")"
  assert_eq 'feature work' "$(git -C "$WT" log -1 --pretty=%s)"
  assert_eq '' "$(git -C "$WT" status --porcelain)"
}

test_sbxwt_commit_uses_mock_editor_without_message() {
  setup_test_env
  wt_repo
  wt_create feature
  echo change >"$WT/file.txt"
  printf '#!/bin/sh\nprintf "%%s\\n" "editor message" >"$1"\n' >"$TEST_TMP/bin/giteditor"
  chmod +x "$TEST_TMP/bin/giteditor"
  export GIT_EDITOR="$TEST_TMP/bin/giteditor"
  _sbx_confirm() { return 0; }
  run sbxwt commit "$SANDBOX"
  assert_rc 0
  assert_eq 'editor message' "$(git -C "$WT" log -1 --pretty=%s)"
}

test_sbxwt_commit_declined() {
  setup_test_env
  wt_repo
  wt_create feature
  echo change >"$WT/file.txt"
  _sbx_confirm() { return 1; }
  run sbxwt commit "$SANDBOX" -m 'feature work'
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: cancelled'
  assert_eq 'initial commit' "$(git -C "$WT" log -1 --pretty=%s)"
  assert_contains "$(git -C "$WT" status --porcelain)" 'file.txt'
}

test_sbxwt_commit_no_changes() {
  setup_test_env
  wt_repo
  wt_create feature
  run sbxwt commit "$SANDBOX" -m 'feature work'
  assert_rc 0
  assert_eq 'sbxwt: no changes to commit in feature' "$OUT"
}

test_sbxwt_commit_refuses_conflicts() {
  setup_test_env
  wt_repo
  wt_create feature
  echo one >"$WT/file.txt"
  git -C "$WT" add -A
  git -C "$WT" commit -m 'feature change' >/dev/null
  echo two >"$REPO/file.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -m 'main change' >/dev/null
  git -C "$WT" merge main >/dev/null 2>&1 || true
  run sbxwt commit "$SANDBOX" -m 'feature work'
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: resolve merge conflicts before committing'
  assert_eq 'feature change' "$(git -C "$WT" log -1 --pretty=%s)"
}

test_sbxwt_commit_usage_errors() {
  setup_test_env
  wt_repo
  wt_create feature
  run sbxwt commit
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]'
  run sbxwt commit a b c d
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]'
  run sbxwt commit "$SANDBOX" -m
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]'
  run sbxwt commit "$SANDBOX" -m ''
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]'
  run sbxwt commit "$SANDBOX" extra -m msg
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]'
  run sbxwt commit no-such -m msg
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: managed worktree metadata not found: no-such'
}

# --- merge --------------------------------------------------------------------

test_sbxwt_merge_merges_after_approval() {
  setup_test_env
  wt_repo
  wt_create feature
  wt_feature_change 'feature change'
  _sbx_confirm() {
    printf '%s\n' "$*" >"$TEST_TMP/confirmation"
    return 0
  }
  run sbxwt merge "$SANDBOX"
  assert_rc 0
  assert_eq 'sbxwt Merge feature into main?' "$(cat "$TEST_TMP/confirmation")"
  assert_contains "$OUT" 'Merge feature -> main'
  git -C "$REPO" merge-base --is-ancestor feature main ||
    assert_fail 'feature was not merged into main'
}

test_sbxwt_merge_declined() {
  setup_test_env
  wt_repo
  wt_create feature
  wt_feature_change 'feature change'
  _sbx_confirm() { return 1; }
  run sbxwt merge "$SANDBOX"
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: cancelled'
  if git -C "$REPO" merge-base --is-ancestor feature main; then
    assert_fail 'feature should not be merged into main'
  fi
}

test_sbxwt_merge_already_merged() {
  setup_test_env
  wt_repo
  wt_create feature
  run sbxwt merge "$SANDBOX"
  assert_rc 0
  assert_eq 'sbxwt: feature is already merged into main' "$OUT"
}

test_sbxwt_merge_rejects_dirty_worktrees() {
  setup_test_env
  wt_repo
  wt_create feature
  wt_feature_change 'feature change'
  echo x >"$WT/new.txt"
  run sbxwt merge "$SANDBOX"
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: source worktree has uncommitted changes; commit them first'
  rm "$WT/new.txt"
  echo y >"$REPO/new.txt"
  run sbxwt merge "$SANDBOX"
  assert_rc 1
  assert_contains "$ERR" "sbxwt: target worktree has uncommitted changes: $REPO"
  rm "$REPO/new.txt"
}

test_sbxwt_merge_into_other_branch() {
  setup_test_env
  wt_repo
  wt_create feature
  wt_feature_change 'feature change'
  git -C "$REPO" branch other
  git -C "$REPO" worktree add "$REPO.worktrees/other" other >/dev/null 2>&1
  _sbx_confirm() { return 0; }
  run sbxwt merge "$SANDBOX" --into other
  assert_rc 0
  assert_contains "$OUT" 'Merge feature -> other'
  git -C "$REPO" merge-base --is-ancestor feature other ||
    assert_fail 'feature was not merged into other'
  if git -C "$REPO" merge-base --is-ancestor feature main; then
    assert_fail 'feature should not be merged into main'
  fi
}

test_sbxwt_merge_usage_errors() {
  setup_test_env
  wt_repo
  wt_create feature
  run sbxwt merge
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]'
  run sbxwt merge a b c d
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]'
  run sbxwt merge "$SANDBOX" --into
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]'
  run sbxwt merge "$SANDBOX" --into ''
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]'
  run sbxwt merge "$SANDBOX" foo --into x
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]'
  run sbxwt merge no-such
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: managed worktree metadata not found: no-such'
  run sbxwt merge "$SANDBOX" --into feature
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: source and target branches are the same'
  run sbxwt merge "$SANDBOX" --into nosuch
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: target branch does not exist locally: nosuch'
  git -C "$REPO" branch other
  run sbxwt merge "$SANDBOX" --into other
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: target branch must be checked out in a worktree: other'
}

# --- done ---------------------------------------------------------------------

test_sbxwt_done_removes_everything_and_preserves_branch() {
  setup_test_env
  wt_repo
  wt_create feature
  wt_feature_change 'feature change'
  git -C "$REPO" merge feature >/dev/null 2>&1
  mkdir -p "$HOME/.config/sandshell/mcp"
  echo srv >"$HOME/.config/sandshell/mcp/$SANDBOX.servers"
  _sbx_confirm() {
    printf '%s\n' "$*" >"$TEST_TMP/confirmation"
    return 0
  }
  run sbxwt 'done' "$SANDBOX"
  assert_rc 0
  assert_eq 'sbxwt Remove this sandbox and host worktree?' "$(cat "$TEST_TMP/confirmation")"
  assert_contains "$OUT" "Sandbox:  $SANDBOX"
  assert_contains "$OUT" "Worktree: $WT"
  assert_contains "$OUT" 'Branch:   feature (preserved)'
  assert_contains "$OUT" 'Base:     main'
  assert_contains "$OUT" 'Removed sandbox and worktree. Branch preserved: feature'
  assert_not_contains "$ERR" 'not merged into'
  assert_eq '' "$(mock_sandbox_names)"
  assert_contains "$(mock_calls)" "rm --force $SANDBOX"
  assert_file_missing "$WT"
  if git -C "$REPO" worktree list --porcelain | grep -qF "$WT"; then
    assert_fail "worktree still registered: $WT"
  fi
  git_repo_has_branch "$REPO" feature || assert_fail 'branch feature was deleted'
  assert_file_missing "$HOME/.config/sandshell/worktrees/$SANDBOX.meta"
  assert_file_missing "$HOME/.config/sandshell/mcp/$SANDBOX.servers"
  assert_file_missing "$HOME/.config/sandshell/skills/$SANDBOX.skills"
}

test_sbxwt_done_cleans_sandbox_preset_metadata() {
  setup_test_env
  wt_repo
  wt_create feature -a opencode-ollama
  assert_file_exists "$HOME/.config/sandshell/sandboxes/$SANDBOX.meta"
  _sbx_confirm() { return 0; }
  run sbxwt 'done' "$SANDBOX"
  assert_rc 0
  assert_file_missing "$HOME/.config/sandshell/sandboxes/$SANDBOX.meta"
  assert_file_missing "$HOME/.config/sandshell/worktrees/$SANDBOX.meta"
}

test_sbxwt_done_warns_when_unmerged() {
  setup_test_env
  wt_repo
  wt_create feature
  wt_feature_change 'feature change'
  _sbx_confirm() { return 0; }
  run sbxwt 'done' "$SANDBOX"
  assert_rc 0
  assert_contains "$ERR" 'Warning: feature is not merged into main; the branch will still be preserved.'
  assert_contains "$OUT" 'Removed sandbox and worktree. Branch preserved: feature'
  git_repo_has_branch "$REPO" feature || assert_fail 'branch feature was deleted'
  assert_eq '' "$(mock_sandbox_names)"
  assert_file_missing "$WT"
}

test_sbxwt_done_refuses_dirty_worktree() {
  setup_test_env
  wt_repo
  wt_create feature
  echo x >"$WT/new.txt"
  run sbxwt 'done' "$SANDBOX"
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: worktree has uncommitted or untracked changes; commit or remove them first'
  # Nothing was removed.
  assert_eq "$SANDBOX" "$(mock_sandbox_names)"
  assert_dir_exists "$WT"
  assert_file_exists "$HOME/.config/sandshell/worktrees/$SANDBOX.meta"
  git_repo_has_branch "$REPO" feature || assert_fail 'branch feature was deleted'
}

test_sbxwt_done_declined() {
  setup_test_env
  wt_repo
  wt_create feature
  _sbx_confirm() { return 1; }
  run sbxwt 'done' "$SANDBOX"
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: cancelled'
  assert_eq "$SANDBOX" "$(mock_sandbox_names)"
  assert_dir_exists "$WT"
  assert_file_exists "$HOME/.config/sandshell/worktrees/$SANDBOX.meta"
}

test_sbxwt_done_unknown_sandbox_and_usage() {
  setup_test_env
  wt_repo
  run sbxwt 'done'
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt done SANDBOX'
  run sbxwt 'done' a b
  assert_rc 2
  assert_contains "$ERR" 'sbxwt: usage: sbxwt done SANDBOX'
  run sbxwt 'done' no-such
  assert_rc 1
  assert_contains "$ERR" 'sbxwt: managed worktree metadata not found: no-such'
}

test_sbxwt_done_refuses_unregistered_path() {
  setup_test_env
  wt_repo
  wt_create feature
  git -C "$REPO" worktree remove "$WT"
  mkdir "$WT"
  run sbxwt 'done' "$SANDBOX"
  assert_rc 1
  assert_contains "$ERR" "sbxwt: path exists but is no longer a registered worktree; refusing to remove it: $WT"
  # The unregistered directory and the sandbox are left alone.
  assert_dir_exists "$WT"
  assert_eq "$SANDBOX" "$(mock_sandbox_names)"
  assert_file_exists "$HOME/.config/sandshell/worktrees/$SANDBOX.meta"
}

run_tests \
  test_sbxwt_help \
  test_sbxwt_rejects_unknown_command \
  test_sbxwt_subcommand_help_shows_usage \
  test_sbxwt_subcommand_help_does_not_perform_the_operation \
  test_sbxwt_missing_git_returns_127 \
  test_sbxwt_create_requires_git_worktree \
  test_sbxwt_create_validates_arguments \
  test_sbxwt_create_detached_head_requires_base \
  test_sbxwt_create_creates_worktree_and_sandbox \
  test_sbxwt_create_prints_resume_hint_exactly_once \
  test_sbxwt_create_slugifies_branch_names \
  test_sbxwt_create_from_subdirectory \
  test_sbxwt_create_uses_default_project_env \
  test_sbxwt_create_explicit_env_wins \
  test_sbxwt_create_attaches_existing_branch \
  test_sbxwt_create_refuses_existing_worktree_path \
  test_sbxwt_create_leaves_worktree_when_sandbox_creation_fails \
  test_sbxwt_ls_lists_worktrees_and_sandboxes \
  test_unexpected_confirmation_fails_fast \
  test_sbxwt_commit_commits_after_approval \
  test_sbxwt_commit_uses_mock_editor_without_message \
  test_sbxwt_commit_declined \
  test_sbxwt_commit_no_changes \
  test_sbxwt_commit_refuses_conflicts \
  test_sbxwt_commit_usage_errors \
  test_sbxwt_merge_merges_after_approval \
  test_sbxwt_merge_declined \
  test_sbxwt_merge_already_merged \
  test_sbxwt_merge_rejects_dirty_worktrees \
  test_sbxwt_merge_into_other_branch \
  test_sbxwt_merge_usage_errors \
  test_sbxwt_done_removes_everything_and_preserves_branch \
  test_sbxwt_done_cleans_sandbox_preset_metadata \
  test_sbxwt_done_warns_when_unmerged \
  test_sbxwt_done_refuses_dirty_worktree \
  test_sbxwt_done_declined \
  test_sbxwt_done_unknown_sandbox_and_usage \
  test_sbxwt_done_refuses_unregistered_path
