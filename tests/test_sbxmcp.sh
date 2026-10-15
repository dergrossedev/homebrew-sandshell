#!/usr/bin/env bash
# Characterization tests for sbxmcp.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

HTTP_JSON='{"name":"fetch","type":"http","url":"https://example.com/mcp"}'

test_sbxmcp_help() {
  setup_test_env
  run sbxmcp --help
  assert_rc 0
  assert_contains "$OUT" 'sbxmcp add SANDBOX SERVER [...]'
  assert_contains "$OUT" 'sbxmcp copy SOURCE TARGET'
}

test_sbxmcp_rejects_unknown_command() {
  setup_test_env
  run sbxmcp frobnicate
  assert_rc 2
  assert_contains "$ERR" 'sbxmcp: unknown command: frobnicate'
}

test_sbxmcp_subcommand_help_shows_usage() {
  setup_test_env
  for sub in ls add copy; do
    run sbxmcp "$sub" --help
    assert_rc 0 "subcommand: $sub"
    assert_contains "$OUT" 'sbxmcp add SANDBOX SERVER [...]' "subcommand: $sub"
    run sbxmcp "$sub" -h
    assert_rc 0 "subcommand: $sub"
    assert_contains "$OUT" 'sbxmcp add SANDBOX SERVER [...]' "subcommand: $sub"
  done
}

test_sbxmcp_subcommand_help_does_not_perform_the_operation() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  run sbxmcp ls --help
  assert_rc 0
  # The help flag never reaches the sandbox lookup: no sbx calls at all.
  assert_eq '' "$(mock_calls)"
}

test_sbxmcp_help_mentions_local_server_approval() {
  setup_test_env
  run sbxmcp --help
  assert_rc 0
  assert_contains "$OUT" 'require interactive approval'
}

test_sbxmcp_missing_sbx_returns_127() {
  setup_test_env
  hide_sbx
  run sbxmcp ls
  assert_rc 127
  assert_contains "$ERR" 'sbxmcp: sbx CLI not found'
}

test_sbxmcp_ls_lists_host_registry() {
  setup_test_env
  make_mcp_server fetch "$HTTP_JSON"
  make_mcp_server web '{"name":"web","type":"http","url":"https://example.com/web"}'
  run sbxmcp ls
  assert_rc 0
  assert_contains "$OUT" 'fetch'
  assert_contains "$OUT" 'web'
}

test_sbxmcp_ls_sandbox_lists_tracked_servers() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  state_dir="$HOME/.config/sandshell/mcp"
  mkdir -p "$state_dir"
  printf 'fetch\nweb\n' >"$state_dir/sbx-a.servers"
  run sbxmcp ls sbx-a
  assert_rc 0
  assert_eq 'Tracked MCP servers for sbx-a:
fetch
web' "$OUT"
}

test_sbxmcp_ls_sandbox_reports_empty() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  mkdir -p "$HOME/.config/sandshell/mcp"
  : >"$HOME/.config/sandshell/mcp/sbx-a.servers"
  run sbxmcp ls sbx-a
  assert_rc 0
  assert_eq 'No MCP servers tracked for sbx-a.' "$OUT"
}

test_sbxmcp_ls_missing_sandbox() {
  setup_test_env
  run sbxmcp ls no-such
  assert_rc 1
  assert_contains "$ERR" 'sbxmcp: sandbox not found: no-such'
}

test_sbxmcp_add_requires_arguments() {
  setup_test_env
  run sbxmcp add
  assert_rc 2
  assert_contains "$ERR" 'sbxmcp: usage: sbxmcp add SANDBOX SERVER [...]'
  run sbxmcp add sbx-a
  assert_rc 2
  assert_contains "$ERR" 'sbxmcp: usage: sbxmcp add SANDBOX SERVER [...]'
}

test_sbxmcp_add_missing_sandbox() {
  setup_test_env
  make_mcp_server fetch "$HTTP_JSON"
  run sbxmcp add no-such fetch
  assert_rc 1
  assert_contains "$ERR" 'sbxmcp: sandbox not found: no-such'
}

test_sbxmcp_add_rejects_invalid_server_name() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  run sbxmcp add sbx-a 'bad server'
  assert_rc 2
  assert_contains "$ERR" 'sbxmcp: invalid MCP server name: bad server'
}

test_sbxmcp_add_rejects_unregistered_server() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  run sbxmcp add sbx-a nosuch
  assert_rc 2
  assert_contains "$ERR" 'sbxmcp: MCP server is not registered: nosuch'
}

test_sbxmcp_add_attaches_multiple_servers() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_mcp_server fetch "$HTTP_JSON"
  make_mcp_server web '{"name":"web","type":"http","url":"https://example.com/web"}'
  run sbxmcp add sbx-a fetch web
  assert_rc 0
  calls=$(mock_calls)
  assert_contains "$calls" 'mcp load fetch --sandbox sbx-a'
  assert_contains "$calls" 'mcp load web --sandbox sbx-a'
  assert_contains "$ERR" 'Attaching MCP fetch -> sbx-a'
  assert_contains "$ERR" 'Attaching MCP web -> sbx-a'
  assert_eq 'fetch
web' "$(cat "$HOME/.config/sandshell/mcp/sbx-a.servers")"
}

test_sbxmcp_state_is_tracked_per_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_sandbox sbx-b claude stopped "$TEST_TMP/ws/proj"
  make_mcp_server fetch "$HTTP_JSON"
  run sbxmcp add sbx-a fetch
  assert_rc 0
  run sbxmcp ls sbx-b
  assert_rc 0
  assert_eq 'No MCP servers tracked for sbx-b.' "$OUT"
  assert_file_missing "$HOME/.config/sandshell/mcp/sbx-b.servers"
}

test_sbxmcp_copy_applies_source_set_to_target() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_sandbox sbx-b claude stopped "$TEST_TMP/ws/proj"
  make_mcp_server fetch "$HTTP_JSON"
  make_mcp_server web '{"name":"web","type":"http","url":"https://example.com/web"}'
  run sbxmcp add sbx-a fetch web
  assert_rc 0
  run sbxmcp copy sbx-a sbx-b
  assert_rc 0
  calls=$(mock_calls)
  assert_contains "$calls" 'mcp load fetch --sandbox sbx-b'
  assert_contains "$calls" 'mcp load web --sandbox sbx-b'
  assert_contains "$ERR" 'Copying MCP fetch -> sbx-b'
  assert_eq 'fetch
web' "$(cat "$HOME/.config/sandshell/mcp/sbx-b.servers")"
}

test_sbxmcp_copy_rejects_same_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  run sbxmcp copy sbx-a sbx-a
  assert_rc 2
  assert_contains "$ERR" 'sbxmcp: source and target are the same sandbox'
}

test_sbxmcp_copy_missing_sandboxes() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  run sbxmcp copy no-a no-b
  assert_rc 1
  assert_contains "$ERR" 'sbxmcp: source sandbox not found: no-a'
  run sbxmcp copy sbx-a no-b
  assert_rc 1
  assert_contains "$ERR" 'sbxmcp: target sandbox not found: no-b'
}

test_sbxmcp_copy_empty_source_is_noop() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_sandbox sbx-b claude stopped "$TEST_TMP/ws/proj"
  run sbxmcp copy sbx-a sbx-b
  assert_rc 0
  assert_contains "$ERR" 'sbxmcp: no tracked MCP servers for sbx-a'
  assert_not_contains "$(mock_calls)" 'mcp load'
}

test_sbxmcp_vibe_gateway_configuration() {
  setup_test_env
  make_stub vibe
  export MCP_GATEWAY_URL='http://gateway.test:8811'
  export MCP_SENTINEL_TOKEN_NAME='MCP_SENTINEL_TOKEN'
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-vibe docker.io/docker/sbx-kit-vibe:latest stopped "$TEST_TMP/ws/proj"
  make_mcp_server fetch "$HTTP_JSON"
  run sbxmcp add sbx-vibe fetch
  assert_rc 0
  vibe_calls=$(stub_log vibe)
  assert_contains "$vibe_calls" 'mcp add docker-sbx-gateway'
  assert_contains "$vibe_calls" '--url http://gateway.test:8811'
  assert_contains "$vibe_calls" '--transport streamable-http'
  assert_contains "$vibe_calls" '--allow-insecure-http'
  assert_contains "$(mock_calls)" 'mcp load fetch --sandbox sbx-vibe'
  assert_eq 'fetch' "$(cat "$HOME/.config/sandshell/mcp/sbx-vibe.servers")"
}

test_sbxmcp_claude_ollama_gateway_configuration() {
  setup_test_env
  make_stub claude
  export MCP_GATEWAY_URL='http://gateway.test:8811'
  export MCP_SENTINEL_TOKEN_NAME='MCP_SENTINEL_TOKEN'
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-ollama docker.io/sbx/claude-ollama:latest stopped "$TEST_TMP/ws/proj"
  make_mcp_server fetch "$HTTP_JSON"
  run sbxmcp add sbx-ollama fetch
  assert_rc 0
  claude_calls=$(stub_log claude)
  assert_contains "$claude_calls" 'mcp add mcp-gateway http://gateway.test:8811'
  assert_contains "$claude_calls" '--transport http'
  assert_contains "$claude_calls" '--scope user'
  assert_contains "$(mock_calls)" 'mcp load fetch --sandbox sbx-ollama'
}

test_sbxmcp_restores_stopped_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  printf 'NAME\tAGENT\tSTATUS\tWORKSPACE\nsbx-a\tclaude\t○ stopped\t%s\n' \
    "$TEST_TMP/ws/proj" >"$SBX_MOCK_STATE/ls-table"
  make_mcp_server fetch "$HTTP_JSON"
  run sbxmcp add sbx-a fetch
  assert_rc 0
  calls=$(mock_calls)
  assert_contains "$calls" 'ls --format json'
  assert_contains "$calls" 'exec sbx-a true'
  assert_contains "$calls" 'stop sbx-a'
  assert_contains "$ERR" 'sbxmcp: temporarily starting sbx-a without launching the agent'
  assert_eq 'stopped' "$(mock_sandbox_status sbx-a)"
}

test_sbxmcp_running_sandbox_is_not_stopped() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude running "$TEST_TMP/ws/proj"
  printf 'NAME\tAGENT\tSTATUS\tWORKSPACE\nsbx-a\tclaude\t● running\t%s\n' \
    "$TEST_TMP/ws/proj" >"$SBX_MOCK_STATE/ls-table"
  make_mcp_server fetch "$HTTP_JSON"
  run sbxmcp add sbx-a fetch
  assert_rc 0
  assert_contains "$(mock_calls)" 'ls --format json'
  assert_not_contains "$(mock_calls)" 'stop sbx-a'
  assert_eq 'running' "$(mock_sandbox_status sbx-a)"
}

test_sbxmcp_has_no_global_remove_operation() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_sandbox sbx-b claude stopped "$TEST_TMP/ws/proj"
  run sbxmcp remove sbx-a sbx-b
  assert_rc 2
  assert_contains "$ERR" 'sbxmcp: unknown command: remove'
  # no global MCP removal primitives are ever invoked
  assert_not_contains "$(mock_calls)" 'mcp rm'
  assert_not_contains "$(mock_calls)" 'mcp unload'
  assert_not_contains "$(mock_calls)" 'mcp remove'
}

run_tests \
  test_sbxmcp_help \
  test_sbxmcp_help_mentions_local_server_approval \
  test_sbxmcp_rejects_unknown_command \
  test_sbxmcp_subcommand_help_shows_usage \
  test_sbxmcp_subcommand_help_does_not_perform_the_operation \
  test_sbxmcp_missing_sbx_returns_127 \
  test_sbxmcp_ls_lists_host_registry \
  test_sbxmcp_ls_sandbox_lists_tracked_servers \
  test_sbxmcp_ls_sandbox_reports_empty \
  test_sbxmcp_ls_missing_sandbox \
  test_sbxmcp_add_requires_arguments \
  test_sbxmcp_add_missing_sandbox \
  test_sbxmcp_add_rejects_invalid_server_name \
  test_sbxmcp_add_rejects_unregistered_server \
  test_sbxmcp_add_attaches_multiple_servers \
  test_sbxmcp_state_is_tracked_per_sandbox \
  test_sbxmcp_copy_applies_source_set_to_target \
  test_sbxmcp_copy_rejects_same_sandbox \
  test_sbxmcp_copy_missing_sandboxes \
  test_sbxmcp_copy_empty_source_is_noop \
  test_sbxmcp_vibe_gateway_configuration \
  test_sbxmcp_claude_ollama_gateway_configuration \
  test_sbxmcp_restores_stopped_sandbox \
  test_sbxmcp_running_sandbox_is_not_stopped \
  test_sbxmcp_has_no_global_remove_operation
