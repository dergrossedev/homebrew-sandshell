#!/usr/bin/env bash
# Characterization tests for sbxskill.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

test_sbxskill_help() {
  setup_test_env
  run sbxskill --help
  assert_rc 0
  assert_contains "$OUT" 'sbxskill add SANDBOX SKILL [...]'
  assert_contains "$OUT" 'sbxskill sync SANDBOX'
  assert_contains "$OUT" 'sbxskill copy SOURCE TARGET'
}

test_sbxskill_rejects_unknown_command() {
  setup_test_env
  run sbxskill frobnicate
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: unknown command: frobnicate'
}

test_sbxskill_subcommand_help_shows_usage() {
  setup_test_env
  for sub in available ls add remove sync copy; do
    run sbxskill "$sub" --help
    assert_rc 0 "subcommand: $sub"
    assert_contains "$OUT" 'Usage:' "subcommand: $sub"
    run sbxskill "$sub" -h
    assert_rc 0 "subcommand: $sub"
    assert_contains "$OUT" 'Usage:' "subcommand: $sub"
  done
}

test_sbxskill_missing_sbx_returns_127() {
  setup_test_env
  hide_sbx
  run sbxskill available
  assert_rc 127
  assert_contains "$ERR" 'sbxskill: sbx CLI not found'
}

test_sbxskill_available_lists_catalog() {
  setup_test_env
  make_skill alpha
  make_skill beta
  run sbxskill available
  assert_rc 0
  assert_contains "$OUT" 'alpha'
  assert_contains "$OUT" 'beta'
}

test_sbxskill_available_rejects_arguments() {
  setup_test_env
  run sbxskill available extra
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: usage: sbxskill available'
}

test_sbxskill_ls_lists_selected_skills() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  printf 'alpha\nbeta\n' >"$HOME/.config/sandshell/skills/sbx-a.skills"
  run sbxskill ls sbx-a
  assert_rc 0
  assert_eq 'Selected skills for sbx-a:
alpha
beta' "$OUT"
}

test_sbxskill_ls_reports_empty() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  run sbxskill ls sbx-a
  assert_rc 0
  assert_eq 'No skills selected for sbx-a.' "$OUT"
}

test_sbxskill_ls_missing_sandbox() {
  setup_test_env
  run sbxskill ls no-such
  assert_rc 1
  assert_contains "$ERR" 'sbxskill: sandbox not found: no-such'
}

test_sbxskill_ls_requires_managed_state() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  run sbxskill ls sbx-a
  assert_rc 3
  assert_contains "$ERR" 'sbxskill: sandbox is not using wrapper-managed isolated skills: sbx-a'
}

test_sbxskill_add_copies_multiple_skills() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  make_skill beta
  before=$(store_fingerprint)
  run sbxskill add sbx-a alpha beta
  assert_rc 0
  assert_contains "$ERR" 'Adding skill alpha -> sbx-a'
  assert_contains "$ERR" 'Adding skill beta -> sbx-a'
  assert_eq 'alpha
beta' "$(cat "$HOME/.config/sandshell/skills/sbx-a.skills")"
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills/alpha/SKILL.md"
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills/beta/SKILL.md"
  # host catalog is never modified
  assert_eq "$before" "$(store_fingerprint)"
}

test_sbxskill_add_all_selects_every_skill() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  make_skill beta
  run sbxskill add sbx-a --all
  assert_rc 0
  assert_eq 'alpha
beta' "$(cat "$HOME/.config/sandshell/skills/sbx-a.skills")"
}

test_sbxskill_add_all_rejects_skill_names() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  run sbxskill add sbx-a --all alpha
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: --all cannot be combined with skill names'
}

test_sbxskill_add_skips_already_selected() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  make_skill beta
  run sbxskill add sbx-a alpha
  assert_rc 0
  run sbxskill add sbx-a alpha beta
  assert_rc 0
  assert_contains "$ERR" 'sbxskill: already selected: alpha'
  assert_eq 'alpha
beta' "$(cat "$HOME/.config/sandshell/skills/sbx-a.skills")"
}

test_sbxskill_add_rejects_invalid_skill_name() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  run sbxskill add sbx-a '../evil'
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: invalid skill name: ../evil'
}

test_sbxskill_add_rejects_unavailable_skill() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  mkdir -p "$(_sbx_skill_store)"
  run sbxskill add sbx-a nosuch
  assert_rc 1
  assert_contains "$ERR" 'sbxskill: skill is not available in the shared store: nosuch'
}

test_sbxskill_add_requires_managed_state() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_skill alpha
  run sbxskill add sbx-a alpha
  assert_rc 3
  assert_contains "$ERR" 'sbxskill: sandbox is not using wrapper-managed isolated skills: sbx-a'
}

test_sbxskill_targets_agent_specific_locations() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_skill alpha
  make_sandbox sbx-claude claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-claude
  run sbxskill add sbx-claude alpha
  assert_rc 0
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-claude/home/agent/.claude/skills/alpha/SKILL.md"
  make_sandbox sbx-codex codex stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-codex
  run sbxskill add sbx-codex alpha
  assert_rc 0
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-codex/home/agent/.agents/skills/alpha/SKILL.md"
  make_sandbox sbx-opencode opencode stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-opencode
  run sbxskill add sbx-opencode alpha
  assert_rc 0
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-opencode/home/agent/.agents/skills/alpha/SKILL.md"
  make_sandbox sbx-vibe docker.io/docker/sbx-kit-vibe:latest stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-vibe
  run sbxskill add sbx-vibe alpha
  assert_rc 0
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-vibe/home/agent/.vibe/skills/alpha/SKILL.md"
  make_sandbox sbx-ollama docker.io/sbx/claude-ollama:latest stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-ollama
  run sbxskill add sbx-ollama alpha
  assert_rc 0
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-ollama/home/agent/.claude/skills/alpha/SKILL.md"
}

test_sbxskill_remove_deletes_multiple_skills() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  make_skill beta
  run sbxskill add sbx-a alpha beta
  assert_rc 0
  run sbxskill remove sbx-a alpha beta
  assert_rc 0
  assert_contains "$ERR" 'Removing skill alpha <- sbx-a'
  assert_contains "$ERR" 'Removing skill beta <- sbx-a'
  assert_eq '' "$(cat "$HOME/.config/sandshell/skills/sbx-a.skills")"
  assert_file_missing "$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills/alpha"
  assert_file_missing "$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills/beta"
  # host catalog is never modified
  assert_file_exists "$(_sbx_skill_store)/alpha/SKILL.md"
  assert_file_exists "$(_sbx_skill_store)/beta/SKILL.md"
}

test_sbxskill_remove_all() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  make_skill beta
  run sbxskill add sbx-a alpha beta
  assert_rc 0
  run sbxskill remove sbx-a --all
  assert_rc 0
  assert_eq '' "$(cat "$HOME/.config/sandshell/skills/sbx-a.skills")"
  assert_file_missing "$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills/alpha"
  assert_file_missing "$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills/beta"
}

test_sbxskill_remove_all_rejects_skill_names() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  run sbxskill remove sbx-a --all alpha
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: --all cannot be combined with skill names'
}

test_sbxskill_remove_unmanaged_skill_is_reported() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  make_skill beta
  run sbxskill add sbx-a alpha
  assert_rc 0
  run sbxskill remove sbx-a beta
  assert_rc 0
  assert_contains "$ERR" 'sbxskill: not managed for this sandbox: beta'
  assert_eq 'alpha' "$(cat "$HOME/.config/sandshell/skills/sbx-a.skills")"
}

test_sbxskill_sync_refreshes_from_catalog() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha 'original description'
  run sbxskill add sbx-a alpha
  assert_rc 0
  printf -- '---\nname: alpha\ndescription: updated description\n---\n\n# alpha\n' >"$(_sbx_skill_store)/alpha/SKILL.md"
  run sbxskill sync sbx-a
  assert_rc 0
  assert_contains "$ERR" 'Syncing skill alpha -> sbx-a'
  assert_contains "$(cat "$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills/alpha/SKILL.md")" 'updated description'
}

test_sbxskill_copy_adds_source_selection_to_target() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_sandbox sbx-b claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  init_skill_state sbx-b
  make_skill alpha
  make_skill beta
  run sbxskill add sbx-a alpha beta
  assert_rc 0
  run sbxskill copy sbx-a sbx-b
  assert_rc 0
  assert_eq 'alpha
beta' "$(cat "$HOME/.config/sandshell/skills/sbx-b.skills")"
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-b/home/agent/.claude/skills/alpha/SKILL.md"
  assert_file_exists "$SBX_MOCK_STATE/fs/sbx-b/home/agent/.claude/skills/beta/SKILL.md"
}

test_sbxskill_copy_rejects_same_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  run sbxskill copy sbx-a sbx-a
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: source and target are the same sandbox'
}

test_sbxskill_copy_missing_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  run sbxskill copy no-a no-b
  assert_rc 1
  assert_contains "$ERR" 'sbxskill: source sandbox not found: no-a'
  run sbxskill copy sbx-a no-b
  assert_rc 1
  assert_contains "$ERR" 'sbxskill: target sandbox not found: no-b'
}

test_sbxskill_state_is_isolated_per_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  make_sandbox sbx-b claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  init_skill_state sbx-b
  make_skill alpha
  run sbxskill add sbx-a alpha
  assert_rc 0
  run sbxskill ls sbx-b
  assert_rc 0
  assert_eq 'No skills selected for sbx-b.' "$OUT"
  assert_file_missing "$SBX_MOCK_STATE/fs/sbx-b/home/agent/.claude/skills/alpha"
}

test_sbxskill_rejects_vibe_incompatible_skill() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-vibe docker.io/docker/sbx-kit-vibe:latest stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-vibe
  long_desc=$(head -c 1100 /dev/zero | tr '\0' x)
  make_skill bigskill "$long_desc"
  before=$(store_fingerprint)
  run sbxskill add sbx-vibe bigskill
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: Vibe-incompatible skill metadata: bigskill'
  assert_eq '' "$(cat "$HOME/.config/sandshell/skills/sbx-vibe.skills")"
  assert_eq "$before" "$(store_fingerprint)"
  assert_file_missing "$SBX_MOCK_STATE/fs/sbx-vibe/home/agent/.vibe/skills/bigskill"
}

test_sbxskill_refuses_to_replace_symlinked_skill() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  target_dir="$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills"
  mkdir -p "$target_dir"
  ln -s "$(_sbx_skill_store)/alpha" "$target_dir/alpha"
  run sbxskill add sbx-a alpha
  assert_rc 42
  assert_contains "$ERR" 'sbxskill: refusing to replace shared/symlinked skill: alpha'
  assert_eq '' "$(cat "$HOME/.config/sandshell/skills/sbx-a.skills")"
}

test_sbxskill_refuses_to_overwrite_existing_skill() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  target_dir="$SBX_MOCK_STATE/fs/sbx-a/home/agent/.claude/skills"
  mkdir -p "$target_dir/alpha"
  run sbxskill add sbx-a alpha
  assert_rc 43
  assert_contains "$ERR" 'sbxskill: skill path already exists; refusing to overwrite: alpha'
  assert_eq '' "$(cat "$HOME/.config/sandshell/skills/sbx-a.skills")"
}

test_sbxskill_restores_stopped_sandbox() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj"
  make_sandbox sbx-a claude stopped "$TEST_TMP/ws/proj"
  init_skill_state sbx-a
  make_skill alpha
  run sbxskill add sbx-a alpha
  assert_rc 0
  calls=$(mock_calls)
  assert_contains "$calls" 'exec sbx-a true'
  assert_contains "$calls" 'stop sbx-a'
  assert_contains "$ERR" 'sbxskill: temporarily starting sbx-a without launching the agent'
  assert_eq 'stopped' "$(mock_sandbox_status sbx-a)"
}

test_sbxskill_usage_errors() {
  setup_test_env
  run sbxskill ls
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: usage: sbxskill ls SANDBOX'
  run sbxskill add sbx-a
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: usage: sbxskill add SANDBOX SKILL [...] | --all'
  run sbxskill remove sbx-a
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: usage: sbxskill remove SANDBOX SKILL [...] | --all'
  run sbxskill sync
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: usage: sbxskill sync SANDBOX'
  run sbxskill copy sbx-a
  assert_rc 2
  assert_contains "$ERR" 'sbxskill: usage: sbxskill copy SOURCE TARGET'
}

run_tests \
  test_sbxskill_help \
  test_sbxskill_rejects_unknown_command \
  test_sbxskill_subcommand_help_shows_usage \
  test_sbxskill_missing_sbx_returns_127 \
  test_sbxskill_available_lists_catalog \
  test_sbxskill_available_rejects_arguments \
  test_sbxskill_ls_lists_selected_skills \
  test_sbxskill_ls_reports_empty \
  test_sbxskill_ls_missing_sandbox \
  test_sbxskill_ls_requires_managed_state \
  test_sbxskill_add_copies_multiple_skills \
  test_sbxskill_add_all_selects_every_skill \
  test_sbxskill_add_all_rejects_skill_names \
  test_sbxskill_add_skips_already_selected \
  test_sbxskill_add_rejects_invalid_skill_name \
  test_sbxskill_add_rejects_unavailable_skill \
  test_sbxskill_add_requires_managed_state \
  test_sbxskill_targets_agent_specific_locations \
  test_sbxskill_remove_deletes_multiple_skills \
  test_sbxskill_remove_all \
  test_sbxskill_remove_all_rejects_skill_names \
  test_sbxskill_remove_unmanaged_skill_is_reported \
  test_sbxskill_sync_refreshes_from_catalog \
  test_sbxskill_copy_adds_source_selection_to_target \
  test_sbxskill_copy_rejects_same_sandbox \
  test_sbxskill_copy_missing_sandbox \
  test_sbxskill_state_is_isolated_per_sandbox \
  test_sbxskill_rejects_vibe_incompatible_skill \
  test_sbxskill_refuses_to_replace_symlinked_skill \
  test_sbxskill_refuses_to_overwrite_existing_skill \
  test_sbxskill_restores_stopped_sandbox \
  test_sbxskill_usage_errors
