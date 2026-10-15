# Bash completion for sandshell (sbxc, sbxr, sbxenv, sbxmcp, sbxskill, sbxwt,
# sbxupdate, sbxcmd).
#
# Load from .bashrc:
#   source /path/to/sandshell/completions/sandshell.bash
#
# This file is standalone: it does not require sandshell.sh to be sourced and
# never creates or modifies sandboxes, directories, configuration, or Git
# state. Dynamic lookups (sbx, git, the shared skill store, sandshell state
# files) are read-only and fail silently when unavailable.

# Only load under Bash; sourcing from another shell is a silent no-op.
if [ -z "${BASH_VERSION:-}" ]; then
  return 0
fi

# --- shared helpers -----------------------------------------------------------

# _sandshell_config_root — sandshell configuration root, mirroring the runtime
# precedence (SANDSHELL_CONFIG_HOME, then XDG_CONFIG_HOME/sandshell, then
# $HOME/.config/sandshell). Prints nothing when no root can be derived.
_sandshell_config_root() {
  local root=${SANDSHELL_CONFIG_HOME:-}
  if [ -z "$root" ]; then
    root=${XDG_CONFIG_HOME:-}
    if [ -n "$root" ]; then
      root=$root/sandshell
    elif [ -n "${HOME:-}" ]; then
      root=$HOME/.config/sandshell
    fi
  fi
  if [ -n "$root" ]; then
    printf '%s\n' "$root"
  fi
  return 0
}

# _sandshell_skill_store — Docker's shared host-wide skill catalog, mirroring
# the runtime path without a uname subprocess. Prints nothing on other hosts.
_sandshell_skill_store() {
  case ${OSTYPE:-} in
    darwin*) printf '%s\n' "$HOME/Library/Application Support/com.docker.sandboxes/sandboxes/agent-skills" ;;
    linux*) printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/sandboxes/sandboxes/agent-skills" ;;
  esac
  return 0
}

# _sandshell_print_unused — print stdin lines that do not exactly match any
# argument. Used to drop names already present on the command line.
_sandshell_print_unused() {
  local line arg skip
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    skip=0
    for arg in "$@"; do
      if [ "$line" = "$arg" ]; then
        skip=1
        break
      fi
    done
    if [ "$skip" -eq 0 ]; then
      printf '%s\n' "$line"
    fi
  done
  return 0
}

# --- dynamic candidate generators ---------------------------------------------
# Each generator prints candidate names to stdout, one per line, skipping any
# names passed as arguments. All of them are read-only and silent on failure.

# _sandshell_sandboxes [EXCLUDE...] — existing sandbox names.
_sandshell_sandboxes() {
  command -v sbx >/dev/null 2>&1 || return 0
  sbx ls -q 2>/dev/null | _sandshell_print_unused "$@"
  return 0
}

# _sandshell_mcp_servers [EXCLUDE...] — registered MCP server names.
_sandshell_mcp_servers() {
  command -v sbx >/dev/null 2>&1 || return 0
  sbx mcp ls 2>/dev/null | _sandshell_print_unused "$@"
  return 0
}

# _sandshell_skills_available [EXCLUDE...] — skills in the shared store.
_sandshell_skills_available() {
  local store d name
  store=$(_sandshell_skill_store)
  [ -n "$store" ] || return 0
  for d in "$store"/*/; do
    [ -d "$d" ] || continue
    [ -L "$d" ] && continue
    [ -f "$d/SKILL.md" ] || continue
    name=${d%/}
    name=${name##*/}
    _sandshell_print_unused "$@" <<<"$name"
  done
  return 0
}

# _sandshell_skills_tracked SANDBOX [EXCLUDE...] — skills selected for SANDBOX.
_sandshell_skills_tracked() {
  local sandbox=$1 root file
  shift
  [[ $sandbox =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || return 0
  root=$(_sandshell_config_root)
  [ -n "$root" ] || return 0
  file=$root/skills/$sandbox.skills
  [ -f "$file" ] || return 0
  _sandshell_print_unused "$@" <"$file"
  return 0
}

# _sandshell_managed_sandboxes [EXCLUDE...] — sandboxes with worktree metadata.
_sandshell_managed_sandboxes() {
  local root f name
  root=$(_sandshell_config_root)
  [ -n "$root" ] || return 0
  for f in "$root"/worktrees/*.meta; do
    [ -f "$f" ] || continue
    name=${f##*/}
    name=${name%.meta}
    _sandshell_print_unused "$@" <<<"$name"
  done
  return 0
}

# _sandshell_branches [EXCLUDE...] — local Git branch names.
_sandshell_branches() {
  command -v git >/dev/null 2>&1 || return 0
  git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | _sandshell_print_unused "$@"
  return 0
}

# --- COMPREPLY plumbing ---------------------------------------------------------

# _sandshell_complete_list CUR WORD... — set COMPREPLY to the WORDs that have
# prefix CUR.
_sandshell_complete_list() {
  local cur=$1 word
  shift
  COMPREPLY=()
  for word in "$@"; do
    if [[ $word == "$cur"* ]]; then
      COMPREPLY+=("$word")
    fi
  done
  return 0
}

# _sandshell_complete_from_append CUR GEN [ARGS...] — append the GEN output
# lines that have prefix CUR to COMPREPLY. The generator runs in a process
# substitution so the read loop updates COMPREPLY in the current shell.
_sandshell_complete_from_append() {
  local cur=$1 line
  shift
  while IFS= read -r line; do
    if [ -n "$line" ] && [[ $line == "$cur"* ]]; then
      COMPREPLY+=("$line")
    fi
  done < <("$@" 2>/dev/null)
  return 0
}

# _sandshell_complete_from CUR GEN [ARGS...] — set COMPREPLY from GEN output.
_sandshell_complete_from() {
  COMPREPLY=()
  _sandshell_complete_from_append "$@"
}

# _sandshell_complete_files CUR — native file completion.
_sandshell_complete_files() {
  _sandshell_complete_from "$1" compgen -f -- "$1"
  compopt -o filenames 2>/dev/null || true
  return 0
}

# _sandshell_complete_dirs CUR — native directory completion.
_sandshell_complete_dirs() {
  _sandshell_complete_from "$1" compgen -d -- "$1"
  compopt -o filenames 2>/dev/null || true
  return 0
}

# --- per-command completion -----------------------------------------------------

_sandshell_sbxc() {
  local cur prev
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  if (( COMP_CWORD > 0 )); then
    prev=${COMP_WORDS[COMP_CWORD-1]}
  else
    prev=''
  fi
  case $prev in
    -a|--agent)
      _sandshell_complete_list "$cur" claude codex opencode vibe claude-ollama opencode-ollama
      return 0 ;;
    -s|--size)
      _sandshell_complete_list "$cur" micro small medium
      return 0 ;;
    -d|--dir)
      _sandshell_complete_dirs "$cur"
      return 0 ;;
    --env-file)
      _sandshell_complete_files "$cur"
      return 0 ;;
    -n|--name|--model)
      return 0 ;;
  esac
  _sandshell_complete_list "$cur" -h --help -a --agent -d --dir -s --size -n --name --clone --env-file --model
  return 0
}

_sandshell_sbxr() {
  local cur prev
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  if (( COMP_CWORD > 0 )); then
    prev=${COMP_WORDS[COMP_CWORD-1]}
  else
    prev=''
  fi
  case $prev in
    --env-file)
      _sandshell_complete_files "$cur"
      return 0 ;;
  esac
  if [[ $cur == -* ]]; then
    _sandshell_complete_list "$cur" -h --help --all --env-file
    return 0
  fi
  _sandshell_complete_from "$cur" _sandshell_sandboxes
  return 0
}

_sandshell_sbxenv() {
  local cur
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  if [[ $cur == -* ]]; then
    _sandshell_complete_list "$cur" -h --help
    return 0
  fi
  if (( COMP_CWORD == 1 )); then
    _sandshell_complete_from "$cur" compgen -A command -- "$cur"
    return 0
  fi
  return 0
}

_sandshell_sbxupdate() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=()
  (( COMP_CWORD == 1 )) || return 0
  if [[ $cur == -* ]]; then
    _sandshell_complete_list "$cur" -h --help
  else
    _sandshell_complete_from "$cur" _sandshell_sandboxes
  fi
  return 0
}

_sandshell_sbxmcp() {
  local cur sub i
  local -a typed
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  if (( COMP_CWORD == 1 )); then
    if [[ $cur == -* ]]; then
      _sandshell_complete_list "$cur" -h --help
    else
      _sandshell_complete_list "$cur" ls add copy -h --help
    fi
    return 0
  fi
  sub=${COMP_WORDS[1]}
  case $sub in
    ls)
      if (( COMP_CWORD == 2 )); then
        _sandshell_complete_from "$cur" _sandshell_sandboxes
      fi
      return 0 ;;
    add)
      if (( COMP_CWORD == 2 )); then
        _sandshell_complete_from "$cur" _sandshell_sandboxes
        return 0
      fi
      typed=()
      for (( i = 3; i < COMP_CWORD; i++ )); do
        typed+=("${COMP_WORDS[i]}")
      done
      _sandshell_complete_from "$cur" _sandshell_mcp_servers "${typed[@]}"
      return 0 ;;
    copy)
      _sandshell_complete_from "$cur" _sandshell_sandboxes
      return 0 ;;
  esac
  return 0
}

_sandshell_sbxskill() {
  local cur sub i
  local -a typed
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  if (( COMP_CWORD == 1 )); then
    if [[ $cur == -* ]]; then
      _sandshell_complete_list "$cur" -h --help
    else
      _sandshell_complete_list "$cur" available ls add remove sync copy -h --help
    fi
    return 0
  fi
  sub=${COMP_WORDS[1]}
  case $sub in
    ls|sync)
      if (( COMP_CWORD == 2 )); then
        _sandshell_complete_from "$cur" _sandshell_sandboxes
      fi
      return 0 ;;
    add|remove)
      if (( COMP_CWORD == 2 )); then
        _sandshell_complete_from "$cur" _sandshell_sandboxes
        return 0
      fi
      # --all cannot be combined with skill names.
      for (( i = 3; i < COMP_CWORD; i++ )); do
        if [[ ${COMP_WORDS[i]} == --all ]]; then
          return 0
        fi
      done
      _sandshell_complete_list "$cur" --all
      typed=()
      for (( i = 3; i < COMP_CWORD; i++ )); do
        typed+=("${COMP_WORDS[i]}")
      done
      if [[ $sub == add ]]; then
        _sandshell_complete_from_append "$cur" _sandshell_skills_available "${typed[@]}"
      else
        _sandshell_complete_from_append "$cur" _sandshell_skills_tracked "${COMP_WORDS[2]}" "${typed[@]}"
      fi
      return 0 ;;
    copy)
      _sandshell_complete_from "$cur" _sandshell_sandboxes
      return 0 ;;
  esac
  return 0
}

_sandshell_sbxwt() {
  local cur prev sub
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  if (( COMP_CWORD > 0 )); then
    prev=${COMP_WORDS[COMP_CWORD-1]}
  else
    prev=''
  fi
  if (( COMP_CWORD == 1 )); then
    if [[ $cur == -* ]]; then
      _sandshell_complete_list "$cur" -h --help
    else
      _sandshell_complete_list "$cur" create ls commit merge 'done' -h --help
    fi
    return 0
  fi
  sub=${COMP_WORDS[1]}
  case $sub in
    create)
      case $prev in
        -a|--agent)
          _sandshell_complete_list "$cur" claude codex opencode vibe claude-ollama opencode-ollama
          return 0 ;;
        -s|--size)
          _sandshell_complete_list "$cur" micro small medium
          return 0 ;;
        --base)
          _sandshell_complete_from "$cur" _sandshell_branches
          return 0 ;;
        --env-file)
          _sandshell_complete_files "$cur"
          return 0 ;;
      esac
      if [[ $cur == -* ]]; then
        _sandshell_complete_list "$cur" -a --agent -s --size --base --env-file
        return 0
      fi
      if (( COMP_CWORD == 2 )); then
        _sandshell_complete_from "$cur" _sandshell_branches
        return 0
      fi
      _sandshell_complete_list "$cur" -a --agent -s --size --base --env-file
      return 0 ;;
    ls)
      return 0 ;;
    commit)
      if (( COMP_CWORD == 2 )); then
        _sandshell_complete_from "$cur" _sandshell_managed_sandboxes
        return 0
      fi
      if [[ $prev == -m ]]; then
        return 0
      fi
      if [[ $cur == -* ]]; then
        _sandshell_complete_list "$cur" -m
      fi
      return 0 ;;
    merge)
      if (( COMP_CWORD == 2 )); then
        _sandshell_complete_from "$cur" _sandshell_managed_sandboxes
        return 0
      fi
      if [[ $prev == --into ]]; then
        _sandshell_complete_from "$cur" _sandshell_branches
        return 0
      fi
      if [[ $cur == -* ]]; then
        _sandshell_complete_list "$cur" --into
      fi
      return 0 ;;
    done)
      if (( COMP_CWORD == 2 )); then
        _sandshell_complete_from "$cur" _sandshell_managed_sandboxes
      fi
      return 0 ;;
  esac
  return 0
}

_sandshell_sbxcmd() {
  local cur
  cur=${COMP_WORDS[COMP_CWORD]}
  _sandshell_complete_list "$cur" -h --help
  return 0
}

# --- registration ---------------------------------------------------------------

complete -F _sandshell_sbxc sbxc
complete -F _sandshell_sbxr sbxr
complete -F _sandshell_sbxupdate sbxupdate
complete -F _sandshell_sbxenv sbxenv
complete -F _sandshell_sbxmcp sbxmcp
complete -F _sandshell_sbxskill sbxskill
complete -F _sandshell_sbxwt sbxwt
complete -F _sandshell_sbxcmd sbxcmd
