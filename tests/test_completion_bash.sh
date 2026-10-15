#!/usr/bin/env bash
# Tests for completions/sandshell.bash (native Bash completion).
#
# The completion file is exercised through a real Bash subprocess: each test
# sources the file, sets COMP_WORDS/COMP_CWORD, invokes the completion
# function, and prints COMPREPLY. Dynamic lookups run against the mock sbx and
# the isolated test HOME, so no real Docker/SBX state is touched.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

COMPLETIONS_BASH="$SANDSHELL_ROOT/completions/sandshell.bash"
BASH_BIN=$(command -v bash)

# bash_complete FUNC WORD... — run a Bash completion function in a fresh Bash
# and print the resulting COMPREPLY, one candidate per line. The completion
# file is sourced standalone (sandshell.sh is not needed). stderr of the run
# lands in $TEST_TMP/.comp-err. COMPLETION_CWD, when exported, is the working
# directory of the completion run.
bash_complete() {
  local func=$1
  shift
  "$BASH_BIN" -c '
    . "$1" || exit 9
    shift
    if [ -n "${COMPLETION_CWD:-}" ]; then cd "$COMPLETION_CWD" || exit 9; fi
    COMP_WORDS=("$@")
    COMP_CWORD=$(( $# - 1 ))
    "$0"
    for c in "${COMPREPLY[@]}"; do printf "%s\n" "$c"; done
  ' "$func" "$COMPLETIONS_BASH" "$@" 2>"$TEST_TMP/.comp-err"
}

comp_err() {
  cat "$TEST_TMP/.comp-err" 2>/dev/null
}

assert_comp_set() { # EXPECTED_NEWLINES ACTUAL_NEWLINES
  local expected actual
  expected=$(printf '%s\n' "$1" | sort)
  actual=$(printf '%s\n' "$2" | sort)
  assert_eq "$expected" "$actual" 'completion candidate sets differ'
}

# --- loading ------------------------------------------------------------------

test_bash_syntax() {
  setup_test_env
  run "$BASH_BIN" -n "$COMPLETIONS_BASH"
  assert_rc 0
}

test_bash_source_is_silent_and_registers() {
  setup_test_env
  reg=$("$BASH_BIN" -c '. "$1" && complete -p sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxupdate sbxcmd' _ "$COMPLETIONS_BASH" 2>"$TEST_TMP/.comp-err")
  assert_contains "$reg" 'complete -F _sandshell_sbxc sbxc'
  assert_contains "$reg" 'complete -F _sandshell_sbxr sbxr'
  assert_contains "$reg" 'complete -F _sandshell_sbxupdate sbxupdate'
  assert_contains "$reg" 'complete -F _sandshell_sbxenv sbxenv'
  assert_contains "$reg" 'complete -F _sandshell_sbxmcp sbxmcp'
  assert_contains "$reg" 'complete -F _sandshell_sbxskill sbxskill'
  assert_contains "$reg" 'complete -F _sandshell_sbxwt sbxwt'
  assert_contains "$reg" 'complete -F _sandshell_sbxcmd sbxcmd'
  assert_eq '' "$(cat "$TEST_TMP/.comp-err")"
}

test_bash_source_produces_no_output() {
  setup_test_env
  out=$("$BASH_BIN" -c '. "$1"' _ "$COMPLETIONS_BASH" 2>"$TEST_TMP/.comp-err")
  assert_comp '' "$out"
  assert_eq '' "$(cat "$TEST_TMP/.comp-err")"
}

# --- sbxc ---------------------------------------------------------------------

test_bash_sbxc_options() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxc sbxc --)
  assert_comp '--help --agent --dir --size --name --clone --env-file --model' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc -)
  assert_comp '-h --help -a --agent -d --dir -s --size -n --name --clone --env-file --model' "$out"
}

test_bash_sbxc_agent_values() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxc sbxc -a '')
  assert_comp 'claude codex opencode vibe claude-ollama opencode-ollama' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc --agent '')
  assert_comp 'claude codex opencode vibe claude-ollama opencode-ollama' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc -a cl)
  assert_comp 'claude claude-ollama' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc -a open)
  assert_comp 'opencode opencode-ollama' "$out"
}

test_bash_sbxc_model_option() {
  setup_test_env
  # --model is offered as an option ...
  out=$(bash_complete _sandshell_sbxc sbxc --)
  assert_comp '--help --agent --dir --size --name --clone --env-file --model' "$out"
  # ... but its value is free text (no candidates).
  out=$(bash_complete _sandshell_sbxc sbxc --model '')
  assert_comp '' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc -a opencode-ollama --model '')
  assert_comp '' "$out"
}

test_bash_sbxc_size_values() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxc sbxc -s '')
  assert_comp 'micro small medium' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc --size '')
  assert_comp 'micro small medium' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc -s me)
  assert_comp 'medium' "$out"
}

test_bash_sbxc_name_value_has_no_completion() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxc sbxc -n '')
  assert_comp '' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc --name '')
  assert_comp '' "$out"
}

# --- sbxr ---------------------------------------------------------------------

test_bash_sbxr_options() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxr sbxr --)
  assert_comp '--help --all --env-file' "$out"
  out=$(bash_complete _sandshell_sbxr sbxr -)
  assert_comp '-h --help --all --env-file' "$out"
}

test_bash_sbxr_sandbox_names() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_sandbox beta codex stopped "$TEST_TMP/ws"
  out=$(bash_complete _sandshell_sbxr sbxr '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxr sbxr al)
  assert_comp 'alpha' "$out"
  # After --all the same sandbox names are offered (a harmless superset).
  out=$(bash_complete _sandshell_sbxr sbxr --all '')
  assert_comp 'alpha beta' "$out"
  # Dynamic candidates come from the mock sbx, never a real one.
  assert_contains "$(mock_calls)" 'ls -q'
}

# --- sbxenv -------------------------------------------------------------------

test_bash_sbxupdate() {
  setup_test_env
  make_sandbox alpha vibe stopped "$TEST_TMP/ws"
  make_sandbox beta opencode stopped "$TEST_TMP/ws"
  out=$(bash_complete _sandshell_sbxupdate sbxupdate -)
  assert_comp '-h --help' "$out"
  out=$(bash_complete _sandshell_sbxupdate sbxupdate '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxupdate sbxupdate al)
  assert_comp 'alpha' "$out"
  out=$(bash_complete _sandshell_sbxupdate sbxupdate alpha '')
  assert_comp '' "$out"
  assert_eq 'ls -q
ls -q' "$(mock_calls)"
  export SBX_MOCK_LS_RC=7
  out=$(bash_complete _sandshell_sbxupdate sbxupdate '')
  assert_comp '' "$out"
  assert_eq '' "$(comp_err)"
  hide_sbx
  out=$(bash_complete _sandshell_sbxupdate sbxupdate '')
  assert_comp '' "$out"
  assert_eq '' "$(comp_err)"
}

test_bash_sbxenv() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxenv sbxenv --)
  assert_comp '--help' "$out"
  out=$(bash_complete _sandshell_sbxenv sbxenv -)
  assert_comp '-h --help' "$out"
  out=$(bash_complete _sandshell_sbxenv sbxenv '')
  printf '%s\n' "$out" | grep -qx cat || assert_fail 'expected cat in editor completion'
  printf '%s\n' "$out" | grep -qx sbx || assert_fail 'expected sbx in editor completion'
  out=$(bash_complete _sandshell_sbxenv sbxenv vim '')
  assert_comp '' "$out"
}

# --- sbxmcp -------------------------------------------------------------------

test_bash_sbxmcp_subcommands() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxmcp sbxmcp '')
  assert_comp 'ls add copy -h --help' "$out"
  out=$(bash_complete _sandshell_sbxmcp sbxmcp -)
  assert_comp '-h --help' "$out"
}

test_bash_sbxmcp_sandbox_arguments() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_sandbox beta codex stopped "$TEST_TMP/ws"
  out=$(bash_complete _sandshell_sbxmcp sbxmcp ls '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxmcp sbxmcp add '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxmcp sbxmcp copy '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxmcp sbxmcp copy alpha '')
  assert_comp 'alpha beta' "$out"
}

test_bash_sbxmcp_server_names() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_mcp_server github '{}'
  make_mcp_server fetch '{}'
  out=$(bash_complete _sandshell_sbxmcp sbxmcp add alpha '')
  assert_comp 'fetch github' "$out"
  # Already-typed server names are not suggested again.
  out=$(bash_complete _sandshell_sbxmcp sbxmcp add alpha github '')
  assert_comp 'fetch' "$out"
  out=$(bash_complete _sandshell_sbxmcp sbxmcp add alpha github fetch '')
  assert_comp '' "$out"
}

# --- sbxskill -----------------------------------------------------------------

test_bash_sbxskill_subcommands() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxskill sbxskill '')
  assert_comp 'available ls add remove sync copy -h --help' "$out"
  out=$(bash_complete _sandshell_sbxskill sbxskill -)
  assert_comp '-h --help' "$out"
}

test_bash_sbxskill_sandbox_arguments() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_sandbox beta codex stopped "$TEST_TMP/ws"
  out=$(bash_complete _sandshell_sbxskill sbxskill ls '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxskill sbxskill sync '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxskill sbxskill copy '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxskill sbxskill copy alpha '')
  assert_comp 'alpha beta' "$out"
}

test_bash_sbxskill_available_skills() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_skill skill-a
  make_skill skill-b
  out=$(bash_complete _sandshell_sbxskill sbxskill add alpha '')
  assert_comp '--all skill-a skill-b' "$out"
  # Already-typed skills are not suggested again; --all remains offered.
  out=$(bash_complete _sandshell_sbxskill sbxskill add alpha skill-a '')
  assert_comp '--all skill-b' "$out"
  out=$(bash_complete _sandshell_sbxskill sbxskill add alpha --all '')
  assert_comp '' "$out"
  out=$(bash_complete _sandshell_sbxskill sbxskill add alpha -)
  assert_comp '--all' "$out"
}

test_bash_sbxskill_tracked_skills() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_skill skill-a
  make_skill skill-b
  init_skill_state alpha
  printf 'skill-a\nskill-b\n' >>"$HOME/.config/sandshell/skills/alpha.skills"
  out=$(bash_complete _sandshell_sbxskill sbxskill remove alpha '')
  assert_comp '--all skill-a skill-b' "$out"
  out=$(bash_complete _sandshell_sbxskill sbxskill remove alpha skill-a '')
  assert_comp '--all skill-b' "$out"
}

# --- sbxwt --------------------------------------------------------------------

test_bash_sbxwt_subcommands() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxwt sbxwt '')
  assert_comp 'create ls commit merge done -h --help' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt -)
  assert_comp '-h --help' "$out"
}

test_bash_sbxwt_create_options() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxwt sbxwt create -)
  assert_comp '-a --agent -s --size --base --env-file' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt create -a '')
  assert_comp 'claude codex opencode vibe claude-ollama opencode-ollama' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt create --agent '')
  assert_comp 'claude codex opencode vibe claude-ollama opencode-ollama' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt create -s '')
  assert_comp 'micro small medium' "$out"
}

test_bash_sbxwt_branches() {
  setup_test_env
  make_git_repo "$TEST_TMP/repo"
  git -C "$TEST_TMP/repo" branch feature-x
  COMPLETION_CWD="$TEST_TMP/repo"
  export COMPLETION_CWD
  out=$(bash_complete _sandshell_sbxwt sbxwt create '')
  assert_comp 'feature-x main' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt create --base '')
  assert_comp 'feature-x main' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt merge wt-one --into '')
  assert_comp 'feature-x main' "$out"
}

test_bash_sbxwt_managed_sandboxes() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_sandbox wt-one claude stopped "$TEST_TMP/ws"
  make_sandbox wt-two codex stopped "$TEST_TMP/ws"
  mkdir -p "$HOME/.config/sandshell/worktrees"
  : >"$HOME/.config/sandshell/worktrees/wt-one.meta"
  : >"$HOME/.config/sandshell/worktrees/wt-two.meta"
  out=$(bash_complete _sandshell_sbxwt sbxwt commit '')
  assert_comp 'wt-one wt-two' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt merge '')
  assert_comp 'wt-one wt-two' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt 'done' '')
  assert_comp 'wt-one wt-two' "$out"
}

test_bash_sbxwt_commit_and_merge_options() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxwt sbxwt commit wt-one -)
  assert_comp '-m' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt commit wt-one -m '')
  assert_comp '' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt merge wt-one -)
  assert_comp '--into' "$out"
}

# --- sbxcmd -------------------------------------------------------------------

test_bash_sbxcmd() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxcmd sbxcmd -)
  assert_comp '-h --help' "$out"
  out=$(bash_complete _sandshell_sbxcmd sbxcmd '')
  assert_comp '-h --help' "$out"
}

# --- file and directory completion --------------------------------------------

test_bash_file_and_dir_completion() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/subdir"
  : >"$TEST_TMP/ws/env.txt"
  COMPLETION_CWD="$TEST_TMP/ws"
  export COMPLETION_CWD
  out=$(bash_complete _sandshell_sbxc sbxc -d '')
  assert_comp 'subdir' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc --dir '')
  assert_comp 'subdir' "$out"
  out=$(bash_complete _sandshell_sbxc sbxc --env-file '')
  assert_comp_set 'env.txt
subdir' "$out"
  out=$(bash_complete _sandshell_sbxr sbxr --env-file '')
  assert_comp_set 'env.txt
subdir' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt create --env-file '')
  assert_comp_set 'env.txt
subdir' "$out"
}

# --- safety -------------------------------------------------------------------

test_bash_loads_and_completes_without_sbx() {
  setup_test_env
  hide_sbx
  reg=$("$BASH_BIN" -c '. "$1" && complete -p sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxcmd' _ "$COMPLETIONS_BASH" 2>/dev/null)
  assert_contains "$reg" 'complete -F _sandshell_sbxc sbxc'
  assert_contains "$reg" 'complete -F _sandshell_sbxcmd sbxcmd'
  out=$(bash_complete _sandshell_sbxr sbxr '')
  assert_comp '' "$out"
  out=$(bash_complete _sandshell_sbxmcp sbxmcp add alpha '')
  assert_comp '' "$out"
  out=$(bash_complete _sandshell_sbxskill sbxskill ls '')
  assert_comp '' "$out"
  assert_eq '' "$(comp_err)"
  # Static completion still works without sbx.
  out=$(bash_complete _sandshell_sbxc sbxc -a '')
  assert_comp 'claude codex opencode vibe claude-ollama opencode-ollama' "$out"
  # Skill-store completion does not need sbx either.
  make_skill skill-a
  out=$(bash_complete _sandshell_sbxskill sbxskill add alpha '')
  assert_comp '--all skill-a' "$out"
}

test_bash_failing_sbx_fails_silently() {
  setup_test_env
  rm -f "$TEST_TMP/bin/sbx"
  printf '#!/bin/sh\nprintf "sbx: boom\\n" >&2\nexit 1\n' >"$TEST_TMP/bin/sbx"
  chmod +x "$TEST_TMP/bin/sbx"
  out=$(bash_complete _sandshell_sbxr sbxr '')
  assert_comp '' "$out"
  out=$(bash_complete _sandshell_sbxmcp sbxmcp add alpha '')
  assert_comp '' "$out"
  assert_eq '' "$(comp_err)"
}

test_bash_missing_git_fails_silently() {
  setup_test_env
  hide_git
  out=$(bash_complete _sandshell_sbxwt sbxwt create '')
  assert_comp '' "$out"
  assert_eq '' "$(comp_err)"
}

test_bash_completion_is_read_only() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_sandbox beta codex stopped "$TEST_TMP/ws"
  make_mcp_server github '{}'
  make_skill skill-a
  init_skill_state alpha
  printf 'skill-a\n' >>"$HOME/.config/sandshell/skills/alpha.skills"
  mkdir -p "$HOME/.config/sandshell/worktrees"
  : >"$HOME/.config/sandshell/worktrees/wt-one.meta"
  make_git_repo "$TEST_TMP/repo"
  git -C "$TEST_TMP/repo" branch feature-x
  COMPLETION_CWD="$TEST_TMP/repo"
  export COMPLETION_CWD
  # Sanity: the completions under test actually produce candidates.
  out=$(bash_complete _sandshell_sbxr sbxr '')
  assert_comp 'alpha beta' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt commit '')
  assert_comp 'wt-one' "$out"
  fp1=$(store_fingerprint)
  tree1=$(tree_fingerprint "$HOME/.config/sandshell")
  bash_complete _sandshell_sbxr sbxr '' >/dev/null
  bash_complete _sandshell_sbxmcp sbxmcp add alpha '' >/dev/null
  bash_complete _sandshell_sbxskill sbxskill add alpha '' >/dev/null
  bash_complete _sandshell_sbxskill sbxskill remove alpha '' >/dev/null
  bash_complete _sandshell_sbxwt sbxwt commit '' >/dev/null
  bash_complete _sandshell_sbxwt sbxwt create '' >/dev/null
  fp2=$(store_fingerprint)
  tree2=$(tree_fingerprint "$HOME/.config/sandshell")
  assert_eq "$fp1" "$fp2"
  assert_eq "$tree1" "$tree2"
  # The mock sbx must only ever see read-only queries.
  bad=$(grep -v -e '^ls -q$' -e '^mcp ls$' "$SBX_MOCK_STATE/calls.log" 2>/dev/null || true)
  assert_eq '' "$bad"
}

test_bash_completion_creates_no_config() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxskill sbxskill remove alpha '')
  assert_comp '--all' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt commit '')
  assert_comp '' "$out"
  assert_file_missing "$HOME/.config/sandshell"
}

test_bash_config_root_precedence() {
  setup_test_env
  mkdir -p "$TEST_TMP/custom/skills"
  printf 'skill-x\n' >"$TEST_TMP/custom/skills/alpha.skills"
  SANDSHELL_CONFIG_HOME="$TEST_TMP/custom"
  export SANDSHELL_CONFIG_HOME
  out=$(bash_complete _sandshell_sbxskill sbxskill remove alpha '')
  assert_comp '--all skill-x' "$out"
  unset SANDSHELL_CONFIG_HOME
  mkdir -p "$TEST_TMP/xdg/sandshell/skills"
  printf 'skill-y\n' >"$TEST_TMP/xdg/sandshell/skills/alpha.skills"
  XDG_CONFIG_HOME="$TEST_TMP/xdg"
  export XDG_CONFIG_HOME
  out=$(bash_complete _sandshell_sbxskill sbxskill remove alpha '')
  assert_comp '--all skill-y' "$out"
}

test_bash_missing_config_dir_yields_no_dynamic_candidates() {
  setup_test_env
  out=$(bash_complete _sandshell_sbxskill sbxskill remove alpha '')
  assert_comp '--all' "$out"
  out=$(bash_complete _sandshell_sbxwt sbxwt commit '')
  assert_comp '' "$out"
  assert_eq '' "$(comp_err)"
}

run_tests \
  test_bash_syntax \
  test_bash_source_is_silent_and_registers \
  test_bash_source_produces_no_output \
  test_bash_sbxc_options \
  test_bash_sbxc_agent_values \
  test_bash_sbxc_model_option \
  test_bash_sbxc_size_values \
  test_bash_sbxc_name_value_has_no_completion \
  test_bash_sbxr_options \
  test_bash_sbxr_sandbox_names \
  test_bash_sbxupdate \
  test_bash_sbxenv \
  test_bash_sbxmcp_subcommands \
  test_bash_sbxmcp_sandbox_arguments \
  test_bash_sbxmcp_server_names \
  test_bash_sbxskill_subcommands \
  test_bash_sbxskill_sandbox_arguments \
  test_bash_sbxskill_available_skills \
  test_bash_sbxskill_tracked_skills \
  test_bash_sbxwt_subcommands \
  test_bash_sbxwt_create_options \
  test_bash_sbxwt_branches \
  test_bash_sbxwt_managed_sandboxes \
  test_bash_sbxwt_commit_and_merge_options \
  test_bash_sbxcmd \
  test_bash_file_and_dir_completion \
  test_bash_loads_and_completes_without_sbx \
  test_bash_failing_sbx_fails_silently \
  test_bash_missing_git_fails_silently \
  test_bash_completion_is_read_only \
  test_bash_completion_creates_no_config \
  test_bash_config_root_precedence \
  test_bash_missing_config_dir_yields_no_dynamic_candidates
