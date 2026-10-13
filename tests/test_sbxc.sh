#!/usr/bin/env bash
# Characterization tests for sbxc.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

# make_workspace PATH — a plain directory used as a sandbox workspace.
make_workspace() {
  mkdir -p "$1"
}

# write_vibe_config — a readable host Vibe config at the default location.
write_vibe_config() {
  mkdir -p "$HOME/.config/sandshell/agents"
  printf '[model]\nname = "test"\n' >"$HOME/.config/sandshell/agents/vibe.toml"
}

test_sbxc_help() {
  setup_test_env
  run sbxc --help
  assert_rc 0
  assert_contains "$OUT" 'Usage: sbxc [-a AGENT] [-d DIR] [-s SIZE] [-n NAME] [--clone] [--env-file FILE] [--model MODEL]'
  assert_contains "$OUT" 'Agents: claude (default), codex, opencode, vibe, claude-ollama, opencode-ollama'
  assert_contains "$OUT" '--model MODEL'
  assert_contains "$OUT" 'qwen3.5:4b-mlx'
}

test_sbxc_help_shows_generated_name_format() {
  setup_test_env
  run sbxc --help
  assert_rc 0
  assert_contains "$OUT" 'sbx-<project>-<agent>-<random>'
}

test_sbxc_success_reports_created_sandbox_and_resume_hint() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -n my-sbx
  assert_rc 0
  # sbxc creates without launching; the output must say what was created and
  # how to start it.
  assert_contains "$ERR" 'Created sandbox: my-sbx'
  assert_contains "$ERR" 'Resume with: sbxr my-sbx'
}

test_sbxc_rejects_unknown_option() {
  setup_test_env
  run sbxc --bogus
  assert_rc 2
  assert_contains "$ERR" 'sbxc: unknown option: --bogus'
}

test_sbxc_rejects_missing_option_value() {
  setup_test_env
  run sbxc -a
  assert_rc 2
  assert_contains "$ERR" 'sbxc: missing value for -a'
}

test_sbxc_rejects_unsupported_agent() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a bogus
  assert_rc 2
  assert_contains "$ERR" 'sbxc: unsupported agent: bogus'
}

test_sbxc_rejects_invalid_size() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -s huge
  assert_rc 2
  assert_contains "$ERR" 'sbxc: invalid size: huge (micro|small|medium)'
}

test_sbxc_rejects_missing_directory() {
  setup_test_env
  run sbxc -d "$TEST_TMP/no-such-dir"
  assert_rc 2
  assert_contains "$ERR" 'sbxc: directory not found'
}

test_sbxc_refuses_broad_workspaces() {
  setup_test_env
  run sbxc -d /
  assert_rc 2
  assert_contains "$ERR" 'sbxc: refusing broad workspace: /'
  run sbxc -d "$HOME"
  assert_rc 2
  assert_contains "$ERR" 'sbxc: refusing broad workspace'
  # an ancestor of $HOME is also too broad
  run sbxc -d "$(dirname "$HOME")"
  assert_rc 2
  assert_contains "$ERR" 'sbxc: refusing broad workspace'
}

test_sbxc_refuses_sensitive_workspaces() {
  setup_test_env
  for d in "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.config"; do
    mkdir -p "$d"
    run sbxc -d "$d"
    assert_rc 2 "workspace: $d"
    assert_contains "$ERR" 'sbxc: refusing sensitive workspace' "workspace: $d"
  done
  # Exercise a system path through canonicalization without creating or
  # modifying anything outside the test tree.
  ln -s /usr "$TEST_TMP/sensitive-system"
  run sbxc -d "$TEST_TMP/sensitive-system"
  assert_rc 2
  assert_contains "$ERR" 'sbxc: refusing sensitive workspace: /usr'
}

test_sbxc_defaults_to_claude_with_micro_size() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj"
  assert_rc 0
  calls=$(mock_calls)
  assert_contains "$calls" 'create --name sbx-proj-claude-'
  assert_contains "$calls" '--cpus 2 --memory 2g --pull missing --skills off'
  assert_contains "$calls" " claude $TEST_TMP/ws/proj"
  assert_contains "$ERR" 'Creating sandbox: sbx-proj-claude-'
  assert_contains "$ERR" 'Mode: direct'
  # creates but does not launch the interactive agent
  assert_not_contains "$calls" 'run --name'
}

test_sbxc_size_mappings() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/small"
  make_workspace "$TEST_TMP/ws/medium"
  run sbxc -d "$TEST_TMP/ws/small" -s small
  assert_rc 0
  assert_contains "$(mock_calls)" '--cpus 2 --memory 4g'
  run sbxc -d "$TEST_TMP/ws/medium" -s medium
  assert_rc 0
  assert_contains "$(mock_calls)" '--cpus 4 --memory 8g'
}

test_sbxc_builtin_agent_mappings() {
  setup_test_env
  for agent in codex opencode; do
    make_workspace "$TEST_TMP/ws/$agent"
    run sbxc -d "$TEST_TMP/ws/$agent" -a "$agent"
    assert_rc 0
    assert_contains "$(mock_calls)" " $agent $TEST_TMP/ws/$agent"
  done
}

test_sbxc_claude_ollama_maps_to_kit_image() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a claude-ollama
  assert_rc 0
  assert_contains "$(mock_calls)" " docker.io/sbx/claude-ollama:latest $TEST_TMP/ws/proj"
}

# --- opencode-ollama -----------------------------------------------------------

test_sbxc_opencode_ollama_creates_opencode_sandbox() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama
  assert_rc 0
  name=$(mock_sandbox_names)
  # The underlying sandbox uses the built-in opencode workload.
  assert_contains "$(mock_calls)" "create --name $name"
  assert_contains "$(mock_calls)" '--cpus 2 --memory 2g'
  assert_contains "$(mock_calls)" " opencode $TEST_TMP/ws/proj"
  assert_eq 'opencode' "$(awk -F '\t' '$1 == "agent" { print substr($0, index($0, "\t") + 1); exit }' "$SBX_MOCK_STATE/sandboxes/$name")"
  # Create-only: the agent is not launched.
  assert_not_contains "$(mock_calls)" 'run --name'
}

test_sbxc_opencode_ollama_persists_default_model() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama -n oc-sbx
  assert_rc 0
  meta="$HOME/.config/sandshell/sandboxes/oc-sbx.meta"
  assert_file_exists "$meta"
  assert_eq 'preset=opencode-ollama
model=qwen3.5:4b-mlx' "$(cat "$meta")"
  assert_eq 600 "$(file_mode "$meta")"
}

test_sbxc_opencode_ollama_model_override_persists() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama --model llama3.2:latest -n oc-sbx
  assert_rc 0
  assert_eq 'preset=opencode-ollama
model=llama3.2:latest' "$(cat "$HOME/.config/sandshell/sandboxes/oc-sbx.meta")"
}

test_sbxc_rejects_model_for_other_agents() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  for agent in claude codex opencode vibe claude-ollama; do
    run sbxc -d "$TEST_TMP/ws/proj" -a "$agent" --model some-model
    assert_rc 2 "agent: $agent"
    assert_contains "$ERR" 'sbxc: --model is only supported for the opencode-ollama agent' "agent: $agent"
  done
  assert_eq 0 "$(mock_sandbox_count)"
}

test_sbxc_rejects_invalid_model_name() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama --model 'bad model'
  assert_rc 2
  assert_contains "$ERR" 'sbxc: invalid model'
  assert_eq 0 "$(mock_sandbox_count)"
}

test_sbxc_opencode_has_no_preset_metadata() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode -n oc-plain
  assert_rc 0
  assert_file_missing "$HOME/.config/sandshell/sandboxes/oc-plain.meta"
}

test_sbxc_opencode_ollama_never_pulls_or_installs_models() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a opencode-ollama -n oc-sbx
  assert_rc 0
  run sbxr oc-sbx
  assert_rc 0
  calls=$(mock_calls)
  assert_not_contains "$calls" 'ollama pull'
  assert_not_contains "$calls" 'ollama install'
  assert_not_contains "$calls" 'ollama run'
  assert_not_contains "$calls" 'ollama serve'
  # The only pull is the image pull policy, never a model pull.
  assert_contains "$calls" '--pull missing'
  # The runtime source never issues an Ollama pull/install either.
  if grep -nE 'ollama[[:space:]]+(pull|install|run|serve)' "$SANDSHELL_SH" "$SANDSHELL_ROOT"/src/*.sh; then
    assert_fail 'runtime must never pull or install Ollama models'
  fi
}

test_sbxc_vibe_maps_to_kit_image() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  write_vibe_config
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe
  assert_rc 0
  assert_contains "$(mock_calls)" " docker.io/docker/sbx-kit-vibe:latest $TEST_TMP/ws/proj"
}

test_sbxc_vibe_syncs_bundled_preset_without_user_config() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe
  assert_rc 0
  name=$(mock_sandbox_names)
  assert_eq 'stopped' "$(mock_sandbox_status "$name")"
  # Without a user config the bundled Sandshell preset is synchronized into
  # the sandbox and marked as Sandshell-managed; no host config is created.
  assert_file_eq "$SANDSHELL_ROOT/examples/vibe.toml" \
    "$SBX_MOCK_STATE/fs/$name/home/agent/.vibe/config.toml"
  assert_file_exists "$SBX_MOCK_STATE/fs/$name/home/agent/.vibe/.sandshell-config-managed"
  assert_file_missing "$HOME/.config/sandshell/agents/vibe.toml"
  # The MCP gateway setup still runs (and warns without gateway env vars).
  assert_contains "$ERR" 'sbxc: warning: could not configure Vibe for the Docker MCP gateway'
}

test_sbxc_vibe_rejects_invalid_config() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  # The config path exists but is a directory, not a readable file.
  mkdir -p "$HOME/.config/sandshell/agents/vibe.toml"
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe
  assert_rc 2
  assert_contains "$ERR" 'sbxc: Vibe config not readable'
  assert_not_contains "$(mock_calls)" 'create'
}

test_sbxc_vibe_rejects_dangling_symlink_config() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  mkdir -p "$HOME/.config/sandshell/agents"
  ln -s "$TEST_TMP/no-such-target" "$HOME/.config/sandshell/agents/vibe.toml"
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe
  assert_rc 2
  assert_contains "$ERR" 'sbxc: Vibe config not readable'
  assert_not_contains "$(mock_calls)" 'create'
}

test_sbxc_vibe_uses_custom_config_root() {
  setup_test_env
  export SANDSHELL_CONFIG_HOME="$TEST_TMP/custom root"
  mkdir -p "$SANDSHELL_CONFIG_HOME/agents"
  printf '[model]\nname = "custom"\n' >"$SANDSHELL_CONFIG_HOME/agents/vibe.toml"
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe
  assert_rc 0
  name=$(mock_sandbox_names)
  assert_file_eq "$SANDSHELL_CONFIG_HOME/agents/vibe.toml" \
    "$SBX_MOCK_STATE/fs/$name/home/agent/.vibe/config.toml"
}

test_sbxc_vibe_copies_config_and_returns_to_stopped() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  write_vibe_config
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe
  assert_rc 0
  name=$(mock_sandbox_names)
  assert_eq 'stopped' "$(mock_sandbox_status "$name")"
  assert_file_eq "$HOME/.config/sandshell/agents/vibe.toml" \
    "$SBX_MOCK_STATE/fs/$name/home/agent/.vibe/config.toml"
  # without gateway env vars the gateway setup warns but creation succeeds
  assert_contains "$ERR" 'sbxc: warning: could not configure Vibe for the Docker MCP gateway'
}

test_sbxc_vibe_marks_config_as_sandshell_managed() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  write_vibe_config
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe
  assert_rc 0
  name=$(mock_sandbox_names)
  # The copied config is marked as Sandshell-managed so a later resume can
  # safely replace or remove it, and it stays private to the agent user.
  assert_file_exists "$SBX_MOCK_STATE/fs/$name/home/agent/.vibe/.sandshell-config-managed"
  assert_eq '600' "$(file_mode "$SBX_MOCK_STATE/fs/$name/home/agent/.vibe/config.toml")"
}

test_sbxc_vibe_configures_mcp_gateway_when_env_present() {
  setup_test_env
  make_stub vibe
  export MCP_GATEWAY_URL='http://gateway.test:8811'
  export MCP_SENTINEL_TOKEN_NAME='MCP_SENTINEL_TOKEN'
  make_workspace "$TEST_TMP/ws/proj"
  write_vibe_config
  run sbxc -d "$TEST_TMP/ws/proj" -a vibe
  assert_rc 0
  vibe_calls=$(stub_log vibe)
  assert_contains "$vibe_calls" 'mcp add docker-sbx-gateway'
  assert_contains "$vibe_calls" '--url http://gateway.test:8811'
  assert_contains "$vibe_calls" '--transport streamable-http'
  assert_contains "$vibe_calls" '--allow-insecure-http'
  assert_contains "$vibe_calls" '--api-key-env MCP_SENTINEL_TOKEN_NAME'
}

test_sbxc_uses_centralized_env_file_when_present() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir"
  printf 'TOKEN=abc\n' >"$env_dir/proj.env"
  run sbxc -d "$TEST_TMP/ws/proj"
  assert_rc 0
  assert_contains "$(mock_calls)" "--env-file $env_dir/proj.env"
}

test_sbxc_omits_env_file_when_absent() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj"
  assert_rc 0
  assert_not_contains "$(mock_calls)" '--env-file'
}

test_sbxc_explicit_env_file_overrides_default() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir"
  printf 'A=1\n' >"$env_dir/proj.env"
  printf 'B=2\n' >"$TEST_TMP/custom.env"
  run sbxc -d "$TEST_TMP/ws/proj" --env-file "$TEST_TMP/custom.env"
  assert_rc 0
  assert_contains "$(mock_calls)" "--env-file $TEST_TMP/custom.env"
  assert_not_contains "$(mock_calls)" "--env-file $env_dir/proj.env"
}

test_sbxc_rejects_unreadable_env_file() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" --env-file "$TEST_TMP/missing.env"
  assert_rc 2
  assert_contains "$ERR" 'sbxc: env file not readable'
}

test_sbxc_rejects_name_collision() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  make_sandbox taken-name claude stopped "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -n taken-name
  assert_rc 2
  assert_contains "$ERR" 'sbxc: sandbox already exists: taken-name'
}

test_sbxc_rejects_invalid_custom_names() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  for bad in default a 'bad name' '-lead' '.dot'; do
    run sbxc -d "$TEST_TMP/ws/proj" -n "$bad"
    assert_rc 2 "name: $bad"
    assert_contains "$ERR" 'sbxc: invalid sandbox name' "name: $bad"
  done
}

test_sbxc_accepts_valid_custom_name() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" -n my-sandbox.1
  assert_rc 0
  assert_contains "$(mock_calls)" 'create --name my-sandbox.1 '
  assert_eq 'my-sandbox.1' "$(mock_sandbox_names)"
}

test_sbxc_generates_conventional_names() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/myproj"
  run sbxc -d "$TEST_TMP/ws/myproj" -a codex
  assert_rc 0
  assert_match '^sbx-myproj-codex-[0-9a-f]{8}$' "$(mock_sandbox_names)"
}

test_sbxc_clone_mode_requires_git() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj" --clone
  assert_rc 2
  assert_contains "$ERR" 'sbxc: --clone requires a Git working tree'
}

test_sbxc_clone_mode_uses_clone_flag() {
  setup_test_env
  make_git_repo "$TEST_TMP/repos/proj"
  run sbxc -d "$TEST_TMP/repos/proj" --clone
  assert_rc 0
  assert_contains "$(mock_calls)" '--clone'
  assert_contains "$ERR" 'Mode: clone'
}

test_sbxc_detects_worktree_mode() {
  setup_test_env
  make_git_repo "$TEST_TMP/repos/proj"
  git -C "$TEST_TMP/repos/proj" worktree add -b feature "$TEST_TMP/repos/proj.worktrees/feature" >/dev/null 2>&1
  run sbxc -d "$TEST_TMP/repos/proj.worktrees/feature"
  assert_rc 0
  assert_contains "$ERR" 'Mode: host worktree'
}

test_sbxc_missing_sbx_returns_127() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  hide_sbx
  run sbxc -d "$TEST_TMP/ws/proj"
  assert_rc 127
  assert_contains "$ERR" 'sbxc: sbx CLI not found'
}

test_sbxc_initializes_isolated_skill_state() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  run sbxc -d "$TEST_TMP/ws/proj"
  assert_rc 0
  name=$(mock_sandbox_names)
  assert_file_exists "$HOME/.config/sandshell/skills/$name.skills"
  assert_eq '' "$(cat "$HOME/.config/sandshell/skills/$name.skills")"
}

run_tests \
  test_sbxc_help \
  test_sbxc_help_shows_generated_name_format \
  test_sbxc_success_reports_created_sandbox_and_resume_hint \
  test_sbxc_rejects_unknown_option \
  test_sbxc_rejects_missing_option_value \
  test_sbxc_rejects_unsupported_agent \
  test_sbxc_rejects_invalid_size \
  test_sbxc_rejects_missing_directory \
  test_sbxc_refuses_broad_workspaces \
  test_sbxc_refuses_sensitive_workspaces \
  test_sbxc_defaults_to_claude_with_micro_size \
  test_sbxc_size_mappings \
  test_sbxc_builtin_agent_mappings \
  test_sbxc_claude_ollama_maps_to_kit_image \
  test_sbxc_opencode_ollama_creates_opencode_sandbox \
  test_sbxc_opencode_ollama_persists_default_model \
  test_sbxc_opencode_ollama_model_override_persists \
  test_sbxc_rejects_model_for_other_agents \
  test_sbxc_rejects_invalid_model_name \
  test_sbxc_opencode_has_no_preset_metadata \
  test_sbxc_opencode_ollama_never_pulls_or_installs_models \
  test_sbxc_vibe_maps_to_kit_image \
  test_sbxc_vibe_syncs_bundled_preset_without_user_config \
  test_sbxc_vibe_rejects_invalid_config \
  test_sbxc_vibe_rejects_dangling_symlink_config \
  test_sbxc_vibe_uses_custom_config_root \
  test_sbxc_vibe_copies_config_and_returns_to_stopped \
  test_sbxc_vibe_marks_config_as_sandshell_managed \
  test_sbxc_vibe_configures_mcp_gateway_when_env_present \
  test_sbxc_uses_centralized_env_file_when_present \
  test_sbxc_omits_env_file_when_absent \
  test_sbxc_explicit_env_file_overrides_default \
  test_sbxc_rejects_unreadable_env_file \
  test_sbxc_rejects_name_collision \
  test_sbxc_rejects_invalid_custom_names \
  test_sbxc_accepts_valid_custom_name \
  test_sbxc_generates_conventional_names \
  test_sbxc_clone_mode_requires_git \
  test_sbxc_clone_mode_uses_clone_flag \
  test_sbxc_detects_worktree_mode \
  test_sbxc_missing_sbx_returns_127 \
  test_sbxc_initializes_isolated_skill_state
