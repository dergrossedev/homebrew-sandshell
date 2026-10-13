#!/usr/bin/env bash
# Shell compatibility checks for sandshell.sh: syntax, sourcing, and identical
# public output under Bash and Zsh.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

test_shell_compat_bash_syntax() {
  setup_test_env
  out=$(bash -n "$SANDSHELL_SH" 2>&1)
  RC=$?
  assert_rc 0
  assert_eq '' "$out"
}

test_shell_compat_zsh_syntax() {
  setup_test_env
  out=$(zsh -n "$SANDSHELL_SH" 2>&1)
  RC=$?
  assert_rc 0
  assert_eq '' "$out"
}

test_shell_compat_source_bash() {
  setup_test_env
  out=$(bash -c '. "$1" && sbxcmd' sh "$SANDSHELL_SH" 2>&1)
  RC=$?
  assert_rc 0
  assert_contains "$out" 'Docker Sandbox helpers:'
  assert_contains "$out" 'sbxwt'
}

test_shell_compat_source_zsh() {
  setup_test_env
  out=$(zsh -c '. "$1" && sbxcmd' sh "$SANDSHELL_SH" 2>&1)
  RC=$?
  assert_rc 0
  assert_contains "$out" 'Docker Sandbox helpers:'
  assert_contains "$out" 'sbxwt'
}

test_shell_compat_defines_all_public_commands() {
  setup_test_env
  for shell in bash zsh; do
    out=$($shell -c '
      . "$1"
      for cmd in sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxcmd; do
        command -v "$cmd" >/dev/null 2>&1 || { printf "missing: %s\n" "$cmd"; exit 1; }
      done
    ' sh "$SANDSHELL_SH" 2>&1)
    RC=$?
    assert_rc 0
    assert_eq '' "$out"
  done
}

test_shell_compat_sbxcmd_identical_across_shells() {
  setup_test_env
  b=$(bash -c '. "$1" && sbxcmd' sh "$SANDSHELL_SH" 2>/dev/null)
  z=$(zsh -c '. "$1" && sbxcmd' sh "$SANDSHELL_SH" 2>/dev/null)
  assert_eq "$b" "$z"
}

test_shell_compat_no_array_substring_expansion() {
  setup_test_env
  # Bash 3.2 (the macOS system bash) rejects array substring expansion
  # (${arr[@]:offset:length}, added in Bash 4.0). Sandshell targets macOS,
  # so no Bash-targeted file may use it.
  out=$(grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]:' \
    "$SANDSHELL_SH" "$SANDSHELL_ROOT"/src/*.sh "$SANDSHELL_ROOT/completions/sandshell.bash" 2>&1)
  # RC is consumed by assert_rc.
  # shellcheck disable=SC2034
  RC=$?
  assert_rc 1
  assert_eq '' "$out"
}

run_tests \
  test_shell_compat_bash_syntax \
  test_shell_compat_zsh_syntax \
  test_shell_compat_source_bash \
  test_shell_compat_source_zsh \
  test_shell_compat_defines_all_public_commands \
  test_shell_compat_sbxcmd_identical_across_shells \
  test_shell_compat_no_array_substring_expansion
