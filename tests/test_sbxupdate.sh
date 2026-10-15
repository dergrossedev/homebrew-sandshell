#!/usr/bin/env bash
# sbxupdate uses only the deterministic fake sbx; no agents or registries run.
_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

update_fixture() {
  setup_test_env
  mkdir -p "$TEST_TMP/work space"
  cd "$TEST_TMP/work space" || exit 1
  make_sandbox selected "${1:-opencode}" "${2:-running}" "$PWD"
}

test_update_help_usage() {
  setup_test_env
  hide_sbx
  for flag in -h --help; do
    run sbxupdate "$flag"
    assert_rc 0
    assert_contains "$OUT" 'Usage: sbxupdate [SANDBOX]'
    assert_contains "$OUT" 'Update the installed agent CLI in an existing sandbox.'
    assert_contains "$OUT" 'Supports: vibe, opencode, opencode-ollama, claude, claude-ollama, codex.'
  done
  for flag in --all --agent --version ''; do
    run sbxupdate "$flag"
    assert_rc 2
  done
  run sbxupdate one two
  assert_rc 2
  run sbxupdate one --help
  assert_rc 2
  run sbxupdate
  assert_rc 127
}

test_update_explicit_selection() {
  update_fixture
  make_sandbox other vibe stopped "$PWD"
  run sbxupdate selected
  assert_rc 0
  assert_contains "$OUT" 'Updating opencode in selected'
  assert_contains "$(mock_calls)" 'exec -u agent -w /tmp selected opencode upgrade --method npm'
  assert_not_contains "$(mock_calls)" 'exec -u agent -w /tmp other'
  run sbxupdate absent
  assert_rc 1
  assert_contains "$ERR" 'sandbox not found: absent'
}

test_update_workspace_selection() {
  update_fixture
  ln -s "$PWD" "$TEST_TMP/link"
  cd "$TEST_TMP/link" || exit 1
  run sbxupdate
  assert_rc 0
  assert_contains "$OUT" 'Updating opencode in selected'
  make_sandbox second vibe stopped "$PWD"
  run sbxupdate
  assert_rc 2
  assert_contains "$ERR" 'multiple sandboxes'
  assert_contains "$ERR" 'selected'
  assert_contains "$ERR" 'second'
  assert_contains "$ERR" 'specify SANDBOX'
  mkdir -p "$TEST_TMP/other"
  cd "$TEST_TMP/other" || exit 1
  run sbxupdate
  assert_rc 2
  assert_contains "$ERR" 'no sandbox'
  assert_contains "$ERR" 'specify SANDBOX'
}

test_update_listing_failure() {
  update_fixture
  export SBX_MOCK_LS_RC=7
  run sbxupdate selected
  assert_rc 7
  assert_contains "$ERR" 'sandbox listing failed'
  assert_not_contains "$ERR" 'not found'
  run sbxupdate
  assert_rc 7
  run _sbx_sandbox_field selected 2
  assert_rc 7
  assert_not_contains "$(mock_calls)" 'exec '
}

test_update_vibe_dispatch() {
  # Include the real Docker workload identifier as well as existing identities.
  for agent in sbx-kit-vibe vibe docker.io/docker/sbx-kit-vibe:latest; do
    update_fixture "$agent"
    run sbxupdate selected
    assert_rc 0
    assert_contains "$OUT" 'Updating vibe in selected'
    assert_contains "$OUT" 'Before: Mistral Vibe v2.25.5'
    assert_contains "$OUT" 'After:  Mistral Vibe v2.26.1'
    assert_eq 'ls
ls --format json
exec -u agent -w /tmp selected vibe --version
policy ls selected --json --include-inactive
policy allow network --sandbox selected pypi.org:443
policy allow network --sandbox selected files.pythonhosted.org:443
exec -u agent -w /tmp selected uv tool install --force mistral-vibe@latest --with httpx[socks]
exec -u agent -w /tmp selected vibe --version
policy rm network --sandbox selected --resource pypi.org:443 --force
policy rm network --sandbox selected --resource files.pythonhosted.org:443 --force' "$(mock_calls)"
    assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
    assert_eq running "$(mock_sandbox_status selected)"
  done
}

test_update_opencode_ollama_dispatch() {
  update_fixture opencode-ollama
  run sbxupdate selected
  assert_rc 0
  assert_contains "$(mock_calls)" 'selected opencode upgrade --method npm'
  assert_not_contains "$(mock_calls)" 'policy '
  assert_not_contains "$(mock_calls)" 'ollama '
}

test_update_native_dispatch() {
  for agent in claude codex; do
    update_fixture "$agent"
    export SBX_MOCK_VERSION_BEFORE="$agent 1.1.0" SBX_MOCK_VERSION_AFTER="$agent 1.2.0"
    run sbxupdate selected
    assert_rc 0
    assert_contains "$OUT" "Updating $agent in selected"
    assert_contains "$OUT" "Before: $agent 1.1.0"
    assert_contains "$OUT" "After:  $agent 1.2.0"
    assert_eq "ls
ls --format json
exec -u agent -w /tmp selected $agent --version
exec -u agent -w /tmp selected $agent update
exec -u agent -w /tmp selected $agent --version" "$(mock_calls)"
    assert_not_contains "$(mock_calls)" 'policy '
  done
}

test_update_native_updater_failure() {
  for agent in claude codex; do
    update_fixture "$agent"
    export SBX_MOCK_UPDATE_RC=8
    run sbxupdate selected
    assert_rc 8
    assert_contains "$ERR" 'sbxupdate: updater failed for selected (exit 8)'
    assert_contains "$OUT" 'After:'
    assert_not_contains "$OUT" 'restart/resume'
    assert_not_contains "$(mock_calls)" 'policy '
    assert_eq running "$(mock_sandbox_status selected)"
  done
}

test_update_claude_ollama_dispatch_and_policy() {
  update_fixture claude-ollama
  mkdir -p "$SBX_MOCK_STATE/policy"
  printf 'host.docker.internal:11434\nunrelated.example\n' >"$SBX_MOCK_STATE/policy/selected"
  cp "$SBX_MOCK_STATE/policy/selected" "$TEST_TMP/before"
  export CLAUDE_OLLAMA_MODEL='test-model:local'
  export ANTHROPIC_BASE_URL='http://host.docker.internal:11434'
  export ANTHROPIC_AUTH_TOKEN='test-only-placeholder'
  printf 'CLAUDE_OLLAMA_MODEL=%s\nANTHROPIC_BASE_URL=%s\nANTHROPIC_AUTH_TOKEN=%s\n' \
    "$CLAUDE_OLLAMA_MODEL" "$ANTHROPIC_BASE_URL" "$ANTHROPIC_AUTH_TOKEN" >"$SBX_MOCK_STATE/fs/selected/.env"
  cp "$SBX_MOCK_STATE/fs/selected/.env" "$TEST_TMP/config-before"
  export SBX_MOCK_VERSION_BEFORE='Claude Code 1.1.0' SBX_MOCK_VERSION_AFTER='Claude Code 1.2.0'
  run sbxupdate selected
  assert_rc 0
  assert_contains "$OUT" 'Before: Claude Code 1.1.0'
  assert_contains "$OUT" 'After:  Claude Code 1.2.0'
  assert_eq 'ls
ls --format json
exec -u agent -w /tmp selected claude --version
policy ls selected --json --include-inactive
policy allow network --sandbox selected downloads.claude.ai:443
exec -u agent -w /tmp selected claude update
exec -u agent -w /tmp selected claude --version
policy rm network --sandbox selected --resource downloads.claude.ai:443 --force' "$(mock_calls)"
  assert_file_eq "$TEST_TMP/before" "$SBX_MOCK_STATE/policy/selected"
  assert_file_eq "$TEST_TMP/config-before" "$SBX_MOCK_STATE/fs/selected/.env"
  assert_eq 'test-model:local' "$CLAUDE_OLLAMA_MODEL"
  assert_eq 'http://host.docker.internal:11434' "$ANTHROPIC_BASE_URL"
  assert_eq 'test-only-placeholder' "$ANTHROPIC_AUTH_TOKEN"
  assert_eq running "$(mock_sandbox_status selected)"
}

test_update_claude_ollama_preserves_existing_rule() {
  # Both representations are equivalent, including case-insensitive hosts.
  for resource in downloads.claude.ai DOWNLOADS.CLAUDE.AI:443; do
    update_fixture claude-ollama
    mkdir -p "$SBX_MOCK_STATE/policy"
    printf 'host.docker.internal:11434\n%s\nunrelated.example\n' "$resource" >"$SBX_MOCK_STATE/policy/selected"
    cp "$SBX_MOCK_STATE/policy/selected" "$TEST_TMP/before"
    run sbxupdate selected
    assert_rc 0
    assert_contains "$(mock_calls)" 'selected claude update'
    assert_not_contains "$(mock_calls)" 'policy allow'
    assert_not_contains "$(mock_calls)" 'policy rm'
    assert_file_eq "$TEST_TMP/before" "$SBX_MOCK_STATE/policy/selected"
  done
}

test_update_claude_ollama_failure_cleans_rule() {
  update_fixture claude-ollama stopped
  export SBX_MOCK_UPDATE_RC=8
  run sbxupdate selected
  assert_rc 8
  assert_contains "$ERR" 'updater failed'
  assert_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource downloads.claude.ai:443 --force'
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
  assert_eq stopped "$(mock_sandbox_status selected)"
  assert_not_contains "$OUT" 'restart/resume'
}

test_update_claude_ollama_cleanup_failure() {
  update_fixture claude-ollama stopped
  export SBX_MOCK_POLICY_RM_FAIL=downloads.claude.ai:443
  run sbxupdate selected
  assert_rc 1
  assert_contains "$ERR" 'failed to remove temporary rule for downloads.claude.ai:443'
  assert_eq 'downloads.claude.ai:443' "$(cat "$SBX_MOCK_STATE/policy/selected")"
  assert_eq stopped "$(mock_sandbox_status selected)"
  assert_not_contains "$OUT" 'restart/resume'
}

test_update_claude_ollama_stopped_lifecycle() {
  update_fixture claude-ollama stopped
  run sbxupdate selected
  assert_rc 0
  assert_eq 'ls
ls --format json
exec -u agent -w /tmp selected true
exec -u agent -w /tmp selected claude --version
policy ls selected --json --include-inactive
policy allow network --sandbox selected downloads.claude.ai:443
exec -u agent -w /tmp selected claude update
exec -u agent -w /tmp selected claude --version
policy rm network --sandbox selected --resource downloads.claude.ai:443 --force
stop selected' "$(mock_calls)"
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
  assert_eq stopped "$(mock_sandbox_status selected)"
}

test_update_claude_ollama_handled_interruption() {
  update_fixture claude-ollama stopped
  export SBX_MOCK_UPDATE_SIGNAL=TERM
  run sbxupdate selected
  assert_rc 143
  assert_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource downloads.claude.ai:443 --force'
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
  assert_eq stopped "$(mock_sandbox_status selected)"
  assert_not_contains "$OUT" 'restart/resume'
}

test_update_unverified_agents() {
  update_fixture
  for agent in docker.io/sbx/claude-ollama:latest unknown something-vibe-custom sbx-kit-vibe-custom; do
    make_sandbox selected "$agent" stopped "$PWD"
    run sbxupdate selected
    assert_rc 1
    assert_eq "sbxupdate: unsupported update for agent $agent in selected" "$ERR"
    assert_not_contains "$(mock_calls)" 'exec '
    assert_not_contains "$(mock_calls)" 'policy '
  done
}

test_update_updater_failure() {
  update_fixture opencode stopped
  export SBX_MOCK_UPDATE_RC=8
  run sbxupdate selected
  assert_rc 8
  assert_contains "$ERR" 'updater failed'
  assert_contains "$OUT" 'After:'
  assert_not_contains "$OUT" 'restart/resume'
  assert_eq stopped "$(mock_sandbox_status selected)"
}

test_update_version_failure_and_unchanged() {
  update_fixture
  export SBX_MOCK_VERSION_BEFORE_RC=9 SBX_MOCK_VERSION_AFTER_RC=9
  run sbxupdate selected
  assert_rc 0
  assert_contains "$OUT" 'Before: unavailable'
  assert_contains "$OUT" 'After:  unavailable'
  assert_contains "$(mock_calls)" 'opencode upgrade --method npm'
  unset SBX_MOCK_VERSION_BEFORE_RC SBX_MOCK_VERSION_AFTER_RC
  export SBX_MOCK_VERSION_BEFORE='raw version 1.0' SBX_MOCK_VERSION_AFTER='raw version 1.0'
  run sbxupdate selected
  assert_rc 0
  assert_contains "$OUT" 'Before: raw version 1.0'
  assert_contains "$OUT" 'After:  raw version 1.0'
}

test_update_vibe_missing_rules() {
  update_fixture vibe
  run sbxupdate selected
  assert_rc 0
  calls=$(mock_calls)
  assert_contains "$calls" 'policy ls selected --json'
  for resource in pypi.org files.pythonhosted.org; do
    assert_contains "$calls" "policy allow network --sandbox selected $resource:443"
    assert_contains "$calls" "policy rm network --sandbox selected --resource $resource:443 --force"
  done
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
}

test_update_vibe_preserves_existing_rules() {
  update_fixture vibe
  mkdir -p "$SBX_MOCK_STATE/policy"
  printf 'pypi.org\nfiles.pythonhosted.org\nunrelated.example\n' >"$SBX_MOCK_STATE/policy/selected"
  cp "$SBX_MOCK_STATE/policy/selected" "$TEST_TMP/before"
  run sbxupdate selected
  assert_rc 0
  assert_not_contains "$(mock_calls)" 'policy allow'
  assert_not_contains "$(mock_calls)" 'policy rm'
  assert_file_eq "$TEST_TMP/before" "$SBX_MOCK_STATE/policy/selected"
}

test_update_vibe_owns_only_added_rules() {
  update_fixture vibe
  mkdir -p "$SBX_MOCK_STATE/policy"
  printf 'pypi.org\nunrelated.example\n' >"$SBX_MOCK_STATE/policy/selected"
  cp "$SBX_MOCK_STATE/policy/selected" "$TEST_TMP/before"
  run sbxupdate selected
  assert_rc 0
  assert_not_contains "$(mock_calls)" 'policy allow network --sandbox selected pypi.org'
  assert_not_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource pypi.org'
  assert_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource files.pythonhosted.org'
  assert_file_eq "$TEST_TMP/before" "$SBX_MOCK_STATE/policy/selected"
}

test_update_vibe_partial_grant_failure() {
  update_fixture vibe stopped
  export SBX_MOCK_POLICY_ALLOW_FAIL=files.pythonhosted.org:443
  run sbxupdate selected
  assert_rc 1
  assert_contains "$ERR" 'failed to allow files.pythonhosted.org'
  assert_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource pypi.org'
  assert_not_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource files.pythonhosted.org'
  assert_not_contains "$(mock_calls)" 'uv tool install'
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
  assert_eq stopped "$(mock_sandbox_status selected)"
}

test_update_vibe_failure_cleans_rules() {
  update_fixture vibe
  export SBX_MOCK_UPDATE_RC=8
  run sbxupdate selected
  assert_rc 8
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
  assert_contains "$ERR" 'updater failed'
}

test_update_cleanup_failure() {
  update_fixture vibe stopped
  export SBX_MOCK_POLICY_RM_FAIL=pypi.org:443
  run sbxupdate selected
  assert_rc 1
  assert_contains "$ERR" 'failed to remove temporary rule for pypi.org'
  assert_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource files.pythonhosted.org'
  assert_eq stopped "$(mock_sandbox_status selected)"
  export SBX_MOCK_UPDATE_RC=8
  export SBX_MOCK_POLICY_RM_FAIL=files.pythonhosted.org:443
  run sbxupdate selected
  assert_rc 8
  assert_contains "$ERR" 'updater failed'
  assert_contains "$ERR" 'failed to remove temporary rule'
}

test_update_policy_listing_failure() {
  update_fixture vibe stopped
  export SBX_MOCK_POLICY_LS_RC=6
  run sbxupdate selected
  assert_rc 6
  assert_contains "$ERR" 'policy listing failed'
  assert_not_contains "$(mock_calls)" 'policy allow'
  assert_not_contains "$(mock_calls)" 'uv tool install'
  assert_eq stopped "$(mock_sandbox_status selected)"
}

test_update_native_policy_fields() {
  update_fixture vibe
  cat >"$SBX_MOCK_STATE/policy-response.json" <<'JSON'
{
  "rules": [
    {"scope":"global","layer":"local","resource_type":"network","decision":"allow",
     "resources":["pypi.org:443","files.pythonhosted.org:443"],"actions":["net:connect:tcp"]},
    {"scope":"sandbox:other","layer":"local","resource_type":"network","decision":"allow",
     "resources":["files.pythonhosted.org"],"actions":["net:connect:tcp"]},
    {"scope":"sandbox:selected","layer":"org","resource_type":"network","decision":"allow",
     "resources":["files.pythonhosted.org"],"actions":["net:connect:tcp"]},
    {"name":"a } brace and \"quote\"","actions":["net:connect:tcp"],
     "resources":["PYPI.ORG:443","unrelated.example"],"decision":"allow",
     "resource_type":"network","origin":"scoped","layer":"local","status":"inactive",
     "scope":"sandbox:selected","editable":true,
     "provenance":{"created_via":"added","scope":"global","decision":"deny"}}
  ]
}
JSON
  run sbxupdate selected
  assert_rc 0
  assert_not_contains "$(mock_calls)" 'policy allow network --sandbox selected pypi.org'
  assert_not_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource pypi.org'
  assert_contains "$(mock_calls)" 'policy allow network --sandbox selected files.pythonhosted.org:443'
  assert_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource files.pythonhosted.org:443 --force'
}

test_update_conflicting_rules_are_preserved() {
  update_fixture vibe stopped
  # Removing by resource could also affect pre-existing deny/UDP rules.
  for attributes in '"decision":"deny","actions":["net:connect:tcp"]' '"decision":"allow","actions":["net:connect:udp"]'; do
    printf '{"rules":[{"scope":"sandbox:selected","layer":"local","resource_type":"network","resources":["pypi.org:443"],%s}]}\n' "$attributes" >"$SBX_MOCK_STATE/policy-response.json"
    run sbxupdate selected
    assert_rc 1
    assert_contains "$ERR" 'conflicting local rule'
    assert_not_contains "$(mock_calls)" 'policy allow'
    assert_not_contains "$(mock_calls)" 'policy rm'
    assert_not_contains "$(mock_calls)" 'uv tool install'
    assert_eq stopped "$(mock_sandbox_status selected)"
  done
}

test_update_bad_policy_response_fails_closed() {
  update_fixture vibe
  for response in '' '{"policies":[]}' '{"rules":[{"scope":"sandbox:selected"}]}' '{"rules":['; do
    printf '%s\n' "$response" >"$SBX_MOCK_STATE/policy-response.json"
    run sbxupdate selected
    assert_rc 1
    assert_contains "$ERR" 'cannot read network policy rules'
    assert_not_contains "$(mock_calls)" 'policy allow'
    assert_not_contains "$(mock_calls)" 'uv tool install'
  done
}

test_update_handled_interruptions() {
  update_fixture vibe stopped
  export SBX_MOCK_UPDATE_SIGNAL=TERM
  run sbxupdate selected
  assert_rc 143
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
  assert_eq stopped "$(mock_sandbox_status selected)"
  assert_not_contains "$OUT" 'restart/resume'
  unset SBX_MOCK_UPDATE_SIGNAL
  export SBX_MOCK_POLICY_ALLOW_SIGNAL=pypi.org:443
  run sbxupdate selected
  assert_rc 143
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/selected")"
  assert_eq stopped "$(mock_sandbox_status selected)"
  assert_contains "$(mock_calls)" 'policy rm network --sandbox selected --resource pypi.org:443 --force'
}

test_update_partial_start_and_unusable_state() {
  update_fixture opencode stopped
  export SBX_MOCK_START_RC=4
  run sbxupdate selected
  assert_rc 4
  assert_eq stopped "$(mock_sandbox_status selected)"
  assert_not_contains "$(mock_calls)" 'opencode upgrade'
  unset SBX_MOCK_START_RC
  make_sandbox selected opencode broken "$PWD"
  run sbxupdate selected
  assert_rc 1
  assert_contains "$ERR" 'not in a usable state'
}

test_update_lifecycle() {
  update_fixture
  run sbxupdate selected
  assert_rc 0
  assert_eq running "$(mock_sandbox_status selected)"
  assert_not_contains "$(mock_calls)" 'stop selected'
  assert_contains "$OUT" 'restart/resume'
  make_sandbox selected codex stopped "$PWD"
  run sbxupdate selected
  assert_rc 0
  assert_eq stopped "$(mock_sandbox_status selected)"
  assert_contains "$(mock_calls)" 'exec -u agent -w /tmp selected true'
  assert_contains "$(mock_calls)" 'exec -u agent -w /tmp selected codex update'
  assert_contains "$(mock_calls)" 'stop selected'
  assert_not_contains "$(mock_calls)" 'run --name'
}

test_update_decorated_table_lifecycle() {
  for lifecycle in running stopped; do
    update_fixture opencode "$lifecycle"
    if [ "$lifecycle" = running ]; then
      selected_status='● running'; other_status='○ stopped'
    else
      selected_status='○ stopped'; other_status='● running'
    fi
    # Current Docker table output: the status cell contains two words.
    printf 'NAME\tAGENT\tSTATUS\tWORKSPACE\nother\tcodex\t%s\t%s\nselected\topencode\t%s\t%s\n' \
      "$other_status" "$PWD" "$selected_status" "$PWD" >"$SBX_MOCK_STATE/ls-table"
    run sbx ls
    assert_contains "$OUT" '● running'
    assert_contains "$OUT" '○ stopped'
    run sbxupdate selected
    assert_rc 0
    assert_contains "$(mock_calls)" 'ls --format json'
    assert_eq "$lifecycle" "$(mock_sandbox_status selected)"
    assert_contains "$(mock_calls)" 'selected opencode upgrade --method npm'
    if [ "$lifecycle" = stopped ]; then
      assert_contains "$(mock_calls)" 'exec -u agent -w /tmp selected true'
      assert_contains "$(mock_calls)" 'stop selected'
    else
      assert_not_contains "$(mock_calls)" 'exec -u agent -w /tmp selected true'
      assert_not_contains "$(mock_calls)" 'stop selected'
    fi
    assert_not_contains "$ERR" '○'
    assert_not_contains "$ERR" '●'
  done
}

test_update_json_lifecycle_fields() {
  update_fixture
  # Formatting, field order, unrelated entries, and nested fields must not
  # change which direct status belongs to the selected sandbox.
  cat >"$SBX_MOCK_STATE/ls-response.json" <<'JSON'
[
  {"name":"other","id":"other-id","agent":"codex","status":"running"},
  {"status":"starting","workspaces":[{"source":"/tmp/a } brace and \"quote\"","target":"/workspace","name":"selected","status":"running"}],
   "agent":"opencode","id":"selected-id","name":"selected"}
]
JSON
  run sbxupdate selected
  assert_rc 1
  assert_eq 'sbxupdate: sandbox is not in a usable state: selected (starting)' "$ERR"
  assert_not_contains "$(mock_calls)" 'exec '
}

test_update_json_lifecycle_failure() {
  update_fixture
  export SBX_MOCK_LS_JSON_RC=7
  run sbxupdate selected
  assert_rc 7
  assert_not_contains "$(mock_calls)" 'exec '
}

test_update_unreadable_json_lifecycle() {
  update_fixture
  for response in '' '{"sandboxes":[]}' '[{"name":"selected","status":"running"}' \
    '[{"name":"selected","status":"○"}]' '[{"name":"selected","status":"●"}]'; do
    printf '%s\n' "$response" >"$SBX_MOCK_STATE/ls-response.json"
    run sbxupdate selected
    assert_rc 1
    assert_contains "$ERR" 'cannot read sandbox lifecycle state for selected'
    assert_not_contains "$ERR" '○'
    assert_not_contains "$ERR" '●'
    assert_not_contains "$(mock_calls)" 'exec '
  done
}

test_update_restoration_failure() {
  update_fixture opencode stopped
  export SBX_MOCK_STOP_RC=5
  run sbxupdate selected
  assert_rc 1
  assert_contains "$ERR" 'failed to restore stopped state'
  assert_not_contains "$OUT" 'restart/resume'
}

test_update_nounset_cleanup() {
  update_fixture opencode stopped
  make_sandbox vibe-selected vibe stopped "$PWD"
  mkdir -p "$SBX_MOCK_STATE/policy"
  printf 'pypi.org\nfiles.pythonhosted.org\n' >"$SBX_MOCK_STATE/policy/vibe-selected"
  cp "$SBX_MOCK_STATE/policy/vibe-selected" "$TEST_TMP/before"

  # Exercise the current Bash when available, including an isolated Bash 3.2
  # on Linux. A fresh process reproduces EXIT trap scope unwinding.
  update_with_nounset() {
    "${BASH:-/bin/bash}" -u -c '. "$1"; sbxupdate "$2"' sandshell "$SANDSHELL_SH" "$1"
  }
  # Also pin one probe to system Bash for macOS callers using a newer Bash.
  run /bin/bash -u -c '. "$1"; sbxupdate "$2"' sandshell "$SANDSHELL_SH" selected
  assert_rc 0
  assert_not_contains "$ERR" 'unbound variable'
  assert_eq stopped "$(mock_sandbox_status selected)"
  for sandbox in selected vibe-selected; do
    for updater_rc in 0 8; do
      export SBX_MOCK_UPDATE_RC=$updater_rc
      run update_with_nounset "$sandbox"
      assert_rc "$updater_rc"
      assert_not_contains "$ERR" 'unbound variable'
      assert_eq stopped "$(mock_sandbox_status "$sandbox")"
    done
  done
  assert_not_contains "$(mock_calls)" 'policy allow'
  assert_not_contains "$(mock_calls)" 'policy rm'
  assert_file_eq "$TEST_TMP/before" "$SBX_MOCK_STATE/policy/vibe-selected"

  # A nonempty ownership array must still forward every owned resource.
  make_sandbox missing-rules vibe stopped "$PWD"
  run update_with_nounset missing-rules
  assert_rc 8
  assert_eq stopped "$(mock_sandbox_status missing-rules)"
  assert_eq '' "$(cat "$SBX_MOCK_STATE/policy/missing-rules")"
}

test_update_no_trap_option_leakage() {
  update_fixture vibe stopped
  trap ':' INT TERM HUP
  before_traps=$(trap)
  before_options=$(set +o)
  run sbxupdate selected
  assert_rc 0
  assert_eq "$before_traps" "$(trap)"
  assert_eq "$before_options" "$(set +o)"
  assert_file_missing "$HOME/.config/sandshell"
  assert_eq '' "$(ls -A "$PWD")"
}

test_update_mock_rejects_unknown_exec() {
  setup_test_env
  make_sandbox selected vibe running "$TEST_TMP/ws"
  run sbx exec selected unknown-updater
  assert_rc 2
  run sbx exec -u agent -w /tmp selected opencode 'upgrade --method npm'
  assert_rc 2
  run sbx exec -u agent -w /tmp selected uv 'tool install --force mistral-vibe@latest --with httpx[socks]'
  assert_rc 2
  for agent in claude codex; do
    run sbx exec -u agent -w /tmp selected "$agent" update --force
    assert_rc 2
  done
}

run_tests \
  test_update_help_usage \
  test_update_explicit_selection \
  test_update_workspace_selection \
  test_update_listing_failure \
  test_update_vibe_dispatch \
  test_update_opencode_ollama_dispatch \
  test_update_native_dispatch \
  test_update_native_updater_failure \
  test_update_claude_ollama_dispatch_and_policy \
  test_update_claude_ollama_preserves_existing_rule \
  test_update_claude_ollama_failure_cleans_rule \
  test_update_claude_ollama_cleanup_failure \
  test_update_claude_ollama_stopped_lifecycle \
  test_update_claude_ollama_handled_interruption \
  test_update_unverified_agents \
  test_update_updater_failure \
  test_update_version_failure_and_unchanged \
  test_update_vibe_missing_rules \
  test_update_vibe_preserves_existing_rules \
  test_update_vibe_owns_only_added_rules \
  test_update_vibe_partial_grant_failure \
  test_update_vibe_failure_cleans_rules \
  test_update_cleanup_failure \
  test_update_policy_listing_failure \
  test_update_native_policy_fields \
  test_update_conflicting_rules_are_preserved \
  test_update_bad_policy_response_fails_closed \
  test_update_handled_interruptions \
  test_update_partial_start_and_unusable_state \
  test_update_lifecycle \
  test_update_decorated_table_lifecycle \
  test_update_json_lifecycle_fields \
  test_update_json_lifecycle_failure \
  test_update_unreadable_json_lifecycle \
  test_update_restoration_failure \
  test_update_nounset_cleanup \
  test_update_no_trap_option_leakage \
  test_update_mock_rejects_unknown_exec
