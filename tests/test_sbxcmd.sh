#!/usr/bin/env bash
# Characterization tests for sbxcmd.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

test_sbxcmd_lists_all_public_commands() {
  setup_test_env
  run sbxcmd
  assert_rc 0
  assert_eq 'Docker Sandbox helpers:
  sbxc      Create and configure a new sandbox
  sbxr      List or resume existing sandboxes
  sbxupdate Update the installed agent CLI in an existing sandbox
  sbxenv    Edit the current project environment file
  sbxmcp    List, attach, or copy MCP servers per sandbox
  sbxskill  Manage isolated skills per sandbox
  sbxwt     Create and manage host Git worktree sandboxes
  sbxcmd    Show this command summary

Use <command> --help for detailed usage.' "$OUT"
}

test_sbxcmd_help() {
  setup_test_env
  run sbxcmd --help
  assert_rc 0
  assert_eq 'Usage: sbxcmd
List the sandshell helper commands.' "$OUT"
}

test_sbxcmd_rejects_unexpected_argument() {
  setup_test_env
  run sbxcmd bogus
  assert_rc 2
  assert_eq 'sbxcmd: unexpected argument: bogus' "$ERR"
}

run_tests \
  test_sbxcmd_lists_all_public_commands \
  test_sbxcmd_help \
  test_sbxcmd_rejects_unexpected_argument
