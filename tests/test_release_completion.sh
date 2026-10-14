#!/usr/bin/env bash
# Regression tests for shell completion from an unpacked release archive.
#
# v0.1.0 release bug: Zsh completion did not work when set up manually from
# the unpacked release archive. compinit only scans $fpath at the moment it
# runs, so a completions directory added after completion initialization is
# never discovered. These tests package a throwaway tree, extract the release
# archive, and exercise completion against the extracted artifact only — never
# the repository-local completion files — following the flows documented in
# README.md:
#
#   - Zsh, completion not initialized yet: add the completions directory to
#     $fpath before compinit, then initialize completion;
#   - Zsh, completion already initialized: re-run compinit once;
#   - Bash: source the runtime and the Bash completion file.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

ZSH_BIN=$(command -v zsh 2>/dev/null) || ZSH_BIN=''
BASH_BIN=$(command -v bash 2>/dev/null) || BASH_BIN=''

# require_zsh — skip the calling test (with a note) when Zsh is unavailable.
require_zsh() {
  if [ -z "$ZSH_BIN" ]; then
    printf '    zsh not found; skipping\n'
    return 1
  fi
  return 0
}

# Keep the real Zsh completion initializer, but give it a disposable function
# path. `zsh -f` still sees installed/site completions and inherited FPATH.
_sandshell_setup_release_zsh_functions() {
  local core_dir
  core_dir=$("$ZSH_BIN" -f -c '
    autoload -Uz compinit
    autoload +X compinit || exit
    print -r -- "${functions_source[compinit]:h}"
  ') || assert_fail 'could not locate Zsh compinit'
  mkdir -p "$TEST_TMP/zsh-functions"
  cp "$core_dir/compinit" "$core_dir/compaudit" \
    "$core_dir/compdump" "$core_dir/compinstall" "$TEST_TMP/zsh-functions/" \
    || assert_fail 'could not copy Zsh completion initializers'
  export ZDOTDIR="$HOME"
}

# package_release_tree DEST — package a throwaway copy of the repository tree
# and extract the release archive under DEST/extract. Sets RELEASE_DIR to the
# extracted sandshell-0.1.0 directory. The real working tree and its real
# dist/ directory are never touched.
package_release_tree() {
  local tree=$1
  mkdir -p "$tree/scripts" "$tree/src" "$tree/completions" "$tree/examples"
  cp "$SANDSHELL_ROOT/scripts/build.sh" "$SANDSHELL_ROOT/scripts/package.sh" "$tree/scripts/"
  chmod +x "$tree/scripts/build.sh" "$tree/scripts/package.sh"
  cp "$SANDSHELL_ROOT"/src/*.sh "$tree/src/"
  cp "$SANDSHELL_SH" "$tree/sandshell.sh"
  cp "$SANDSHELL_ROOT/completions/sandshell.bash" "$SANDSHELL_ROOT/completions/_sandshell" "$tree/completions/"
  cp "$SANDSHELL_ROOT/examples/vibe.toml" "$tree/examples/"
  cp "$SANDSHELL_ROOT/README.md" "$SANDSHELL_ROOT/LICENSE" "$tree/"
  "$tree/scripts/package.sh" 0.1.0 >/dev/null || return 1
  mkdir -p "$tree/extract"
  tar -xzf "$tree/dist/sandshell-0.1.0.tar.gz" -C "$tree/extract" || return 1
  RELEASE_DIR="$tree/extract/sandshell-0.1.0"
}

# --- the release artifact itself -------------------------------------------------

test_release_archive_contains_completion_assets() {
  setup_test_env
  package_release_tree "$TEST_TMP/repo" || assert_fail 'packaging the throwaway tree failed'
  assert_file_exists "$RELEASE_DIR/sandshell.sh"
  assert_file_exists "$RELEASE_DIR/completions/_sandshell"
  assert_file_exists "$RELEASE_DIR/completions/sandshell.bash"
}

# --- Zsh: completion not initialized yet -------------------------------------------

test_release_zsh_completion_discovers_all_commands() {
  require_zsh || return 0
  setup_test_env
  _sandshell_setup_release_zsh_functions
  package_release_tree "$TEST_TMP/repo" || assert_fail 'packaging the throwaway tree failed'
  # The documented flow: source the extracted runtime, add the extracted
  # completions directory to $fpath BEFORE compinit, then initialize.
  run "$ZSH_BIN" -f -c '
    fpath=("$TEST_TMP/zsh-functions")
    fpath=("$1/completions" $fpath)
    autoload -U compinit
    compinit -i -D
    . "$1/sandshell.sh"
    for c in sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxcmd; do
      printf "%s=%s\n" "$c" "${_comps[$c]:-none}"
    done
  ' _ "$RELEASE_DIR"
  assert_rc 0
  assert_eq '' "$ERR"
  for c in sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxcmd; do
    assert_contains "$OUT" "$c=_sandshell" "command: $c"
  done
}

# --- Zsh: completion already initialized -------------------------------------------

test_release_zsh_fpath_after_compinit_is_not_discovered() {
  require_zsh || return 0
  setup_test_env
  _sandshell_setup_release_zsh_functions
  package_release_tree "$TEST_TMP/repo" || assert_fail 'packaging the throwaway tree failed'
  # Characterization of the release bug: compinit scans $fpath only when it
  # runs, so a directory added afterwards is never discovered. This is why
  # the README must document the ordering and the re-run remedy.
  run "$ZSH_BIN" -f -c '
    fpath=("$TEST_TMP/zsh-functions")
    autoload -U compinit
    compinit -i -D
    fpath=("$1/completions" $fpath)
    . "$1/sandshell.sh"
    printf "sbxc=%s\n" "${_comps[sbxc]:-none}"
  ' _ "$RELEASE_DIR"
  assert_rc 0
  assert_eq 'sbxc=none' "$OUT"
}

test_release_zsh_compinit_rerun_makes_completion_visible() {
  require_zsh || return 0
  setup_test_env
  _sandshell_setup_release_zsh_functions
  package_release_tree "$TEST_TMP/repo" || assert_fail 'packaging the throwaway tree failed'
  # The documented remedy when completion was already initialized before the
  # completions directory was added: re-run compinit once in the current shell.
  run "$ZSH_BIN" -f -c '
    fpath=("$TEST_TMP/zsh-functions")
    autoload -U compinit
    compinit -i -D
    fpath=("$1/completions" $fpath)
    . "$1/sandshell.sh"
    compinit -i -D
    printf "sbxc=%s\n" "${_comps[sbxc]:-none}"
    printf "sbxr=%s\n" "${_comps[sbxr]:-none}"
  ' _ "$RELEASE_DIR"
  assert_rc 0
  assert_contains "$OUT" 'sbxc=_sandshell'
  assert_contains "$OUT" 'sbxr=_sandshell'
}

test_release_zsh_ignores_installed_completion() {
  require_zsh || return 0
  setup_test_env
  _sandshell_setup_release_zsh_functions
  package_release_tree "$TEST_TMP/repo" || assert_fail 'packaging the throwaway tree failed'
  mkdir -p "$TEST_TMP/site-functions"
  printf '#compdef sbxc sbxr\nreturn 99\n' > "$TEST_TMP/site-functions/_sandshell"
  # Simulate a Homebrew-installed completion without touching host directories.
  local installed_fpath
  installed_fpath=$("$ZSH_BIN" -f -c 'print -r -- "${(j.:.)fpath}"')
  run env FPATH="$TEST_TMP/site-functions:$installed_fpath" "$ZSH_BIN" -f -c '
    fpath=("$TEST_TMP/zsh-functions")
    autoload -U compinit
    compinit -i -D
    printf "before=%s\n" "${_comps[sbxc]:-none}"
    fpath=("$1/completions" $fpath)
    . "$1/sandshell.sh"
    printf "added=%s\n" "${_comps[sbxc]:-none}"
    compinit -i -D
    printf "after=%s\n" "${_comps[sbxc]:-none}"
    autoload +X _sandshell || exit
    printf "source=%s\n" "${functions_source[_sandshell]}"
  ' _ "$RELEASE_DIR"
  assert_rc 0
  assert_eq '' "$ERR"
  assert_eq "before=none
added=none
after=_sandshell
source=$RELEASE_DIR/completions/_sandshell" "$OUT"
}

# --- Bash ---------------------------------------------------------------------------

test_release_bash_completion_from_extracted_archive() {
  setup_test_env
  package_release_tree "$TEST_TMP/repo" || assert_fail 'packaging the throwaway tree failed'
  make_sandbox alpha claude stopped "$TEST_TMP/ws"
  make_sandbox beta codex stopped "$TEST_TMP/ws"
  # The documented flow: source the extracted runtime, then source the
  # extracted Bash completion file.
  run "$BASH_BIN" -c '
    . "$1/sandshell.sh"
    . "$1/completions/sandshell.bash"
    complete -p sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxcmd
    COMP_WORDS=(sbxc -a "")
    COMP_CWORD=2
    _sandshell_sbxc
    printf "agents:"
    printf " %s" "${COMPREPLY[@]}"
    printf "\n"
    COMPREPLY=()
    COMP_WORDS=(sbxr "")
    COMP_CWORD=1
    _sandshell_sbxr
    printf "sandboxes:"
    printf " %s" "${COMPREPLY[@]}"
    printf "\n"
  ' _ "$RELEASE_DIR"
  assert_rc 0
  assert_eq '' "$ERR"
  for c in sbxc sbxr sbxenv sbxmcp sbxskill sbxwt sbxcmd; do
    assert_contains "$OUT" "complete -F _sandshell_$c $c" "command: $c"
  done
  assert_contains "$OUT" 'agents: claude codex opencode vibe claude-ollama opencode-ollama'
  assert_contains "$OUT" 'sandboxes: alpha beta'
  # Dynamic completion must have gone through the mock sbx, never a real one.
  assert_contains "$(mock_calls)" 'ls -q'
}

# --- documentation -------------------------------------------------------------------

test_release_readme_documents_completion_installation() {
  setup_test_env
  readme=$(cat "$SANDSHELL_ROOT/README.md")
  # The v0.1.0 release bug was a documentation bug: the README did not ensure
  # the completions directory reached $fpath before compinit ran, and gave no
  # remedy for an already-initialized completion system.
  assert_contains "$readme" 'Add the completions directory to `fpath` before Zsh initializes completion'
  assert_contains "$readme" 're-run `compinit` once'
  assert_contains "$readme" 'source "$HOME/.local/share/sandshell/completions/sandshell.bash"'
}

run_tests \
  test_release_archive_contains_completion_assets \
  test_release_zsh_completion_discovers_all_commands \
  test_release_zsh_fpath_after_compinit_is_not_discovered \
  test_release_zsh_compinit_rerun_makes_completion_visible \
  test_release_zsh_ignores_installed_completion \
  test_release_bash_completion_from_extracted_archive \
  test_release_readme_documents_completion_installation
