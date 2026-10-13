#!/usr/bin/env bash
# Characterization tests for sbxenv.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

# make_workspace PATH — a plain directory used as the current project.
make_workspace() {
  mkdir -p "$1"
}

test_sbxenv_help() {
  setup_test_env
  run sbxenv --help
  assert_rc 0
  assert_contains "$OUT" 'Usage: sbxenv [EDITOR]'
  assert_contains "$OUT" 'Creates a missing env file with permissions 600.'
  assert_contains "$OUT" 'Editor priority:'
}

test_sbxenv_rejects_unknown_option() {
  setup_test_env
  run sbxenv --bogus
  assert_rc 2
  assert_contains "$ERR" 'sbxenv: unknown option: --bogus'
}

test_sbxenv_rejects_extra_arguments() {
  setup_test_env
  run sbxenv a b
  assert_rc 2
  assert_contains "$ERR" 'sbxenv: expected at most one editor argument'
}

test_sbxenv_resolves_project_env_path() {
  setup_test_env
  make_stub myeditor
  make_workspace "$TEST_TMP/ws/my project"
  cd "$TEST_TMP/ws/my project" || exit 1
  run sbxenv myeditor
  assert_rc 0
  env_file="$HOME/.config/sandshell/envs/my-project.env"
  assert_file_exists "$env_file"
  assert_eq "$env_file" "$(stub_log myeditor)"
}

test_sbxenv_creates_missing_dirs_and_file_with_private_permissions() {
  setup_test_env
  make_stub myeditor
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv myeditor
  assert_rc 0
  env_file="$HOME/.config/sandshell/envs/proj.env"
  assert_dir_exists "$HOME/.config/sandshell/envs"
  assert_file_exists "$env_file"
  assert_eq '600' "$(file_mode "$env_file")"
}

test_sbxenv_does_not_overwrite_existing_contents() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir"
  env_file="$env_dir/proj.env"
  printf 'FOO=bar\n' >"$env_file"
  # An editor that appends instead of replacing must not lose existing content.
  printf '#!/bin/sh\nprintf "EDITED=yes\\n" >> "$1"\n' >"$TEST_TMP/bin/appender"
  chmod +x "$TEST_TMP/bin/appender"
  run sbxenv appender
  assert_rc 0
  assert_eq 'FOO=bar
EDITED=yes' "$(cat "$env_file")"
}

test_sbxenv_explicit_editor_wins_over_micro() {
  setup_test_env
  make_stub micro
  make_stub customed
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv customed
  assert_rc 0
  assert_eq "$HOME/.config/sandshell/envs/proj.env" "$(stub_log customed)"
  assert_eq '' "$(stub_log micro)"
}

test_sbxenv_prefers_micro_over_visual_and_editor() {
  setup_test_env
  make_stub micro
  make_stub vised
  make_stub eded
  export VISUAL=vised
  export EDITOR=eded
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv
  assert_rc 0
  assert_eq "$HOME/.config/sandshell/envs/proj.env" "$(stub_log micro)"
  assert_eq '' "$(stub_log vised)"
  assert_eq '' "$(stub_log eded)"
}

test_sbxenv_uses_visual_before_editor() {
  setup_test_env
  make_stub vised
  make_stub eded
  export VISUAL=vised
  export EDITOR=eded
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv
  assert_rc 0
  assert_eq "$HOME/.config/sandshell/envs/proj.env" "$(stub_log vised)"
  assert_eq '' "$(stub_log eded)"
}

test_sbxenv_uses_editor_before_vi() {
  setup_test_env
  make_stub eded
  make_stub vi
  unset VISUAL
  export EDITOR=eded
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv
  assert_rc 0
  assert_eq "$HOME/.config/sandshell/envs/proj.env" "$(stub_log eded)"
  assert_eq '' "$(stub_log vi)"
}

test_sbxenv_falls_back_to_vi() {
  setup_test_env
  make_stub vi
  unset VISUAL EDITOR
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv
  assert_rc 0
  assert_eq "$HOME/.config/sandshell/envs/proj.env" "$(stub_log vi)"
}

test_sbxenv_splits_editor_value_with_arguments() {
  setup_test_env
  make_stub eded
  unset VISUAL
  export EDITOR='eded --flag'
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv
  assert_rc 0
  assert_contains "$(stub_log eded)" '--flag'
  assert_contains "$(stub_log eded)" "$HOME/.config/sandshell/envs/proj.env"
}

test_sbxenv_missing_editor_returns_127_and_creates_nothing() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  run sbxenv no-such-editor
  assert_rc 127
  assert_contains "$ERR" 'sbxenv: editor not found: no-such-editor'
  assert_file_missing "$HOME/.config/sandshell/envs"
}

test_sbxenv_reports_when_no_editor_exists() {
  setup_test_env
  make_workspace "$TEST_TMP/ws/proj"
  # A PATH with no editor at all (no micro, VISUAL, EDITOR, or vi).
  mkdir -p "$TEST_TMP/edbin"
  ln -s "$(command -v bash)" "$TEST_TMP/edbin/bash"
  run env -i PATH="$TEST_TMP/edbin" HOME="$HOME" \
    bash -c '. "$1"; cd "$2" || exit 1; sbxenv' sh "$SANDSHELL_SH" "$TEST_TMP/ws/proj"
  assert_rc 127
  assert_contains "$ERR" 'sbxenv: no editor found'
  assert_file_missing "$HOME/.config/sandshell/envs"
}

test_sbxenv_refuses_symlinked_env_file() {
  setup_test_env
  make_stub myeditor
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir" "$TEST_TMP/elsewhere"
  ln -s "$TEST_TMP/elsewhere/target.env" "$env_dir/proj.env"
  run sbxenv myeditor
  assert_rc 2
  assert_contains "$ERR" 'sbxenv: refusing symlink or non-file path'
  assert_eq '' "$(stub_log myeditor)"
}

test_sbxenv_refuses_symlinked_env_dir() {
  setup_test_env
  make_stub myeditor
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  mkdir -p "$HOME/.config/sandshell" "$TEST_TMP/elsewhere"
  ln -s "$TEST_TMP/elsewhere" "$HOME/.config/sandshell/envs"
  run sbxenv myeditor
  assert_rc 2
  assert_contains "$ERR" 'sbxenv: refusing symlink or non-file path'
  assert_eq '' "$(stub_log myeditor)"
}

test_sbxenv_refuses_non_file_env_target() {
  setup_test_env
  make_stub myeditor
  make_workspace "$TEST_TMP/ws/proj"
  cd "$TEST_TMP/ws/proj" || exit 1
  env_dir="$HOME/.config/sandshell/envs"
  mkdir -p "$env_dir/proj.env"
  run sbxenv myeditor
  assert_rc 2
  assert_contains "$ERR" 'sbxenv: refusing symlink or non-file path'
  assert_eq '' "$(stub_log myeditor)"
}

run_tests \
  test_sbxenv_help \
  test_sbxenv_rejects_unknown_option \
  test_sbxenv_rejects_extra_arguments \
  test_sbxenv_resolves_project_env_path \
  test_sbxenv_creates_missing_dirs_and_file_with_private_permissions \
  test_sbxenv_does_not_overwrite_existing_contents \
  test_sbxenv_explicit_editor_wins_over_micro \
  test_sbxenv_prefers_micro_over_visual_and_editor \
  test_sbxenv_uses_visual_before_editor \
  test_sbxenv_uses_editor_before_vi \
  test_sbxenv_falls_back_to_vi \
  test_sbxenv_splits_editor_value_with_arguments \
  test_sbxenv_missing_editor_returns_127_and_creates_nothing \
  test_sbxenv_reports_when_no_editor_exists \
  test_sbxenv_refuses_symlinked_env_file \
  test_sbxenv_refuses_symlinked_env_dir \
  test_sbxenv_refuses_non_file_env_target
