#!/usr/bin/env bash
# Tests for the Sandshell configuration root: resolution priority, XDG
# support, paths with spaces, consistent use across commands, and the
# optional shared Vibe config location.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

test_config_default_root_is_home_dot_config_sandshell() {
  setup_test_env
  root=$(_sbx_config_dir)
  assert_eq "$HOME/.config/sandshell" "$root"
}

test_config_xdg_config_home_is_used() {
  setup_test_env
  export XDG_CONFIG_HOME="$TEST_TMP/xdg config"
  root=$(_sbx_config_dir)
  assert_eq "$TEST_TMP/xdg config/sandshell" "$root"
}

test_config_sandshell_config_home_takes_precedence_over_xdg() {
  setup_test_env
  export XDG_CONFIG_HOME="$TEST_TMP/xdg"
  export SANDSHELL_CONFIG_HOME="$TEST_TMP/custom"
  root=$(_sbx_config_dir)
  assert_eq "$TEST_TMP/custom" "$root"
}

test_config_empty_sandshell_config_home_falls_back_to_xdg() {
  setup_test_env
  export SANDSHELL_CONFIG_HOME=''
  export XDG_CONFIG_HOME="$TEST_TMP/xdg"
  root=$(_sbx_config_dir)
  assert_eq "$TEST_TMP/xdg/sandshell" "$root"
}

test_config_fails_clearly_when_no_root_can_be_derived() {
  setup_test_env
  unset HOME XDG_CONFIG_HOME SANDSHELL_CONFIG_HOME
  run _sbx_config_dir
  assert_rc 1
  assert_eq '' "$OUT"
  assert_contains "$ERR" 'cannot determine the configuration directory'
}

test_config_env_file_location_is_shared_across_commands() {
  setup_test_env
  # A config root containing spaces must work end to end.
  export SANDSHELL_CONFIG_HOME="$TEST_TMP/sandshell config"
  make_stub myeditor
  mkdir -p "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1

  # sbxenv creates and edits the project env file under the config root.
  run sbxenv myeditor
  assert_rc 0
  env_file="$SANDSHELL_CONFIG_HOME/envs/proj.env"
  assert_file_exists "$env_file"
  assert_eq "$env_file" "$(stub_log myeditor)"
  printf 'TOKEN=abc\n' >"$env_file"

  # sbxc discovers the same file automatically.
  run sbxc -d "$TEST_TMP/ws/proj"
  assert_rc 0
  assert_contains "$(mock_calls)" "--env-file $env_file"

  # sbxr auto-applies the same file when resuming a sandbox on the workspace.
  name=$(mock_sandbox_names)
  run sbxr "$name"
  assert_rc 0
  assert_contains "$(mock_calls)" "run --name $name --env-file $env_file"

  # sbxwt create uses the main repository's project env by default.
  make_git_repo "$TEST_TMP/repos/myrepo"
  printf 'REPO=1\n' >"$SANDSHELL_CONFIG_HOME/envs/myrepo.env"
  cd "$TEST_TMP/repos/myrepo" || exit 1
  run sbxwt create feature
  assert_rc 0
  assert_contains "$(mock_calls)" "--env-file $SANDSHELL_CONFIG_HOME/envs/myrepo.env"
}

test_config_state_dirs_are_shared_across_commands() {
  setup_test_env
  export SANDSHELL_CONFIG_HOME="$TEST_TMP/custom-root"
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_mcp_server fetch '{"name":"fetch","type":"http","url":"https://example.com/mcp"}'
  run sbxmcp add sbx-a fetch
  assert_rc 0
  assert_file_exists "$SANDSHELL_CONFIG_HOME/mcp/sbx-a.servers"
  init_skill_state sbx-a
  assert_file_exists "$SANDSHELL_CONFIG_HOME/skills/sbx-a.skills"
  make_git_repo "$TEST_TMP/repos/myrepo"
  cd "$TEST_TMP/repos/myrepo" || exit 1
  run sbxwt create feature
  assert_rc 0
  sandbox=$(printf '%s\n' "$OUT" | sed -n 's/^Sandbox:  //p')
  assert_file_exists "$SANDSHELL_CONFIG_HOME/worktrees/$sandbox.meta"
}

test_config_never_writes_under_docker_config_namespace() {
  setup_test_env
  make_stub myeditor
  mkdir -p "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv myeditor
  assert_rc 0
  run sbxc -d "$TEST_TMP/ws/proj"
  assert_rc 0
  assert_file_missing "$HOME/.config/sbx"
  assert_file_exists "$HOME/.config/sandshell/envs/proj.env"
  assert_file_exists "$HOME/.config/sandshell/skills/$(mock_sandbox_names).skills"
}

test_config_help_texts_have_no_stale_paths() {
  setup_test_env
  for cmd in sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxcmd; do
    run "$cmd" --help
    assert_rc 0 "help failed: $cmd"
    assert_not_contains "$OUT" '.config/sbx' "stale Docker config path in $cmd --help"
  done
}

run_tests \
  test_config_default_root_is_home_dot_config_sandshell \
  test_config_xdg_config_home_is_used \
  test_config_sandshell_config_home_takes_precedence_over_xdg \
  test_config_empty_sandshell_config_home_falls_back_to_xdg \
  test_config_fails_clearly_when_no_root_can_be_derived \
  test_config_env_file_location_is_shared_across_commands \
  test_config_state_dirs_are_shared_across_commands \
  test_config_never_writes_under_docker_config_namespace \
  test_config_help_texts_have_no_stale_paths
