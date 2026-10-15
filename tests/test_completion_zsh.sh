#!/usr/bin/env bash
# Tests for completions/_sandshell (native Zsh completion).
#
# Generator helpers are exercised in a `zsh -f` subprocess with a stubbed
# compadd that prints the candidates it receives, and the file is loaded
# through a real compinit in a clean Zsh. Dynamic lookups run against the
# mock sbx and the isolated test HOME, so no real Docker/SBX state is touched.
# Pressing TAB in a real interactive shell is a manual release smoke test
# (RELEASING.md).

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

if ! command -v zsh >/dev/null 2>&1; then
  printf 'zsh not found; skipping Zsh completion tests\n'
  exit 0
fi

COMPLETIONS_ZSH="$SANDSHELL_ROOT/completions/_sandshell"
COMPLETIONS_DIR="$SANDSHELL_ROOT/completions"
ZSH_BIN=$(command -v zsh)

# zsh_gen FUNC [ARGS...] — run a completion helper in a fresh `zsh -f` with a
# stubbed compadd and print the candidates it received, one per line. The
# completion file is sourced standalone (sandshell.sh is not needed); one
# bootstrap call to _sandshell defines the nested helpers. stderr of the run
# lands in $TEST_TMP/.zgen-err. COMPLETION_CWD, when exported, is the working
# directory of the run.
#
# The child re-asserts the test PATH as its first action: Zsh sources
# /etc/zshenv even with -f, and on macOS path_helper reorders PATH so system
# directories come first. Baking the current PATH in keeps the mock sbx (or
# its absence, after hide_sbx/hide_git) authoritative in the child.
zsh_gen() {
  local func=$1
  shift
  "$ZSH_BIN" -f -c '
    PATH=$1; export PATH
    shift
    . "$1" || exit 9
    shift
    if [ -n "${COMPLETION_CWD:-}" ]; then cd "$COMPLETION_CWD" || exit 9; fi
    compadd() {
      local w
      for w in "$@"; do
        case $w in
          --) ;;
          *) printf "%s\n" "$w" ;;
        esac
      done
    }
    _arguments() { printf "%s\n" "$@"; }
    service=${COMPLETION_SERVICE:-sbxcmd}
    _sandshell >/dev/null
    "$0" "$@"
  ' "$func" "$PATH" "$COMPLETIONS_ZSH" "$@" 2>"$TEST_TMP/.zgen-err"
}

zgen_err() {
  cat "$TEST_TMP/.zgen-err" 2>/dev/null
}

# --- loading ------------------------------------------------------------------

test_zsh_syntax() {
  setup_test_env
  run "$ZSH_BIN" -n "$COMPLETIONS_ZSH"
  assert_rc 0
}

test_zsh_registers_all_commands_via_compinit() {
  setup_test_env
  # The first arg after the -c script becomes $0 in zsh, so pass a placeholder
  # name and the completions dir as $1.
  run "$ZSH_BIN" -f -c '
    fpath=("$1" $fpath)
    autoload -U compinit
    compinit -i -D
    for c in sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxupdate sbxcmd; do
      printf "%s=%s\n" "$c" "${_comps[$c]}"
    done
  ' _sandshell "$COMPLETIONS_DIR"
  assert_rc 0
  assert_contains "$OUT" 'sbxc=_sandshell'
  assert_contains "$OUT" 'sbxr=_sandshell'
  assert_contains "$OUT" 'sbxupdate=_sandshell'
  assert_contains "$OUT" 'sbxenv=_sandshell'
  assert_contains "$OUT" 'sbxmcp=_sandshell'
  assert_contains "$OUT" 'sbxskill=_sandshell'
  assert_contains "$OUT" 'sbxwt=_sandshell'
  assert_contains "$OUT" 'sbxcmd=_sandshell'
}

test_zsh_file_does_not_run_compinit_or_zstyle() {
  setup_test_env
  assert_file_exists "$COMPLETIONS_ZSH"
  if grep -vE '^[[:space:]]*(#|$)' "$COMPLETIONS_ZSH" | grep -E 'compinit|zstyle'; then
    assert_fail 'completion file must not initialize completion or set styles'
  fi
}

# --- dynamic generators ---------------------------------------------------------

test_zsh_sandboxes() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_sandbox beta codex stopped "$TEST_TMP/ws"
  out=$(zsh_gen _sandshell_sandboxes)
  assert_comp 'alpha beta' "$out"
  out=$(zsh_gen _sandshell_sandboxes alpha)
  assert_comp 'beta' "$out"
  # Dynamic candidates come from the mock sbx, never a real one.
  assert_contains "$(mock_calls)" 'ls -q'
}

test_zsh_sbxupdate() {
  setup_test_env
  out=$(zsh_gen _sandshell_sbxupdate)
  assert_contains "$out" '(-h --help)-h[show help]'
  assert_contains "$out" '(-h --help)--help[show help]'
  assert_contains "$out" '1:sandbox:_sandshell_sandboxes'
  assert_not_contains "$out" '--all'
  assert_not_contains "$out" '2:'
  assert_eq '' "$(zgen_err)"
  assert_eq '' "$(mock_calls)"
  export COMPLETION_SERVICE=sbxupdate
  out=$(zsh_gen _sandshell)
  assert_contains "$out" '1:sandbox:_sandshell_sandboxes'
  assert_eq '' "$(zgen_err)"
}

test_zsh_mcp_servers() {
  setup_test_env
  make_mcp_server github '{}'
  make_mcp_server fetch '{}'
  out=$(zsh_gen _sandshell_mcp_servers)
  assert_comp 'fetch github' "$out"
  out=$(zsh_gen _sandshell_mcp_servers github)
  assert_comp 'fetch' "$out"
}

test_zsh_skills_available() {
  setup_test_env
  make_skill skill-a
  make_skill skill-b
  out=$(zsh_gen _sandshell_skills_available)
  assert_comp 'skill-a skill-b' "$out"
  out=$(zsh_gen _sandshell_skills_available skill-a)
  assert_comp 'skill-b' "$out"
}

test_zsh_skills_tracked() {
  setup_test_env
  init_skill_state alpha
  printf 'skill-a\nskill-b\n' >>"$HOME/.config/sandshell/skills/alpha.skills"
  out=$(zsh_gen _sandshell_skills_tracked alpha)
  assert_comp 'skill-a skill-b' "$out"
  out=$(zsh_gen _sandshell_skills_tracked alpha skill-a)
  assert_comp 'skill-b' "$out"
}

test_zsh_managed_sandboxes() {
  setup_test_env
  mkdir -p "$HOME/.config/sandshell/worktrees"
  : >"$HOME/.config/sandshell/worktrees/wt-one.meta"
  : >"$HOME/.config/sandshell/worktrees/wt-two.meta"
  out=$(zsh_gen _sandshell_managed_sandboxes)
  assert_comp 'wt-one wt-two' "$out"
}

test_zsh_branches() {
  setup_test_env
  make_git_repo "$TEST_TMP/repo"
  git -C "$TEST_TMP/repo" branch feature-x
  COMPLETION_CWD="$TEST_TMP/repo"
  export COMPLETION_CWD
  out=$(zsh_gen _sandshell_branches)
  assert_comp 'feature-x main' "$out"
}

# --- safety -------------------------------------------------------------------

test_zsh_missing_sbx_fails_silently() {
  setup_test_env
  hide_sbx
  out=$(zsh_gen _sandshell_sandboxes)
  assert_comp '' "$out"
  out=$(zsh_gen _sandshell_mcp_servers)
  assert_comp '' "$out"
  assert_eq '' "$(zgen_err)"
}

test_zsh_failing_sbx_fails_silently() {
  setup_test_env
  rm -f "$TEST_TMP/bin/sbx"
  printf '#!/bin/sh\nprintf "sbx: boom\\n" >&2\nexit 1\n' >"$TEST_TMP/bin/sbx"
  chmod +x "$TEST_TMP/bin/sbx"
  out=$(zsh_gen _sandshell_sandboxes)
  assert_comp '' "$out"
  out=$(zsh_gen _sandshell_mcp_servers)
  assert_comp '' "$out"
  assert_eq '' "$(zgen_err)"
}

test_zsh_missing_git_fails_silently() {
  setup_test_env
  hide_git
  out=$(zsh_gen _sandshell_branches)
  assert_comp '' "$out"
  assert_eq '' "$(zgen_err)"
}

test_zsh_completion_is_read_only() {
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
  # Sanity: the generators under test actually produce candidates.
  out=$(zsh_gen _sandshell_sandboxes)
  assert_comp 'alpha beta' "$out"
  out=$(zsh_gen _sandshell_managed_sandboxes)
  assert_comp 'wt-one' "$out"
  fp1=$(store_fingerprint)
  tree1=$(tree_fingerprint "$HOME/.config/sandshell")
  zsh_gen _sandshell_sandboxes >/dev/null
  zsh_gen _sandshell_mcp_servers >/dev/null
  zsh_gen _sandshell_skills_available >/dev/null
  zsh_gen _sandshell_skills_tracked alpha >/dev/null
  zsh_gen _sandshell_managed_sandboxes >/dev/null
  zsh_gen _sandshell_branches >/dev/null
  fp2=$(store_fingerprint)
  tree2=$(tree_fingerprint "$HOME/.config/sandshell")
  assert_eq "$fp1" "$fp2"
  assert_eq "$tree1" "$tree2"
  # The mock sbx must only ever see read-only queries.
  bad=$(grep -v -e '^ls -q$' -e '^mcp ls$' "$SBX_MOCK_STATE/calls.log" 2>/dev/null || true)
  assert_eq '' "$bad"
}

test_zsh_completion_creates_no_config() {
  setup_test_env
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  # Sanity: the generators under test actually produce candidates.
  out=$(zsh_gen _sandshell_sandboxes)
  assert_comp 'alpha' "$out"
  out=$(zsh_gen _sandshell_skills_tracked alpha)
  assert_comp '' "$out"
  out=$(zsh_gen _sandshell_managed_sandboxes)
  assert_comp '' "$out"
  assert_file_missing "$HOME/.config/sandshell"
}

test_zsh_config_root_precedence() {
  setup_test_env
  mkdir -p "$TEST_TMP/custom/skills"
  printf 'skill-x\n' >"$TEST_TMP/custom/skills/alpha.skills"
  SANDSHELL_CONFIG_HOME="$TEST_TMP/custom"
  export SANDSHELL_CONFIG_HOME
  out=$(zsh_gen _sandshell_skills_tracked alpha)
  assert_comp 'skill-x' "$out"
  unset SANDSHELL_CONFIG_HOME
  mkdir -p "$TEST_TMP/xdg/sandshell/skills"
  printf 'skill-y\n' >"$TEST_TMP/xdg/sandshell/skills/alpha.skills"
  XDG_CONFIG_HOME="$TEST_TMP/xdg"
  export XDG_CONFIG_HOME
  out=$(zsh_gen _sandshell_skills_tracked alpha)
  assert_comp 'skill-y' "$out"
}

test_zsh_missing_config_dir_yields_no_candidates() {
  setup_test_env
  out=$(zsh_gen _sandshell_skills_tracked alpha)
  assert_comp '' "$out"
  out=$(zsh_gen _sandshell_managed_sandboxes)
  assert_comp '' "$out"
  assert_eq '' "$(zgen_err)"
}

run_tests \
  test_zsh_syntax \
  test_zsh_registers_all_commands_via_compinit \
  test_zsh_file_does_not_run_compinit_or_zstyle \
  test_zsh_sandboxes \
  test_zsh_sbxupdate \
  test_zsh_mcp_servers \
  test_zsh_skills_available \
  test_zsh_skills_tracked \
  test_zsh_managed_sandboxes \
  test_zsh_branches \
  test_zsh_missing_sbx_fails_silently \
  test_zsh_failing_sbx_fails_silently \
  test_zsh_missing_git_fails_silently \
  test_zsh_completion_is_read_only \
  test_zsh_completion_creates_no_config \
  test_zsh_config_root_precedence \
  test_zsh_missing_config_dir_yields_no_candidates
