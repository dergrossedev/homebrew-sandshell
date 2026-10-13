# shellcheck shell=bash
# Docker Sandbox helpers for Bash and Zsh.
# Configuration and state root:
#   ${SANDSHELL_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/sandshell}
# Shared Vibe config (optional): <config-root>/agents/vibe.toml
# Per-project environment: <config-root>/envs/<project>.env
# Per-sandbox MCP tracking: <config-root>/mcp/<sandbox>.servers
# Per-sandbox skill tracking: <config-root>/skills/<sandbox>.skills
# Per-sandbox preset metadata: <config-root>/sandboxes/<sandbox>.meta
# Managed worktree metadata: <config-root>/worktrees/<sandbox>.meta
# sbxwt done can remove a clean managed host worktree after confirmation; its
# branch is preserved. Other helper state lives under the config root. Direct
# or worktree agents can modify mounted host files; clone mode may update host
# Git repository configuration.

# _sbx_config_dir — sandshell configuration and state root. Priority:
# SANDSHELL_CONFIG_HOME, then XDG_CONFIG_HOME/sandshell, then
# $HOME/.config/sandshell. Fails clearly when no root can be derived.
_sbx_config_dir() {
  local root=${SANDSHELL_CONFIG_HOME:-}
  if [[ -z $root ]]; then
    root=${XDG_CONFIG_HOME:-}
    if [[ -n $root ]]; then
      root=$root/sandshell
    elif [[ -n ${HOME:-} ]]; then
      root=$HOME/.config/sandshell
    else
      printf 'sandshell: cannot determine the configuration directory; set SANDSHELL_CONFIG_HOME, XDG_CONFIG_HOME, or HOME\n' >&2
      return 1
    fi
  fi
  printf '%s\n' "$root"
}

# _sbx_project_name — normalize a workspace path to a project name.
_sbx_project_name() {
  local name=${1##*/}
  name=${name//[^a-zA-Z0-9.-]/-}
  [[ -n $name ]] || name=project
  printf '%s\n' "$name"
}

# _sandshell_tty_available — true when the controlling terminal can actually
# be opened. A plain `test -r /dev/tty` is not enough: the device node passes
# the permission check even when the process has no controlling terminal, and
# opening it then fails with ENXIO. The probe runs in a subshell with stderr
# discarded so the failed open never leaks a shell error message.
_sandshell_tty_available() {
  ( : < /dev/tty && : > /dev/tty ) 2>/dev/null
}

# _sbx_confirm — ask a yes/no question on the controlling terminal. CMD is the
# calling command's name, used to prefix the non-interactive error message.
_sbx_confirm() {
  local cmd=$1 prompt=$2 answer
  if ! _sandshell_tty_available; then
    printf '%s: interactive confirmation required (no terminal)\n' "$cmd" >&2
    return 1
  fi
  printf '%s [y/N] ' "$prompt" > /dev/tty || return
  IFS= read -r answer < /dev/tty || return
  case $answer in y|Y|yes|YES) return 0 ;; esac
  return 1
}
