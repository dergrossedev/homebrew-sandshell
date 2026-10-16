#!/usr/bin/env bash
# Characterization tests for sbxr.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

# write_vibe_config CONTENT — write the host Vibe config at the default
# location (<config-root>/agents/vibe.toml).
write_vibe_config() {
  mkdir -p "$HOME/.config/sandshell/agents"
  printf '%s\n' "$1" >"$HOME/.config/sandshell/agents/vibe.toml"
}

# assert_sync_before_launch NAME — prove the last Vibe config sync call
# happened before the agent launch call in the mock's call log.
assert_sync_before_launch() {
  local name=$1 sync_line run_line
  sync_line=$(grep -n -F 'cat > /home/agent/.vibe/config.toml' "$SBX_MOCK_STATE/calls.log" | tail -n 1 | cut -d: -f1)
  run_line=$(grep -n -F "run --name $name" "$SBX_MOCK_STATE/calls.log" | head -n 1 | cut -d: -f1)
  if [ -z "$sync_line" ] || [ -z "$run_line" ]; then
    assert_fail "expected a config sync and a launch call for $name"
  fi
  if [ "$sync_line" -ge "$run_line" ]; then
    assert_fail "config sync (line $sync_line) must happen before launch (line $run_line)"
  fi
}

test_sbxr_help() {
  setup_test_env
  run sbxr --help
  assert_rc 0
  assert_contains "$OUT" 'Usage: sbxr [NAME] [--env-file FILE] | sbxr [--all]'
  assert_contains "$OUT" 'Resume an existing sandbox (never creates one)'
}

test_sbxr_rejects_unknown_option() {
  setup_test_env
  run sbxr --bogus
  assert_rc 2
  assert_contains "$ERR" 'sbxr: unknown option: --bogus'
}

test_sbxr_rejects_two_names() {
  setup_test_env
  run sbxr one two
  assert_rc 2
  assert_contains "$ERR" 'sbxr: unexpected argument: two'
}

test_sbxr_env_file_requires_name() {
  setup_test_env
  run sbxr --env-file "$TEST_TMP/x.env"
  assert_rc 2
  assert_contains "$ERR" 'sbxr: --env-file requires a sandbox name'
}

test_sbxr_all_rejects_name_and_env_file() {
  setup_test_env
  run sbxr --all some-name
  assert_rc 2
  assert_contains "$ERR" 'sbxr: --all cannot be combined with NAME or --env-file'
  run sbxr --all --env-file "$TEST_TMP/x.env"
  assert_rc 2
  assert_contains "$ERR" 'sbxr: --all cannot be combined with NAME or --env-file'
}

test_sbxr_all_lists_native_output() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/a" "$TEST_TMP/ws/b"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/a"
  make_sandbox sbx-b codex running "$TEST_TMP/ws/b"
  run sbxr --all
  assert_rc 0
  assert_contains "$OUT" 'NAME'
  assert_contains "$OUT" 'sbx-a'
  assert_contains "$OUT" 'sbx-b'
}

test_sbxr_missing_sbx_returns_127() {
  setup_test_env
  hide_sbx
  run sbxr
  assert_rc 127
  assert_contains "$ERR" 'sbxr: sbx CLI not found'
}

test_sbxr_resumes_existing_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxr sbx-a
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name sbx-a'
  assert_contains "$ERR" 'Resuming sandbox: sbx-a'
}

test_sbxr_refuses_to_create_missing_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxr no-such-sandbox
  assert_rc 1
  assert_contains "$ERR" 'sbxr: sandbox not found: no-such-sandbox'
  assert_not_contains "$(mock_calls)" 'create'
}

test_sbxr_applies_project_env_automatically() {
  setup_test_env
  make_git_repo "$TEST_TMP/repos/myrepo"
  git -C "$TEST_TMP/repos/myrepo" worktree add -b feature "$TEST_TMP/repos/myrepo.worktrees/feature" >/dev/null 2>&1
  make_sandbox sbx-feature claude stopped "$TEST_TMP/repos/myrepo.worktrees/feature"
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir"
  printf 'TOKEN=abc\n' >"$env_dir/myrepo.env"
  cd "$TEST_TMP/repos/myrepo" || exit 1
  run sbxr sbx-feature
  assert_rc 0
  assert_contains "$(mock_calls)" "run --name sbx-feature --env-file $env_dir/myrepo.env"
  assert_contains "$ERR" "Environment: $env_dir/myrepo.env"
}

test_sbxr_explicit_env_file_wins_over_automatic() {
  setup_test_env
  make_git_repo "$TEST_TMP/repos/myrepo"
  git -C "$TEST_TMP/repos/myrepo" worktree add -b feature "$TEST_TMP/repos/myrepo.worktrees/feature" >/dev/null 2>&1
  make_sandbox sbx-feature claude stopped "$TEST_TMP/repos/myrepo.worktrees/feature"
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir"
  printf 'TOKEN=abc\n' >"$env_dir/myrepo.env"
  printf 'OTHER=1\n' >"$TEST_TMP/other.env"
  cd "$TEST_TMP/repos/myrepo" || exit 1
  run sbxr sbx-feature --env-file "$TEST_TMP/other.env"
  assert_rc 0
  assert_contains "$(mock_calls)" "run --name sbx-feature --env-file $TEST_TMP/other.env"
  assert_not_contains "$(mock_calls)" "run --name sbx-feature --env-file $env_dir/myrepo.env"
}

test_sbxr_rejects_unreadable_explicit_env_file() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxr sbx-a --env-file "$TEST_TMP/missing.env"
  assert_rc 2
  assert_contains "$ERR" 'sbxr: env file not readable'
}

test_sbxr_lists_sandboxes_for_current_workspace() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj" "$TEST_TMP/ws/other"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_sandbox sbx-b claude stopped "$TEST_TMP/ws/other"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxr
  assert_rc 0
  assert_contains "$OUT" 'sbx-a'
  assert_not_contains "$OUT" 'sbx-b'
}

test_sbxr_lists_repository_worktree_sandboxes() {
  setup_test_env
  make_git_repo "$TEST_TMP/repos/myrepo"
  git -C "$TEST_TMP/repos/myrepo" worktree add -b feature-a "$TEST_TMP/repos/myrepo.worktrees/feature-a" >/dev/null 2>&1
  git -C "$TEST_TMP/repos/myrepo" worktree add -b feature-b "$TEST_TMP/repos/myrepo.worktrees/feature-b" >/dev/null 2>&1
  mkdir -p "$TEST_TMP/ws/unrelated"
  make_sandbox sbx-a claude stopped "$TEST_TMP/repos/myrepo.worktrees/feature-a"
  make_sandbox sbx-b claude stopped "$TEST_TMP/repos/myrepo.worktrees/feature-b"
  make_sandbox sbx-c claude stopped "$TEST_TMP/ws/unrelated"
  cd "$TEST_TMP/repos/myrepo" || exit 1
  run sbxr
  assert_rc 0
  assert_contains "$OUT" 'sbx-a'
  assert_contains "$OUT" 'sbx-b'
  assert_not_contains "$OUT" 'sbx-c'
}

test_sbxr_reports_when_no_sandboxes() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxr
  assert_rc 0
  assert_eq 'No sandboxes for the current workspace/repository (use sbxr --all to see all).' "$OUT"
}

# Exercise public listing output, including the original header and rows.
assert_sbxr_listing_from() {
  cd "$1" || exit 1
  run sbxr
  assert_rc 0
  assert_eq "$2" "$OUT" "listing from $1"
}

check_sbxr_path_shape() {
  setup_test_env
  local shape=$1 workspace repository worktree expected unrelated
  workspace="$TEST_TMP/ws/$shape"
  unrelated="$TEST_TMP/unrelated/$shape"
  mkdir -p "$workspace" "$unrelated" "${workspace}-other"
  make_sandbox sbx-a-workspace claude stopped "$workspace"
  expected=$(sbx ls)
  make_sandbox sbx-same-basename codex running "$unrelated"
  make_sandbox sbx-prefix codex running "${workspace}-other"
  assert_sbxr_listing_from "$workspace" "$expected"
  run sbxr --all
  assert_rc 0
  assert_eq "$(sbx ls)" "$OUT" '--all must preserve native output'

  # Reuse the same sandbox names so the non-Git rows do not enter this listing.
  repository="$TEST_TMP/repos/$shape"
  worktree="$TEST_TMP/trees/$shape"
  make_git_repo "$repository"
  git -C "$repository" worktree add -b feature "$worktree" >/dev/null 2>&1 || exit 1
  mkdir -p "$repository/sub/dir" "$worktree/sub/dir"
  make_sandbox sbx-a-workspace claude stopped "$repository"
  make_sandbox sbx-b-feature codex running "$worktree"
  expected=$(sbx ls | grep -v -e '^sbx-same-basename' -e '^sbx-prefix')
  assert_sbxr_listing_from "$repository" "$expected"
  assert_sbxr_listing_from "$repository/sub/dir" "$expected"
  assert_sbxr_listing_from "$worktree" "$expected"
  assert_sbxr_listing_from "$worktree/sub/dir" "$expected"
  run sbxr --all
  assert_rc 0
  assert_eq "$(sbx ls)" "$OUT" '--all must preserve native output'
}

test_sbxr_hyphen_paths() { check_sbxr_path_shape 'my-project'; }
test_sbxr_dotted_paths() { check_sbxr_path_shape 'project.with.dots'; }
test_sbxr_plus_paths() { check_sbxr_path_shape 'project+api'; }
test_sbxr_bracket_paths() { check_sbxr_path_shape 'project [test]'; }
test_sbxr_space_paths() { check_sbxr_path_shape 'project with spaces'; }

test_sbxr_workspace_symlink_spellings() {
  setup_test_env
  local workspace alias expected
  workspace="$TEST_TMP/ws/project with spaces"
  alias="$TEST_TMP/project [alias]"
  mkdir -p "$workspace"
  ln -s "$workspace" "$alias"
  make_sandbox sbx-alias claude stopped "$alias"
  expected=$(sbx ls)
  assert_sbxr_listing_from "$workspace" "$expected"
  assert_sbxr_listing_from "$alias" "$expected"
  make_sandbox sbx-physical codex running "$workspace"
  expected=$(sbx ls)
  assert_sbxr_listing_from "$workspace" "$expected"
  assert_sbxr_listing_from "$alias" "$expected"
}

test_sbxr_workspace_trailing_slashes() {
  setup_test_env
  local workspace expected
  workspace="$TEST_TMP/ws/my-project"
  mkdir -p "$workspace"
  make_sandbox sbx-slash claude stopped "$workspace/"
  make_sandbox sbx-slashes codex running "$workspace///"
  expected=$(sbx ls)
  assert_sbxr_listing_from "$workspace" "$expected"
}

test_sbxr_workspace_rows_lists_every_matching_sandbox() {
  setup_test_env
  local workspace
  workspace="$TEST_TMP/ws/multi project"
  mkdir -p "$workspace" "$TEST_TMP/ws/other"
  make_sandbox sbx-one claude running "$workspace"
  make_sandbox sbx-two codex stopped "$workspace"
  make_sandbox sbx-three claude running "$TEST_TMP/ws/other"
  # The matched-name list reaches awk through -v, whose values are lexed as
  # string constants: macOS awk rejects raw newlines in them, so every
  # matching sandbox must survive the row filter.
  run _sbx_workspace_rows "$workspace" "$(sbx ls)"
  assert_rc 0
  assert_contains "$OUT" 'sbx-one'
  assert_contains "$OUT" 'sbx-two'
  assert_not_contains "$OUT" 'sbx-three'
}

# write_current_cli_table ROW... — replace `sbx ls` table output with the
# current Docker CLI shape: SANDBOX, AGENT, STATUS, PORTS, WORKSPACE, and
# CREATED columns, with two-word decorated status cells.
write_current_cli_table() {
  {
    printf 'SANDBOX\tAGENT\tSTATUS\tPORTS\tWORKSPACE\tCREATED\n'
    printf '%b\n' "$@"
  } >"$SBX_MOCK_STATE/ls-table"
}

test_sbxr_matches_workspaces_in_current_cli_table() {
  setup_test_env
  local workspace expected
  workspace="$TEST_TMP/ws/current project"
  mkdir -p "$workspace" "$TEST_TMP/ws/other"
  make_sandbox sbx-running claude running "$workspace"
  make_sandbox sbx-stopped codex stopped "$workspace"
  make_sandbox sbx-unrelated claude running "$TEST_TMP/ws/other"
  write_current_cli_table \
    "sbx-running\tclaude\t● running\t127.0.0.1:8080->3000/tcp4\t$workspace\t2m" \
    "sbx-stopped\tcodex\t○ stopped\t-\t$workspace\t3h" \
    "sbx-unrelated\tclaude\t● running\t-\t$TEST_TMP/ws/other\t1m"
  expected=$(printf 'SANDBOX\tAGENT\tSTATUS\tPORTS\tWORKSPACE\tCREATED\nsbx-running\tclaude\t● running\t127.0.0.1:8080->3000/tcp4\t%s\t2m\nsbx-stopped\tcodex\t○ stopped\t-\t%s\t3h\n' "$workspace" "$workspace")
  assert_sbxr_listing_from "$workspace" "$expected"
  assert_sbxr_listing_from "$TEST_TMP/ws/other" \
    "$(printf 'SANDBOX\tAGENT\tSTATUS\tPORTS\tWORKSPACE\tCREATED\nsbx-unrelated\tclaude\t● running\t-\t%s\t1m\n' "$TEST_TMP/ws/other")"
}

test_sbxr_matches_structured_json_workspaces() {
  setup_test_env
  local workspace other expected
  workspace="$TEST_TMP/ws/json project"
  other="$TEST_TMP/ws/other project"
  mkdir -p "$workspace" "$other"
  make_sandbox sbx-multi claude running "$workspace"
  make_sandbox sbx-readonly codex stopped "$workspace"
  make_sandbox sbx-unrelated claude running "$other"
  # Structured workspaces are the source of truth: the table abbreviates the
  # workspace cell, a sandbox can list several workspaces, and a read-only
  # workspace carries a :ro suffix.
  cat >"$SBX_MOCK_STATE/ls-response.json" <<JSON
[
  {"name":"sbx-multi","id":"id-a","agent":"claude","status":"running",
   "workspaces":["$other","$workspace"]},
  {"name":"sbx-readonly","id":"id-b","agent":"codex","status":"stopped",
   "workspaces":["${workspace}:ro"]},
  {"name":"sbx-unrelated","id":"id-c","agent":"claude","status":"running",
   "workspaces":["$other"]}
]
JSON
  write_current_cli_table \
    "sbx-multi\tclaude\t● running\t-\t…/json project\t2m" \
    "sbx-readonly\tcodex\t○ stopped\t-\t…/json project\t3h" \
    "sbx-unrelated\tclaude\t● running\t-\t…/other project\t1m"
  expected=$(printf 'SANDBOX\tAGENT\tSTATUS\tPORTS\tWORKSPACE\tCREATED\nsbx-multi\tclaude\t● running\t-\t…/json project\t2m\nsbx-readonly\tcodex\t○ stopped\t-\t…/json project\t3h\n')
  assert_sbxr_listing_from "$workspace" "$expected"
  expected=$(printf 'SANDBOX\tAGENT\tSTATUS\tPORTS\tWORKSPACE\tCREATED\nsbx-multi\tclaude\t● running\t-\t…/json project\t2m\nsbx-unrelated\tclaude\t● running\t-\t…/other project\t1m\n')
  assert_sbxr_listing_from "$other" "$expected"
}

test_sbxr_rejects_unparsable_workspace_json() {
  setup_test_env
  local workspace
  workspace="$TEST_TMP/ws/proj"
  mkdir -p "$workspace"
  make_sandbox sbx-a claude running "$workspace"
  printf '[{"name":"sbx-a","workspaces":["%s"}]\n' "$workspace" >"$SBX_MOCK_STATE/ls-response.json"
  cd "$workspace" || exit 1
  run sbxr
  assert_rc 2
  assert_contains "$ERR" 'sandshell: cannot read sandbox workspaces'
}

test_sbxr_resume_rejects_unparsable_workspace_json() {
  setup_test_env
  local workspace
  workspace="$TEST_TMP/ws/proj"
  mkdir -p "$workspace"
  make_sandbox sbx-a claude stopped "$workspace"
  printf '[{"name":"sbx-a","workspaces":["%s"}]\n' "$workspace" >"$SBX_MOCK_STATE/ls-response.json"
  cd "$workspace" || exit 1
  run sbxr sbx-a
  assert_rc 2
  assert_contains "$ERR" 'sandshell: cannot read sandbox workspaces'
  assert_not_contains "$(mock_calls)" 'run --name sbx-a'
}

test_sbxr_resume_in_worktree_rejects_unparsable_workspace_json() {
  setup_test_env
  local repository worktree
  repository="$TEST_TMP/repos/myrepo"
  worktree="$TEST_TMP/repos/myrepo.worktrees/feature"
  make_git_repo "$repository"
  git -C "$repository" worktree add -b feature "$worktree" >/dev/null 2>&1
  make_sandbox sbx-feature claude stopped "$worktree"
  printf '[{"name":"sbx-feature","workspaces":["%s"}]\n' "$worktree" >"$SBX_MOCK_STATE/ls-response.json"
  cd "$worktree" || exit 1
  run sbxr sbx-feature
  assert_rc 2
  assert_contains "$ERR" 'sandshell: cannot read sandbox workspaces'
  assert_not_contains "$(mock_calls)" 'run --name sbx-feature'
}

test_sbxr_repository_symlink_spellings() {
  setup_test_env
  local repository worktree alias expected
  mkdir -p "$TEST_TMP/repos"
  alias="$TEST_TMP/repos [alias]"
  ln -s "$TEST_TMP/repos" "$alias"
  repository="$TEST_TMP/repos/my-project"
  worktree="$TEST_TMP/repos/linked tree"
  make_git_repo "$alias/my-project"
  git -C "$alias/my-project" worktree add -b feature "$alias/linked tree" >/dev/null 2>&1 || exit 1
  mkdir -p "$repository/sub/dir" "$worktree/sub/dir"
  make_sandbox sbx-a-root claude stopped "$alias/my-project"
  make_sandbox sbx-b-feature codex running "$alias/linked tree"
  expected=$(sbx ls)
  make_sandbox sbx-unrelated claude stopped "$TEST_TMP/unrelated/my-project"
  assert_sbxr_listing_from "$repository" "$expected"
  assert_sbxr_listing_from "$repository/sub/dir" "$expected"
  assert_sbxr_listing_from "$alias/my-project/sub/dir" "$expected"
  assert_sbxr_listing_from "$worktree" "$expected"
  assert_sbxr_listing_from "$alias/linked tree/sub/dir" "$expected"
}

test_sbxr_repository_trailing_slashes() {
  setup_test_env
  local repository worktree expected
  repository="$TEST_TMP/repos/my-project"
  worktree="$TEST_TMP/trees/linked tree"
  make_git_repo "$repository"
  git -C "$repository" worktree add -b feature "$worktree" >/dev/null 2>&1 || exit 1
  mkdir -p "$repository/sub/dir"
  make_sandbox sbx-a-root claude stopped "$repository/"
  make_sandbox sbx-b-feature codex running "$worktree///"
  expected=$(sbx ls)
  assert_sbxr_listing_from "$repository" "$expected"
  assert_sbxr_listing_from "$repository/sub/dir" "$expected"
  assert_sbxr_listing_from "$worktree" "$expected"
}

test_sbxr_unavailable_worktree_keeps_literal_matching() {
  setup_test_env
  local repository worktree expected
  repository="$TEST_TMP/repos/my-project"
  worktree="$TEST_TMP/trees/linked  tree "
  make_git_repo "$repository"
  git -C "$repository" worktree add -b feature "$worktree" >/dev/null 2>&1 || exit 1
  make_sandbox sbx-root claude stopped "$repository"
  make_sandbox sbx-unavailable codex stopped "$worktree"
  expected=$(sbx ls)
  mv "$worktree" "$TEST_TMP/moved-worktree"
  assert_sbxr_listing_from "$repository" "$expected"
}

test_sbxr_macos_var_spellings() {
  setup_test_env
  if [ "$(uname -s)" != Darwin ] || [ "$(cd /var && pwd -P)" != /private/var ]; then
    printf '    SKIP: /var -> /private/var equivalence unavailable\n'
    return 0
  fi
  local physical alias expected
  physical=$(mktemp -d /var/tmp/sandshell-sbxr.XXXXXX) || exit 1
  physical=$(cd "$physical" && pwd -P) || exit 1
  # Capture this generated path before the local variable leaves scope.
  # shellcheck disable=SC2064
  trap "rm -rf -- '$physical'" EXIT
  alias=${physical#/private}
  make_sandbox sbx-var claude stopped "$alias"
  make_sandbox sbx-private codex running "/private$alias/"
  expected=$(sbx ls)
  assert_sbxr_listing_from "$alias" "$expected"
  assert_sbxr_listing_from "/private$alias" "$expected"
}

# --- Vibe config lifecycle on resume -----------------------------------------

test_sbxr_vibe_resume_syncs_updated_config_before_launch() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  write_vibe_config '[model]
name = "version-a"'
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  # Version A was copied into the sandbox at creation time.
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'version-a'
  # The host config changes to version B after creation.
  write_vibe_config '[model]
name = "version-b"'
  run sbxr vibe-sbx
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name vibe-sbx'
  # The sandbox now holds version B ...
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'version-b'
  assert_not_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'version-a'
  # ... the agent saw version B at launch time ...
  assert_contains "$(mock_launched_config vibe-sbx)" 'version-b'
  # ... and the sync happened before the launch, not after.
  assert_sync_before_launch vibe-sbx
  # The synced copy is marked as Sandshell-managed.
  assert_file_exists "$(mock_sandbox_vibe_marker vibe-sbx)"
}

test_sbxr_vibe_resume_applies_project_env_file() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  write_vibe_config '[model]
name = "version-a"'
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir"
  printf 'TOKEN=abc\n' >"$env_dir/proj.env"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxr vibe-sbx
  assert_rc 0
  assert_contains "$(mock_calls)" "run --name vibe-sbx --env-file $env_dir/proj.env"
  assert_contains "$ERR" "Environment: $env_dir/proj.env"
  # The Vibe config sync still happens before the launch.
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'version-a'
  assert_sync_before_launch vibe-sbx
}

test_sbxr_vibe_resume_syncs_bundled_preset_without_host_config() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  run sbxr vibe-sbx
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name vibe-sbx'
  # Without a user config the bundled Sandshell preset is synchronized before
  # launch; no host config is created.
  assert_eq "$(cat "$SANDSHELL_ROOT/examples/vibe.toml")" "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")"
  assert_eq "$(cat "$SANDSHELL_ROOT/examples/vibe.toml")" "$(mock_launched_config vibe-sbx)"
  assert_sync_before_launch vibe-sbx
  assert_file_exists "$(mock_sandbox_vibe_marker vibe-sbx)"
  assert_file_missing "$HOME/.config/sandshell/agents/vibe.toml"
}

test_sbxr_vibe_user_config_overrides_bundled_preset() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  # Creation without a user config synchronizes the bundled preset.
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'mistral-large-4'
  # A user config takes priority over the bundled preset.
  write_vibe_config '[model]
name = "user-model"'
  run sbxr vibe-sbx
  assert_rc 0
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'user-model'
  assert_not_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'mistral-large-4'
  assert_contains "$(mock_launched_config vibe-sbx)" 'user-model'
  assert_sync_before_launch vibe-sbx
}

test_sbxr_vibe_resume_restores_bundled_preset_when_host_config_disappears() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  write_vibe_config '[model]
name = "version-a"'
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  assert_file_exists "$(mock_sandbox_vibe_config vibe-sbx)"
  assert_file_exists "$(mock_sandbox_vibe_marker vibe-sbx)"
  # The host config is removed; the sandbox previously received a managed copy.
  rm "$HOME/.config/sandshell/agents/vibe.toml"
  run sbxr vibe-sbx
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name vibe-sbx'
  # The bundled Sandshell preset is synchronized instead of the stale copy.
  assert_eq "$(cat "$SANDSHELL_ROOT/examples/vibe.toml")" "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")"
  assert_not_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'version-a'
  assert_contains "$(mock_launched_config vibe-sbx)" 'mistral-large-4'
  assert_sync_before_launch vibe-sbx
  assert_file_exists "$(mock_sandbox_vibe_marker vibe-sbx)"
}

test_sbxr_vibe_resume_preserves_unmanaged_sandbox_config() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  # The user creates a Vibe config manually inside the sandbox and removes
  # Sandshell's ownership marker: the config is not Sandshell-managed.
  mkdir -p "$SBX_MOCK_STATE/fs/vibe-sbx/home/agent/.vibe"
  printf '[model]\nname = "manual"\n' >"$(mock_sandbox_vibe_config vibe-sbx)"
  rm -f "$(mock_sandbox_vibe_marker vibe-sbx)"
  run sbxr vibe-sbx
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name vibe-sbx'
  # The unowned config is never replaced by the bundled preset and reaches
  # the agent untouched.
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'manual'
  assert_file_missing "$(mock_sandbox_vibe_marker vibe-sbx)"
  assert_contains "$(mock_launched_config vibe-sbx)" 'manual'
}

test_sbxr_vibe_resume_rejects_invalid_host_config() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  write_vibe_config '[model]
name = "version-a"'
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  # The host config path exists but is a directory, not a readable file.
  rm "$HOME/.config/sandshell/agents/vibe.toml"
  mkdir "$HOME/.config/sandshell/agents/vibe.toml"
  run sbxr vibe-sbx
  assert_rc 2
  assert_contains "$ERR" 'sbxr: Vibe config not readable'
  # Vibe is not launched and the previous sandbox copy is untouched.
  assert_not_contains "$(mock_calls)" 'run --name vibe-sbx'
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'version-a'
}

test_sbxr_vibe_resume_rejects_dangling_symlink_host_config() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  write_vibe_config '[model]
name = "version-a"'
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  rm "$HOME/.config/sandshell/agents/vibe.toml"
  ln -s "$TEST_TMP/no-such-target" "$HOME/.config/sandshell/agents/vibe.toml"
  run sbxr vibe-sbx
  assert_rc 2
  assert_contains "$ERR" 'sbxr: Vibe config not readable'
  assert_not_contains "$(mock_calls)" 'run --name vibe-sbx'
}

test_sbxr_vibe_resume_uses_custom_config_root() {
  setup_test_env
  export SANDSHELL_CONFIG_HOME="$TEST_TMP/custom root"
  mkdir -p "$SANDSHELL_CONFIG_HOME/agents"
  printf '[model]\nname = "custom-a"\n' >"$SANDSHELL_CONFIG_HOME/agents/vibe.toml"
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  printf '[model]\nname = "custom-b"\n' >"$SANDSHELL_CONFIG_HOME/agents/vibe.toml"
  run sbxr vibe-sbx
  assert_rc 0
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'custom-b'
  assert_contains "$(mock_launched_config vibe-sbx)" 'custom-b'
  assert_sync_before_launch vibe-sbx
}

test_sbxr_vibe_resume_identifies_vibe_by_agent_not_name() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  write_vibe_config '[model]
name = "version-a"'
  # A custom sandbox name without "vibe" in it must still be detected.
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n my-agent-box
  assert_rc 0
  write_vibe_config '[model]
name = "version-b"'
  run sbxr my-agent-box
  assert_rc 0
  assert_contains "$(cat "$(mock_sandbox_vibe_config my-agent-box)")" 'version-b'
  assert_contains "$(mock_launched_config my-agent-box)" 'version-b'
  assert_sync_before_launch my-agent-box
}

test_sbxr_non_vibe_resume_skips_vibe_sync() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  write_vibe_config '[model]
name = "version-a"'
  run sbxc -d "$TEST_TMP/ws/proj" -a claude -n claude-sbx
  assert_rc 0
  run sbxr claude-sbx
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name claude-sbx'
  # No Vibe synchronization runs for a non-Vibe sandbox.
  assert_not_contains "$(mock_calls)" 'cat > /home/agent/.vibe/config.toml'
  assert_not_contains "$(mock_calls)" '.sandshell-config-managed'
  assert_file_missing "$(mock_sandbox_vibe_config claude-sbx)"
  assert_file_missing "$(mock_sandbox_vibe_marker claude-sbx)"
}

test_sbxr_vibe_sync_never_modifies_host_state() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  write_vibe_config '[model]
name = "version-a"'
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  write_vibe_config '[model]
name = "version-b"'
  before=$(tree_fingerprint "$HOME")
  run sbxr vibe-sbx
  assert_rc 0
  # sbxr writes nothing under the host HOME; the host config keeps version B.
  assert_eq "$before" "$(tree_fingerprint "$HOME")"
  assert_contains "$(cat "$HOME/.config/sandshell/agents/vibe.toml")" 'version-b'
  # No host-side Vibe state is created.
  assert_file_missing "$HOME/.vibe"
}

test_sbxr_vibe_resume_warns_when_replacing_unmanaged_config() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe -n vibe-sbx
  assert_rc 0
  # The user creates a Vibe config manually inside the sandbox and removes
  # Sandshell's ownership marker: the config is not Sandshell-managed.
  mkdir -p "$SBX_MOCK_STATE/fs/vibe-sbx/home/agent/.vibe"
  printf '[model]\nname = "manual"\n' >"$(mock_sandbox_vibe_config vibe-sbx)"
  rm -f "$(mock_sandbox_vibe_marker vibe-sbx)"
  # ... then a host config appears.
  write_vibe_config '[model]
name = "version-a"'
  run sbxr vibe-sbx
  assert_rc 0
  # The replacement is not silent, and the copy becomes Sandshell-managed.
  assert_contains "$ERR" 'replacing a Vibe config inside the sandbox that sandshell did not manage'
  assert_contains "$(cat "$(mock_sandbox_vibe_config vibe-sbx)")" 'version-a'
  assert_file_exists "$(mock_sandbox_vibe_marker vibe-sbx)"
  assert_contains "$(mock_launched_config vibe-sbx)" 'version-a'
}

# --- opencode-ollama resume ----------------------------------------------------

test_sbxr_opencode_ollama_applies_provider_and_default_model() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama -n oc-sbx
  assert_rc 0
  run sbxr oc-sbx
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name oc-sbx --provider ollama --model qwen3.5:4b-mlx'
}

test_sbxr_opencode_ollama_custom_name_and_model_override() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama --model llama3.2:latest -n my-custom-box
  assert_rc 0
  run sbxr my-custom-box
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name my-custom-box --provider ollama --model llama3.2:latest'
}

test_sbxr_opencode_ollama_applies_env_file() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama -n oc-sbx
  assert_rc 0
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir"
  printf 'TOKEN=abc\n' >"$env_dir/proj.env"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxr oc-sbx
  assert_rc 0
  calls=$(mock_calls)
  assert_contains "$calls" 'run --name oc-sbx'
  assert_contains "$calls" '--provider ollama'
  assert_contains "$calls" '--model qwen3.5:4b-mlx'
  assert_contains "$calls" "--env-file $env_dir/proj.env"
}

test_sbxr_plain_opencode_gets_no_ollama_flags() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode -n oc-plain
  assert_rc 0
  run sbxr oc-plain
  assert_rc 0
  assert_contains "$(mock_calls)" 'run --name oc-plain'
  assert_not_contains "$(mock_calls)" '--provider ollama'
  assert_not_contains "$(mock_calls)" '--model'
}

test_sbxr_invalid_preset_metadata_fails_safely() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama -n oc-sbx
  assert_rc 0
  meta="$HOME/.config/sandshell/sandboxes/oc-sbx.meta"
  # Unknown preset.
  printf 'preset=bogus\nmodel=qwen3.5:4b-mlx\n' >"$meta"
  run sbxr oc-sbx
  assert_rc 2
  assert_contains "$ERR" 'invalid sandbox metadata'
  assert_not_contains "$(mock_calls)" 'run --name oc-sbx'
  # Unknown key.
  printf 'preset=opencode-ollama\nmodel=qwen3.5:4b-mlx\nextra=1\n' >"$meta"
  run sbxr oc-sbx
  assert_rc 2
  assert_contains "$ERR" 'invalid sandbox metadata'
  # Missing model.
  printf 'preset=opencode-ollama\n' >"$meta"
  run sbxr oc-sbx
  assert_rc 2
  assert_contains "$ERR" 'invalid sandbox metadata'
  # Malformed line.
  printf 'garbage\n' >"$meta"
  run sbxr oc-sbx
  assert_rc 2
  assert_contains "$ERR" 'invalid sandbox metadata'
  # Model with an unsafe value.
  printf 'preset=opencode-ollama\nmodel=bad model\n' >"$meta"
  run sbxr oc-sbx
  assert_rc 2
  assert_contains "$ERR" 'invalid sandbox metadata'
  # The sandbox is never launched while the metadata is invalid.
  assert_not_contains "$(mock_calls)" 'run --name oc-sbx'
}

test_sbxr_unreadable_preset_metadata_fails_safely() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama -n oc-sbx
  assert_rc 0
  meta="$HOME/.config/sandshell/sandboxes/oc-sbx.meta"
  rm -f "$meta"
  ln -s "$TEST_TMP/no-such-target" "$meta"
  run sbxr oc-sbx
  assert_rc 2
  assert_contains "$ERR" 'sandbox metadata'
  assert_not_contains "$(mock_calls)" 'run --name oc-sbx'
}

run_tests \
  test_sbxr_help \
  test_sbxr_rejects_unknown_option \
  test_sbxr_rejects_two_names \
  test_sbxr_env_file_requires_name \
  test_sbxr_all_rejects_name_and_env_file \
  test_sbxr_all_lists_native_output \
  test_sbxr_missing_sbx_returns_127 \
  test_sbxr_resumes_existing_sandbox \
  test_sbxr_refuses_to_create_missing_sandbox \
  test_sbxr_applies_project_env_automatically \
  test_sbxr_explicit_env_file_wins_over_automatic \
  test_sbxr_rejects_unreadable_explicit_env_file \
  test_sbxr_lists_sandboxes_for_current_workspace \
  test_sbxr_lists_repository_worktree_sandboxes \
  test_sbxr_reports_when_no_sandboxes \
  test_sbxr_hyphen_paths \
  test_sbxr_dotted_paths \
  test_sbxr_plus_paths \
  test_sbxr_bracket_paths \
  test_sbxr_space_paths \
  test_sbxr_workspace_symlink_spellings \
  test_sbxr_workspace_trailing_slashes \
  test_sbxr_workspace_rows_lists_every_matching_sandbox \
  test_sbxr_matches_workspaces_in_current_cli_table \
  test_sbxr_matches_structured_json_workspaces \
  test_sbxr_rejects_unparsable_workspace_json \
  test_sbxr_resume_rejects_unparsable_workspace_json \
  test_sbxr_resume_in_worktree_rejects_unparsable_workspace_json \
  test_sbxr_repository_symlink_spellings \
  test_sbxr_repository_trailing_slashes \
  test_sbxr_unavailable_worktree_keeps_literal_matching \
  test_sbxr_macos_var_spellings \
  test_sbxr_vibe_resume_syncs_updated_config_before_launch \
  test_sbxr_vibe_resume_applies_project_env_file \
  test_sbxr_vibe_resume_syncs_bundled_preset_without_host_config \
  test_sbxr_vibe_user_config_overrides_bundled_preset \
  test_sbxr_vibe_resume_restores_bundled_preset_when_host_config_disappears \
  test_sbxr_vibe_resume_preserves_unmanaged_sandbox_config \
  test_sbxr_vibe_resume_rejects_invalid_host_config \
  test_sbxr_vibe_resume_rejects_dangling_symlink_host_config \
  test_sbxr_vibe_resume_uses_custom_config_root \
  test_sbxr_vibe_resume_identifies_vibe_by_agent_not_name \
  test_sbxr_non_vibe_resume_skips_vibe_sync \
  test_sbxr_vibe_sync_never_modifies_host_state \
  test_sbxr_vibe_resume_warns_when_replacing_unmanaged_config \
  test_sbxr_opencode_ollama_applies_provider_and_default_model \
  test_sbxr_opencode_ollama_custom_name_and_model_override \
  test_sbxr_opencode_ollama_applies_env_file \
  test_sbxr_plain_opencode_gets_no_ollama_flags \
  test_sbxr_invalid_preset_metadata_fails_safely \
  test_sbxr_unreadable_preset_metadata_fails_safely
