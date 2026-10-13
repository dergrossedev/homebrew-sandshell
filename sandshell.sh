# sandshell.sh is a generated file. Do not edit it directly.
# Source of truth: src/. Regenerate with: ./scripts/build.sh

# ---------------------------------------------------------------------------
# src/core.sh
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# src/sandbox.sh
# ---------------------------------------------------------------------------

# shellcheck shell=bash
# Sandbox lifecycle and environment: sbxc, sbxr, sbxenv, agent/kit mapping,
# Vibe setup, and the sandbox lookup helpers shared across commands.

# _sbx_workspace_rows — print `sbx ls` rows whose WORKSPACE column matches.
_sbx_workspace_rows() {
  local workspace=$1 listing line
  if (( $# == 2 )); then
    listing=$2
  else
    listing=$(sbx ls) || return
  fi
  while IFS= read -r line; do
    # The WORKSPACE column is last; match the whole path, not a substring.
    [[ $line == *[[:space:]]"$workspace" ]] && printf '%s\n' "$line"
  done <<< "$listing"
  return 0
}

# _sbx_sandbox_uses_workspace — true when NAME is listed for WORKSPACE.
_sbx_sandbox_uses_workspace() {
  local name=$1 workspace=$2 listing line first
  if (( $# == 3 )); then
    listing=$3
  else
    listing=$(sbx ls) || return
  fi
  while IFS= read -r line; do
    [[ $line == *[[:space:]]"$workspace" ]] || continue
    first=${line%%[[:space:]]*}
    [[ $first == "$name" ]] && return 0
  done <<< "$listing"
  return 1
}

# _sbx_sandbox_field — print one column of `sbx ls` for NAME.
_sbx_sandbox_field() {
  local name=$1 column=$2
  sbx ls | awk -v name="$name" -v column="$column" 'NR > 1 && $1 == name { print $column; exit }'
}

# _sbx_sandbox_exists — true when NAME is a known sandbox.
_sbx_sandbox_exists() {
  local name=$1 existing
  while IFS= read -r existing; do
    [[ $existing == "$name" ]] && return 0
  done < <(sbx ls -q)
  return 1
}

# _sbx_agent_target — print the sbx kit image for AGENT.
_sbx_agent_target() {
  case $1 in
    claude|codex|opencode) printf '%s\n' "$1" ;;
    opencode-ollama) printf '%s\n' 'opencode' ;;
    vibe) printf '%s\n' 'docker.io/docker/sbx-kit-vibe:latest' ;;
    claude-ollama) printf '%s\n' 'docker.io/sbx/claude-ollama:latest' ;;
    *) return 2 ;;
  esac
}

# _sbx_sandbox_meta_file — path of the per-sandbox preset metadata for SANDBOX.
_sbx_sandbox_meta_file() {
  local sandbox=$1
  if [[ ! $sandbox =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    printf 'sandshell: invalid sandbox name: %s\n' "$sandbox" >&2
    return 2
  fi
  printf '%s/sandboxes/%s.meta\n' "$(_sbx_config_dir)" "$sandbox"
}

# _sbx_sandbox_meta_write — atomically record the sandshell preset metadata
# for SANDBOX (preset=..., model=...). Only the small known format is written.
_sbx_sandbox_meta_write() {
  local sandbox=$1 preset=$2 model=$3
  local dir file tmp
  file=$(_sbx_sandbox_meta_file "$sandbox") || return
  dir="$(_sbx_config_dir)/sandboxes"
  [[ ! -L $dir && ! -L $file && ( ! -e $file || -f $file ) ]] || {
    printf 'sandshell: refusing symlink or non-file metadata path: %s\n' "$file" >&2
    return 2
  }
  (umask 077; mkdir -p -- "$dir") || return
  tmp=$(umask 077; mktemp "$dir/.${sandbox}.meta.XXXXXX") || return
  {
    printf 'preset=%s\n' "$preset"
    printf 'model=%s\n' "$model"
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$file"
}

# _sbx_sandbox_meta_read — print "preset<TAB>model" for SANDBOX. Returns 1
# when no metadata exists (existing behavior applies); fails clearly (2) when
# the metadata exists but is not in the known format. The file is parsed as
# data, never sourced or evaluated.
_sbx_sandbox_meta_read() {
  local sandbox=$1 file line key value preset='' model=''
  file=$(_sbx_sandbox_meta_file "$sandbox") || return
  if [[ ! -e $file && ! -L $file ]]; then
    return 1
  fi
  if [[ -L $file || ! -f $file || ! -r $file ]]; then
    printf 'sandshell: refusing unreadable sandbox metadata: %s\n' "$file" >&2
    return 2
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    case $line in
      preset=*|model=*) ;;
      *)
        printf 'sandshell: invalid sandbox metadata: %s\n' "$file" >&2
        return 2
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case $key in
      preset) preset=$value ;;
      model) model=$value ;;
    esac
  done <"$file"
  if [[ $preset != opencode-ollama || ! $model =~ ^[a-zA-Z0-9][a-zA-Z0-9.:/_-]*$ ]]; then
    printf 'sandshell: invalid sandbox metadata: %s\n' "$file" >&2
    return 2
  fi
  printf '%s\t%s\n' "$preset" "$model"
}

# _sbx_vibe_config_validate — fail when the host Vibe config exists but is
# not a readable regular file. A missing config is valid: the bundled
# sandshell preset is synchronized instead.
_sbx_vibe_config_validate() { # CMD
  local cmd=$1 config
  config=$(_sbx_config_dir)/agents/vibe.toml
  if [[ -e $config || -L $config ]] && [[ ! -f $config || ! -r $config ]]; then
    printf '%s: Vibe config not readable: %s\n' "$cmd" "$config" >&2
    return 2
  fi
}

# _sbx_vibe_config_active — print the host Vibe config path when one exists
# and is readable; print nothing when the bundled sandshell preset applies.
_sbx_vibe_config_active() {
  local config
  config=$(_sbx_config_dir)/agents/vibe.toml
  if [[ -f $config && -r $config ]]; then
    printf '%s\n' "$config"
  fi
  return 0
}

# _sbx_vibe_config_write — write the Vibe config from stdin into the sandbox
# as the agent's Vibe configuration and mark it as sandshell-managed, so a
# later resume can safely replace it. MODE is "user" or "preset": a user-config
# sync replaces a config sandshell cannot prove ownership of (with a warning),
# while a preset sync leaves such a config untouched. Writes only inside the
# sandbox VM, never to the host config.
_sbx_vibe_config_write() { # NAME MODE
  local name=$1 mode=$2
  sbx exec -i -u agent "$name" sh -c \
    'set -e
     umask 077
     test ! -L /home/agent/.vibe
     mkdir -p /home/agent/.vibe
     test ! -L /home/agent/.vibe/config.toml
     if [ -e /home/agent/.vibe/config.toml ] && [ ! -e /home/agent/.vibe/.sandshell-config-managed ]; then
       if [ "$1" = preset ]; then
         exit 0
       fi
       echo "sbx: warning: replacing a Vibe config inside the sandbox that sandshell did not manage" >&2
     fi
     cat > /home/agent/.vibe/config.toml
     : > /home/agent/.vibe/.sandshell-config-managed' \
    sandshell "$mode"
}

# _sbx_vibe_config_sync — synchronize the active Vibe config into the sandbox.
# CONFIG is the host config file, or empty to use the bundled sandshell preset.
_sbx_vibe_config_sync() { # NAME CONFIG
  local name=$1 config=$2
  if [[ -n $config ]]; then
    _sbx_vibe_config_write "$name" user <"$config"
  else
    _sbx_vibe_default_config | _sbx_vibe_config_write "$name" preset
  fi
}

# _sbx_vibe_resume_sync — before resuming a Vibe sandbox, validate the current
# host Vibe config and synchronize the active configuration into the sandbox so
# the agent never launches with a stale configuration: the user's
# <config-root>/agents/vibe.toml when one exists, otherwise the bundled
# sandshell preset.
_sbx_vibe_resume_sync() { # NAME
  local name=$1 config
  _sbx_vibe_config_validate sbxr || return
  config=$(_sbx_vibe_config_active)
  if [[ -n $config ]]; then
    printf 'Vibe config: %s\n' "$config" >&2
  else
    printf 'Vibe config: sandshell preset (built-in)\n' >&2
  fi
  _sbx_vibe_config_sync "$name" "$config" || return
}

# _sbx_vibe_setup — synchronize the active Vibe config into the sandbox (the
# user's <config-root>/agents/vibe.toml when one exists, otherwise the bundled
# sandshell preset), configure the Docker MCP gateway, and return the sandbox
# to the stopped state.
_sbx_vibe_setup() {
  local name=$1 sync_status=0 config
  config=$(_sbx_vibe_config_active)
  _sbx_vibe_config_sync "$name" "$config" || sync_status=$?

  if (( sync_status == 0 )); then
    _sbx_vibe_mcp_gateway_setup "$name" || \
      printf 'sbxc: warning: could not configure Vibe for the Docker MCP gateway\n' >&2
  fi

  # sbx exec starts a stopped VM. Keep sbxc create-only on completion/failure.
  sbx stop "$name" || return
  return "$sync_status"
}

sbxc() {
  local agent=claude workspace="$PWD" size=micro name='' clone=0 model=''
  local target cpus memory project env_file='' env_override='' vibe_config
  local existing names matches answer repo_root mode config_root
  local home_physical
  local -a args
  config_root=$(_sbx_config_dir) || return
  vibe_config="$config_root/agents/vibe.toml"

  while (( $# )); do
    case $1 in
      -h|--help)
        printf '%s\n' \
          'Usage: sbxc [-a AGENT] [-d DIR] [-s SIZE] [-n NAME] [--clone] [--env-file FILE] [--model MODEL]' \
          '' \
          'Creates but does not launch a sandbox.' \
          'Agents: claude (default), codex, opencode, vibe, claude-ollama, opencode-ollama' \
          'Sizes:  micro (default: 2 CPUs, 2 GiB), small (2 CPUs, 4 GiB), medium (4 CPUs, 8 GiB)' \
          '  -a, --agent AGENT       Agent' \
          '  -d, --dir DIR           Workspace (default: current directory)' \
          '  -s, --size SIZE         micro | small | medium' \
          '  -n, --name NAME         Name (default: sbx-<project>-<agent>-<random>)' \
          '      --clone             Private Git clone instead of writable host mount' \
          '      --env-file FILE     Use a specific env file' \
          '      --model MODEL       Ollama model for opencode-ollama (default: qwen3.5:4b-mlx)' \
          '  -h, --help              Show help' \
          '' \
          "Environment: $config_root/envs/<project>.env, if present" \
          "Vibe config: $vibe_config (optional; the bundled sandshell preset is used otherwise)" \
          'Skills: none by default; use sbxskill to add selected skills per sandbox.' \
          'A project with existing sandboxes requires confirmation before creating another.'
        return 0 ;;
      -a|--agent|-d|--dir|-s|--size|-n|--name|--env-file|--model)
        if (( $# < 2 )) || [[ -z $2 ]]; then
          printf 'sbxc: missing value for %s\n' "$1" >&2
          return 2
        fi
        case $1 in
          -a|--agent) agent=$2 ;;
          -d|--dir) workspace=$2 ;;
          -s|--size) size=$2 ;;
          -n|--name) name=$2 ;;
          --env-file) env_override=$2 ;;
          --model) model=$2 ;;
        esac
        shift 2 ;;
      --clone) clone=1; shift ;;
      *) printf 'sbxc: unknown option: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  target=$(_sbx_agent_target "$agent") || {
    printf 'sbxc: unsupported agent: %s\n' "$agent" >&2
    return 2
  }
  case $size in
    micro) cpus=2; memory=2g ;;
    small) cpus=2; memory=4g ;;
    medium) cpus=4; memory=8g ;;
    *) printf 'sbxc: invalid size: %s (micro|small|medium)\n' "$size" >&2; return 2 ;;
  esac
  # --model is only valid for the opencode-ollama preset; the default is the
  # opinionated local model. sandshell never pulls or installs it.
  if [[ $agent == opencode-ollama ]]; then
    [[ -n $model ]] || model=qwen3.5:4b-mlx
    [[ $model =~ ^[a-zA-Z0-9][a-zA-Z0-9.:/_-]*$ ]] || {
      printf 'sbxc: invalid model: %s\n' "$model" >&2
      return 2
    }
  elif [[ -n $model ]]; then
    printf 'sbxc: --model is only supported for the opencode-ollama agent\n' >&2
    return 2
  fi

  if [[ ! -d $workspace ]]; then
    printf 'sbxc: directory not found: %s\n' "$workspace" >&2
    return 2
  fi
  workspace=$(cd -P -- "$workspace" && pwd -P) || return
  home_physical=$(cd -P -- "$HOME" && pwd -P) || return

  if [[ $workspace == / || $workspace == "$home_physical" || $home_physical == "$workspace"/* ]]; then
    printf 'sbxc: refusing broad workspace: %s\n' "$workspace" >&2
    return 2
  fi
  case $workspace in
    "$home_physical"/.ssh|"$home_physical"/.ssh/*|\
    "$home_physical"/.gnupg|"$home_physical"/.gnupg/*|\
    "$home_physical"/.aws|"$home_physical"/.aws/*|\
    "$home_physical"/.config|"$home_physical"/.config/*|\
    /etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|\
    /var|/var/*|/System|/System/*|/Library|/Library/*|\
    /dev|/dev/*|/proc|/proc/*|/sys|/sys/*)
      printf 'sbxc: refusing sensitive workspace: %s\n' "$workspace" >&2
      return 2 ;;
  esac

  mode=direct
  repo_root=''
  if (( clone )); then
    if ! command -v git >/dev/null 2>&1 || ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf 'sbxc: --clone requires a Git working tree\n' >&2
      return 2
    fi
    mode=clone
  elif command -v git >/dev/null 2>&1; then
    repo_root=$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null) || repo_root=''
    [[ -n $repo_root && -f $repo_root/.git ]] && mode=worktree
  fi

  project=$(_sbx_project_name "$workspace") || return
  if [[ -z $name ]]; then
    name="sbx-${project}-${agent}-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
  elif [[ ! $name =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ || $name == default || ${#name} -lt 2 ]]; then
    printf 'sbxc: invalid sandbox name: %s\n' "$name" >&2
    return 2
  fi

  if ! command -v sbx >/dev/null 2>&1; then
    printf 'sbxc: sbx CLI not found\n' >&2
    return 127
  fi
  # A missing Vibe config is fine (Docker/Vibe defaults apply); one that
  # exists but is not a readable regular file must fail clearly.
  if [[ $agent == vibe ]]; then
    _sbx_vibe_config_validate sbxc || return
  fi

  if [[ -n $env_override ]]; then
    env_file=$env_override
    if [[ ! -f $env_file || ! -r $env_file ]]; then
      printf 'sbxc: env file not readable: %s\n' "$env_file" >&2
      return 2
    fi
  else
    env_file="$config_root/envs/$project.env"
    if [[ -e $env_file ]]; then
      if [[ ! -f $env_file || ! -r $env_file ]]; then
        printf 'sbxc: env file not readable: %s\n' "$env_file" >&2
        return 2
      fi
    else
      env_file=''
    fi
  fi

  names=$(sbx ls -q) || return
  while IFS= read -r existing; do
    if [[ $existing == "$name" ]]; then
      printf 'sbxc: sandbox already exists: %s\n' "$name" >&2
      return 2
    fi
  done <<< "$names"

  matches=$(_sbx_workspace_rows "$workspace") || return
  if [[ -n $matches ]]; then
    printf 'Existing sandboxes for %s:\n%s\n' "$workspace" "$matches" >&2
    printf 'Use sbxr NAME to resume one.\n' >&2
    if ! _sandshell_tty_available; then
      printf 'sbxc: refusing duplicate workspace without interactive confirmation\n' >&2
      return 1
    fi
    printf 'Create another sandbox for this workspace? [y/N] ' > /dev/tty || return
    IFS= read -r answer < /dev/tty || return
    case $answer in y|Y|yes|YES) ;; *) printf 'sbxc: cancelled\n' >&2; return 1 ;; esac
  fi

  case $mode in
    clone)
      printf 'Mode: clone — agent edits a private in-sandbox Git clone; sbx may change host Git remote configuration.\n' >&2 ;;
    worktree)
      printf 'Mode: host worktree — agent can edit/delete files in the host worktree directly (Git history is not mounted).\n' >&2 ;;
    direct)
      printf 'Mode: direct — agent can edit/delete host files in %s.\n' "$workspace" >&2 ;;
  esac

  args=(--name "$name" --cpus "$cpus" --memory "$memory" --pull missing --skills off)
  (( clone )) && args+=(--clone)
  [[ -n $env_file ]] && args+=(--env-file "$env_file")
  printf 'Creating sandbox: %s\n' "$name" >&2
  sbx create "${args[@]}" "$target" "$workspace" || return
  _sbx_skill_state_init "$name" || printf 'sbxc: warning: could not initialize isolated skill state for %s\n' "$name" >&2
  # Remember the opencode-ollama preset and its selected model so sbxr can
  # resume the sandbox with the Ollama provider/model selection.
  if [[ $agent == opencode-ollama ]]; then
    _sbx_sandbox_meta_write "$name" opencode-ollama "$model" || \
      printf 'sbxc: warning: could not record the opencode-ollama preset for %s\n' "$name" >&2
  fi
  if [[ $agent == vibe ]]; then
    _sbx_vibe_setup "$name" || return
  fi
  # Composite callers (sbxwt create) print their own summary ending with the
  # resume hint; _sandshell_skip_resume_hint suppresses this duplicate.
  if [[ ${_sandshell_skip_resume_hint:-} != 1 ]]; then
    printf 'Created sandbox: %s\n' "$name" >&2
    printf 'Resume with: sbxr %s\n' "$name" >&2
  fi
}

# Resume a named sandbox; stored environment values persist unless overridden.
sbxr() {
  local name='' env_file='' env_explicit=0 all=0 existing names found=0 workspace rows listing header
  local project candidate wt_path branch match main_worktree repo_match=0 agent
  local meta meta_rc preset meta_model
  local -a args

  while (( $# )); do
    case $1 in
      -h|--help)
        printf '%s\n' \
          'Usage: sbxr [NAME] [--env-file FILE] | sbxr [--all]' \
          '' \
          '  sbxr               List sandboxes for the current Git repository/worktrees' \
          '  sbxr --all         List all sandboxes' \
          '  sbxr NAME          Resume an existing sandbox (never creates one)' \
          '                     Auto-applies the repository project env when applicable' \
          '                     Vibe sandboxes re-synchronize the current Vibe config first' \
          '                     opencode-ollama sandboxes resume with their recorded Ollama provider/model' \
          '  --env-file FILE    Explicit environment override for this session' \
          '  -h, --help         Show help'
        return 0 ;;
      --all) all=1; shift ;;
      --env-file)
        if (( $# < 2 )) || [[ -z $2 ]]; then
          printf 'sbxr: missing value for %s\n' "$1" >&2
          return 2
        fi
        env_file=$2
        env_explicit=1
        shift 2 ;;
      -*) printf 'sbxr: unknown option: %s\n' "$1" >&2; return 2 ;;
      *)
        if [[ -n $name ]]; then
          printf 'sbxr: unexpected argument: %s\n' "$1" >&2
          return 2
        fi
        name=$1
        shift ;;
    esac
  done

  if ! command -v sbx >/dev/null 2>&1; then
    printf 'sbxr: sbx CLI not found\n' >&2
    return 127
  fi
  if (( all )); then
    if [[ -n $name ]] || (( env_explicit )); then
      printf 'sbxr: --all cannot be combined with NAME or --env-file\n' >&2
      return 2
    fi
    sbx ls
    return $?
  fi
  if [[ -z $name ]]; then
    if (( env_explicit )); then
      printf 'sbxr: --env-file requires a sandbox name\n' >&2
      return 2
    fi
    workspace=$(cd -P -- "$PWD" && pwd -P) || return
    listing=$(sbx ls) || return
    rows=''
    if command -v git >/dev/null 2>&1 && git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      while IFS=$'\t' read -r wt_path branch; do
        match=$(_sbx_workspace_rows "$wt_path" "$listing") || return
        [[ -n $match ]] && rows+="${rows:+$'\n'}$match"
      done < <(_sbx_git_worktrees "$workspace")
    else
      rows=$(_sbx_workspace_rows "$workspace" "$listing") || return
    fi
    if [[ -n $rows ]]; then
      header=${listing%%$'\n'*}
      printf '%s\n%s\n' "$header" "$rows"
    else
      printf 'No sandboxes for the current workspace/repository (use sbxr --all to see all).\n'
    fi
    return 0
  fi
  if (( env_explicit )) && [[ ! -f $env_file || ! -r $env_file ]]; then
    printf 'sbxr: env file not readable: %s\n' "$env_file" >&2
    return 2
  fi

  names=$(sbx ls -q) || return
  while IFS= read -r existing; do
    if [[ $existing == "$name" ]]; then
      found=1
      break
    fi
  done <<< "$names"
  if (( ! found )); then
    printf 'sbxr: sandbox not found: %s\n' "$name" >&2
    return 1
  fi

  # Vibe sandboxes re-synchronize the current host Vibe config before launch
  # so a resumed agent never reads a stale configuration. The agent is taken
  # from the sandbox listing, not from the sandbox name.
  agent=$(_sbx_sandbox_field "$name" 2) || return
  case $agent in
    vibe|*vibe*)
      _sbx_vibe_resume_sync "$name" || return
      ;;
  esac

  if (( ! env_explicit )); then
    workspace=$(cd -P -- "$PWD" && pwd -P) || return
    listing=$(sbx ls) || return
    repo_match=0
    main_worktree=''
    if command -v git >/dev/null 2>&1 && git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      main_worktree=$(_sbx_git_main_worktree "$workspace") || main_worktree=''
      # The branch column is intentionally ignored; only the worktree path is used.
      # shellcheck disable=SC2034
      while IFS=$'\t' read -r wt_path branch; do
        if _sbx_sandbox_uses_workspace "$name" "$wt_path" "$listing"; then
          repo_match=1
          break
        fi
      done < <(_sbx_git_worktrees "$workspace")
    elif _sbx_sandbox_uses_workspace "$name" "$workspace" "$listing"; then
      repo_match=1
      main_worktree=$workspace
    fi
    if (( repo_match )); then
      project=$(_sbx_project_name "${main_worktree:-$workspace}") || return
      candidate="$(_sbx_config_dir)/envs/$project.env"
      if [[ -e $candidate ]]; then
        if [[ ! -f $candidate || ! -r $candidate ]]; then
          printf 'sbxr: project env file not readable: %s\n' "$candidate" >&2
          return 2
        fi
        env_file=$candidate
        printf 'Environment: %s\n' "$env_file" >&2
      fi
    fi
  fi

  printf 'Resuming sandbox: %s (host workspace access depends on its original mode).\n' "$name" >&2
  args=(run --name "$name")
  # A sandshell preset recorded at creation time (opencode-ollama) adds the
  # Docker Sandbox provider/model selection to the resume. Absent metadata
  # keeps the existing behavior; invalid metadata fails clearly.
  meta=$(_sbx_sandbox_meta_read "$name")
  meta_rc=$?
  case $meta_rc in
    0) ;;
    1) ;;
    *) return "$meta_rc" ;;
  esac
  if (( meta_rc == 0 )); then
    IFS=$'\t' read -r preset meta_model <<<"$meta"
    case $preset in
      opencode-ollama) args+=(--provider ollama --model "$meta_model") ;;
    esac
  fi
  [[ -n $env_file ]] && args+=(--env-file "$env_file")
  sbx "${args[@]}"
}

# Edit the environment file used by sbxc for the current workspace.
sbxenv() {
  local workspace project env_dir env_file editor='' selection
  local -a editor_args=()

  case $# in
    0) ;;
    1)
      case $1 in
        -h|--help)
          printf '%s\n' \
            'Usage: sbxenv [EDITOR]' \
            "Edit $(_sbx_config_dir)/envs/<project>.env for the current directory." \
            'Editor priority: EDITOR argument, then micro, VISUAL, EDITOR, or vi.' \
            'Creates a missing env file with permissions 600.'
          return 0 ;;
        -*) printf 'sbxenv: unknown option: %s\n' "$1" >&2; return 2 ;;
        *) editor=$1; editor_args=("$1") ;;
      esac ;;
    *) printf 'sbxenv: expected at most one editor argument\n' >&2; return 2 ;;
  esac

  if [[ -z $editor ]]; then
    if command -v micro >/dev/null 2>&1; then
      editor=micro
      editor_args=(micro)
    else
      for selection in "${VISUAL:-}" "${EDITOR:-}" vi; do
        [[ -n $selection ]] || continue
        if [[ -n ${ZSH_VERSION:-} ]]; then
          # Zsh-only (z) flag word splitting, guarded by the ZSH_VERSION check.
          # shellcheck disable=SC2296,SC2206
          editor_args=(${(z)selection})
          editor=${editor_args[1]-}
        else
          IFS=$' \t' read -r -a editor_args <<< "$selection"
          editor=${editor_args[0]-}
        fi
        [[ -n $editor ]] && command -v "$editor" >/dev/null 2>&1 && break
        editor=''
      done
    fi
  fi
  if [[ -z $editor ]]; then
    printf 'sbxenv: no editor found; set VISUAL or EDITOR, or pass one: sbxenv EDITOR\n' >&2
    return 127
  fi
  if ! command -v "$editor" >/dev/null 2>&1; then
    printf 'sbxenv: editor not found: %s\n' "$editor" >&2
    return 127
  fi

  workspace=$(cd -P -- "$PWD" && pwd -P) || return
  project=$(_sbx_project_name "$workspace") || return
  env_dir="$(_sbx_config_dir)/envs"
  env_file="$env_dir/$project.env"

  if [[ -L $env_dir || -L $env_file || ( -e $env_file && ! -f $env_file ) ]]; then
    printf 'sbxenv: refusing symlink or non-file path: %s\n' "$env_file" >&2
    return 2
  fi
  mkdir -p -- "$env_dir" || return
  if [[ ! -e $env_file ]]; then
    (umask 077; set -C; : > "$env_file") || return
  fi

  "${editor_args[@]}" "$env_file"
}

# ---------------------------------------------------------------------------
# src/mcp.sh
# ---------------------------------------------------------------------------

# shellcheck shell=bash
# Per-sandbox MCP management: sbxmcp, MCP state tracking, and agent-specific
# Docker MCP gateway configuration.

# _sbx_mcp_state_file — path of the tracked-server list for SANDBOX.
_sbx_mcp_state_file() {
  local sandbox=$1
  if [[ ! $sandbox =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    printf 'sbxmcp: invalid sandbox name: %s\n' "$sandbox" >&2
    return 2
  fi
  printf '%s/mcp/%s.servers\n' "$(_sbx_config_dir)" "$sandbox"
}

# _sbx_mcp_state_has — true when SANDBOX already tracks SERVER.
_sbx_mcp_state_has() {
  local file
  file=$(_sbx_mcp_state_file "$1") || return
  [[ ! -L $file && -f $file ]] && grep -Fqx -- "$2" "$file"
}

# _sbx_mcp_state_add — record SERVER as tracked for SANDBOX.
_sbx_mcp_state_add() {
  local sandbox=$1 server=$2 dir file
  dir="$(_sbx_config_dir)/mcp"
  file="$dir/$sandbox.servers"

  [[ ! -L $dir && ! -L $file && ( ! -e $file || -f $file ) ]] || {
    printf 'sbxmcp: refusing symlink or non-file state path: %s\n' "$file" >&2
    return 2
  }

  (umask 077; mkdir -p -- "$dir") || return
  _sbx_mcp_state_has "$sandbox" "$server" && return 0
  (umask 077; printf '%s\n' "$server" >> "$file")
}

# _sbx_vibe_mcp_gateway_setup — register the Docker MCP gateway with Vibe.
_sbx_vibe_mcp_gateway_setup() {
  local name=$1
  sbx exec -u agent "$name" sh -c '
    set -e
    [ -n "${MCP_GATEWAY_URL:-}" ] || exit 2
    [ -n "${MCP_SENTINEL_TOKEN_NAME:-}" ] || exit 2
    command -v vibe >/dev/null 2>&1 || exit 2
    config=${VIBE_HOME:-/home/agent/.vibe}/config.toml
    mkdir -p "${config%/*}"
    if ! grep -Fq '\''name = "docker-sbx-gateway"'\'' "$config" 2>/dev/null; then
      VIBE_CLI=python vibe mcp add docker-sbx-gateway \
        --url "$MCP_GATEWAY_URL" \
        --transport streamable-http \
        --allow-insecure-http \
        --api-key-env MCP_SENTINEL_TOKEN_NAME \
        --api-key-header Authorization \
        --api-key-format "Bearer {token}" >/dev/null
    fi
  '
}

# _sbx_claude_mcp_gateway_setup — register the Docker MCP gateway with Claude Code.
_sbx_claude_mcp_gateway_setup() {
  local name=$1
  sbx exec -u agent "$name" sh -c '
    set -e
    [ -n "${MCP_GATEWAY_URL:-}" ] || exit 2
    [ -n "${MCP_SENTINEL_TOKEN_NAME:-}" ] || exit 2
    command -v claude >/dev/null 2>&1 || exit 2
    claude mcp add mcp-gateway "$MCP_GATEWAY_URL" \
      --transport http \
      --scope user \
      --header "Authorization: Bearer $MCP_SENTINEL_TOKEN_NAME" >/dev/null 2>&1 || true
  '
}

# _sbx_mcp_confirm_local — require explicit approval for host-command MCPs.
_sbx_mcp_confirm_local() {
  local sandbox=$1 server=$2 details=$3 answer
  if ! printf '%s\n' "$details" | grep -Eq \
    '"(type|transport)"[[:space:]]*:[[:space:]]*"(local|local-stdio|local stdio|stdio)"|"local"[[:space:]]*:[[:space:]]*true|"command"[[:space:]]*:[[:space:]]*"[^"]+'; then
    return 0
  fi

  printf 'MCP server %s runs a local stdio command on the HOST with your user permissions.\n' "$server" >&2
  printf 'Target sandbox: %s\n' "$sandbox" >&2
  if [[ ! -t 0 ]]; then
    printf 'sbxmcp: refusing host-command MCP without interactive approval\n' >&2
    return 1
  fi
  printf 'Load this MCP server? [y/N] ' > /dev/tty || return
  IFS= read -r answer < /dev/tty 2>/dev/null || return
  case $answer in y|Y|yes|YES) return 0 ;; esac
  printf 'sbxmcp: cancelled\n' >&2
  return 1
}

# _sbx_mcp_attach — load SERVER into SANDBOX, tracking it on success.
_sbx_mcp_attach() {
  local sandbox=$1 server=$2 sandbox_status agent details started=0 rc=0

  details=$(sbx mcp inspect "$server" --json) || {
    printf 'sbxmcp: MCP server is not registered: %s\n' "$server" >&2
    return 2
  }
  _sbx_mcp_confirm_local "$sandbox" "$server" "$details" || return

  sandbox_status=$(_sbx_sandbox_field "$sandbox" 3) || return
  agent=$(_sbx_sandbox_field "$sandbox" 2) || return
  case $sandbox_status in
    running) ;;
    stopped)
      printf 'sbxmcp: temporarily starting %s without launching the agent\n' "$sandbox" >&2
      sbx exec "$sandbox" true >/dev/null || return
      started=1 ;;
    *)
      printf 'sbxmcp: sandbox is not in a usable state: %s (%s)\n' "$sandbox" "${sandbox_status:-unknown}" >&2
      return 1 ;;
  esac

  case $agent in
    vibe|*vibe*)
      _sbx_vibe_mcp_gateway_setup "$sandbox" || {
        printf 'sbxmcp: failed to configure Vibe for the Docker MCP gateway\n' >&2
        rc=1
      } ;;
    claude-ollama|*claude-ollama*)
      _sbx_claude_mcp_gateway_setup "$sandbox" || {
        printf 'sbxmcp: failed to configure Claude/Ollama for the Docker MCP gateway\n' >&2
        rc=1
      } ;;
  esac

  if (( rc == 0 )); then
    sbx mcp load "$server" --sandbox "$sandbox" || rc=$?
  fi
  if (( rc == 0 )); then
    _sbx_mcp_state_add "$sandbox" "$server" || rc=$?
  fi

  if (( started )); then
    sbx stop "$sandbox" >/dev/null || {
      printf 'sbxmcp: warning: failed to restore stopped state for %s\n' "$sandbox" >&2
      (( rc == 0 )) && rc=1
    }
  fi
  return "$rc"
}

# _sandshell_sbxmcp_help — print sbxmcp usage.
_sandshell_sbxmcp_help() {
  printf '%s\n' \
    'Usage:' \
    '  sbxmcp [ls]                     List host-registered MCP servers' \
    '  sbxmcp ls SANDBOX               List MCP servers tracked for a sandbox' \
    '  sbxmcp add SANDBOX SERVER [...] Attach registered MCP server(s)' \
    '  sbxmcp copy SOURCE TARGET       Copy tracked MCP set to another sandbox' \
    '' \
    "State: $(_sbx_config_dir)/mcp/<sandbox>.servers" \
    'Docker persists loaded MCP servers across sandbox restarts.' \
    'Local/stdio MCP servers run host commands and require interactive approval.'
}

# Manage per-sandbox MCP attachments using Docker's host MCP registry.
sbxmcp() {
  local command=${1:-ls} sandbox='' source='' target='' server file
  local -a servers

  case $command in
    -h|--help)
      _sandshell_sbxmcp_help
      return 0 ;;
  esac
  # `sbxmcp SUBCOMMAND --help` shows help instead of a confusing error.
  if [[ ${2:-} == -h || ${2:-} == --help ]]; then
    case $command in
      ls|add|copy)
        _sandshell_sbxmcp_help
        return 0 ;;
    esac
  fi
  if ! command -v sbx >/dev/null 2>&1; then
    printf 'sbxmcp: sbx CLI not found\n' >&2
    return 127
  fi

  case $command in
    ls)
      (( $# > 0 )) && shift
      if (( $# == 0 )); then
        sbx mcp ls
        return $?
      fi
      if (( $# != 1 )); then
        printf 'sbxmcp: usage: sbxmcp ls [SANDBOX]\n' >&2
        return 2
      fi
      sandbox=$1
      if ! _sbx_sandbox_exists "$sandbox"; then
        printf 'sbxmcp: sandbox not found: %s\n' "$sandbox" >&2
        return 1
      fi
      file=$(_sbx_mcp_state_file "$sandbox") || return
      if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
        printf 'sbxmcp: refusing symlink or non-file state path: %s\n' "$file" >&2
        return 2
      elif [[ -s $file ]]; then
        printf 'Tracked MCP servers for %s:\n' "$sandbox"
        cat -- "$file"
      else
        printf 'No MCP servers tracked for %s.\n' "$sandbox"
      fi
      ;;

    add)
      shift
      if (( $# < 2 )); then
        printf 'sbxmcp: usage: sbxmcp add SANDBOX SERVER [...]\n' >&2
        return 2
      fi
      sandbox=$1; shift
      if [[ ! $sandbox =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
        printf 'sbxmcp: invalid sandbox name: %s\n' "$sandbox" >&2
        return 2
      fi
      if ! _sbx_sandbox_exists "$sandbox"; then
        printf 'sbxmcp: sandbox not found: %s\n' "$sandbox" >&2
        return 1
      fi
      for server in "$@"; do
        if [[ ! $server =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
          printf 'sbxmcp: invalid MCP server name: %s\n' "$server" >&2
          return 2
        fi
        printf 'Attaching MCP %s -> %s\n' "$server" "$sandbox" >&2
        _sbx_mcp_attach "$sandbox" "$server" || return
      done
      ;;

    copy)
      shift
      if (( $# != 2 )); then
        printf 'sbxmcp: usage: sbxmcp copy SOURCE TARGET\n' >&2
        return 2
      fi
      source=$1; target=$2
      if [[ $source == "$target" ]]; then
        printf 'sbxmcp: source and target are the same sandbox\n' >&2
        return 2
      fi
      if ! _sbx_sandbox_exists "$source"; then
        printf 'sbxmcp: source sandbox not found: %s\n' "$source" >&2
        return 1
      fi
      if ! _sbx_sandbox_exists "$target"; then
        printf 'sbxmcp: target sandbox not found: %s\n' "$target" >&2
        return 1
      fi
      file=$(_sbx_mcp_state_file "$source") || return
      if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
        printf 'sbxmcp: refusing symlink or non-file state path: %s\n' "$file" >&2
        return 2
      fi
      if [[ ! -s $file ]]; then
        printf 'sbxmcp: no tracked MCP servers for %s\n' "$source" >&2
        return 0
      fi
      servers=()
      while IFS= read -r server; do
        [[ -n $server ]] && servers+=("$server")
      done < "$file"
      for server in "${servers[@]}"; do
        printf 'Copying MCP %s -> %s\n' "$server" "$target" >&2
        _sbx_mcp_attach "$target" "$server" || return
      done
      ;;

    *)
      printf 'sbxmcp: unknown command: %s\n' "$command" >&2
      printf 'Run sbxmcp --help for usage.\n' >&2
      return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# src/skills.sh
# ---------------------------------------------------------------------------

# shellcheck shell=bash
# Isolated per-sandbox skills: sbxskill, per-sandbox skill state, and the
# copy/sync helpers that populate agent-specific skill locations.

# _sbx_vibe_skill_valid — conservative check for Vibe's 1024-character
# description limit. Supports scalar and indented multiline YAML descriptions
# without modifying the original SKILL.md. Malformed metadata may still be
# rejected by Vibe itself.
_sbx_vibe_skill_valid() {
  awk '
    NR == 1 { if ($0 != "---") exit 1; next }
    $0 == "---" {
      if (!saw_description || length_of_description > 1024) exit 1
      exit 0
    }
    /^description:[[:space:]]*/ {
      saw_description = 1
      text = $0
      sub(/^description:[[:space:]]*/, "", text)
      if (text ~ /^[|>][-+]?[[:space:]]*$/) {
        multiline = 1
      } else {
        length_of_description = length(text)
      }
      next
    }
    multiline && /^[[:space:]]+/ {
      text = $0
      sub(/^[[:space:]]+/, "", text)
      length_of_description += length(text) + 1
      next
    }
    multiline && /^[^[:space:]#]/ { multiline = 0 }
    END { if (!saw_description || length_of_description > 1024) exit 1 }
  ' "$1"
}

# _sbx_skill_state_file — path of the selected-skill list for SANDBOX.
_sbx_skill_state_file() {
  local sandbox=$1
  if [[ ! $sandbox =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    printf 'sbxskill: invalid sandbox name: %s\n' "$sandbox" >&2
    return 2
  fi
  printf '%s/skills/%s.skills\n' "$(_sbx_config_dir)" "$sandbox"
}

# _sbx_skill_state_init — create the empty per-sandbox skill tracking file.
_sbx_skill_state_init() {
  local sandbox=$1 dir file
  dir="$(_sbx_config_dir)/skills"
  file="$dir/$sandbox.skills"
  [[ ! -L $dir && ! -L $file && ( ! -e $file || -f $file ) ]] || {
    printf 'sbxskill: refusing symlink or non-file state path: %s\n' "$file" >&2
    return 2
  }
  (umask 077; mkdir -p -- "$dir" && { [[ -e $file ]] || : > "$file"; })
}

# _sbx_skill_state_require — fail unless SANDBOX uses managed skill state.
_sbx_skill_state_require() {
  local file
  file=$(_sbx_skill_state_file "$1") || return
  if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
    printf 'sbxskill: refusing symlink or non-file state path: %s\n' "$file" >&2
    return 2
  fi
  if [[ ! -f $file ]]; then
    printf 'sbxskill: sandbox is not using wrapper-managed isolated skills: %s\n' "$1" >&2
    printf 'This sandbox must be created with `sbxc` so skills are managed per sandbox.\n' >&2
    return 3
  fi
}

# _sbx_skill_state_has — true when SANDBOX already selects SKILL.
_sbx_skill_state_has() {
  local file
  file=$(_sbx_skill_state_file "$1") || return
  [[ ! -L $file && -f $file ]] && grep -Fqx -- "$2" "$file"
}

# _sbx_skill_state_add — record SKILL as selected for SANDBOX.
_sbx_skill_state_add() {
  local sandbox=$1 skill=$2 file
  _sbx_skill_state_require "$sandbox" || return
  file=$(_sbx_skill_state_file "$sandbox") || return
  _sbx_skill_state_has "$sandbox" "$skill" && return 0
  (umask 077; printf '%s\n' "$skill" >> "$file")
}

# _sbx_skill_state_remove — drop SKILL from the SANDBOX selection.
_sbx_skill_state_remove() {
  local sandbox=$1 skill=$2 file dir tmp line
  _sbx_skill_state_require "$sandbox" || return
  file=$(_sbx_skill_state_file "$sandbox") || return
  dir=${file%/*}
  tmp=$(umask 077; mktemp "$dir/.${sandbox}.skills.XXXXXX") || return
  while IFS= read -r line; do
    [[ $line == "$skill" ]] || printf '%s\n' "$line" >> "$tmp"
  done < "$file"
  mv -- "$tmp" "$file"
}

# _sbx_skill_store — Docker's shared host-wide skill catalog.
_sbx_skill_store() {
  case $(uname -s) in
    Darwin) printf '%s\n' "$HOME/Library/Application Support/com.docker.sandboxes/sandboxes/agent-skills" ;;
    Linux) printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/sandboxes/sandboxes/agent-skills" ;;
    *) printf 'sbxskill: unsupported host OS for shared skill store\n' >&2; return 2 ;;
  esac
}

# _sbx_skill_target — in-sandbox skill directory for AGENT.
_sbx_skill_target() {
  case $1 in
    *claude-ollama*|claude) printf '%s\n' '/home/agent/.claude/skills' ;;
    codex|*codex*|opencode|*opencode*) printf '%s\n' '/home/agent/.agents/skills' ;;
    vibe|*vibe*) printf '%s\n' '/home/agent/.vibe/skills' ;;
    *) printf 'sbxskill: unsupported sandbox agent: %s\n' "$1" >&2; return 2 ;;
  esac
}

# _sbx_skill_source — print the catalog path of SKILL, validating its name.
_sbx_skill_source() {
  local skill=$1 store skill_path
  if [[ ! $skill =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ || $skill == .. ]]; then
    printf 'sbxskill: invalid skill name: %s\n' "$skill" >&2
    return 2
  fi
  store=$(_sbx_skill_store) || return
  if [[ ! -d $store || -L $store ]]; then
    printf 'sbxskill: shared skill store missing or symlinked: %s\n' "$store" >&2
    return 2
  fi
  skill_path="$store/$skill"
  if [[ ! -d $skill_path || -L $skill_path || ! -f $skill_path/SKILL.md || -L $skill_path/SKILL.md ]]; then
    printf 'sbxskill: skill is not available in the shared store: %s\n' "$skill" >&2
    return 1
  fi
  printf '%s\n' "$skill_path"
}

# _sbx_skill_copy_into — copy SKILL from the catalog into the sandbox.
_sbx_skill_copy_into() {
  local sandbox=$1 agent=$2 target=$3 skill=$4 replace=${5:-0}
  local store source_path
  local -a tar_args

  source_path=$(_sbx_skill_source "$skill") || return
  store=${source_path%/*}

  if [[ $agent == vibe || $agent == *vibe* ]]; then
    if ! _sbx_vibe_skill_valid "$source_path/SKILL.md"; then
      printf 'sbxskill: Vibe-incompatible skill metadata: %s (description may exceed 1024 chars)\n' "$skill" >&2
      return 2
    fi
  fi

  case $(uname -s) in
    Darwin) tar_args=(--no-xattrs --no-acls --no-fflags) ;;
    Linux) tar_args=(--no-xattrs --no-acls) ;;
    *) tar_args=() ;;
  esac

  (set -o pipefail
   COPYFILE_DISABLE=1 tar "${tar_args[@]}" -C "$store" -cf - "$skill" | \
     sbx exec -i -u agent "$sandbox" sh -c '
       set -eu
       target=$1; skill=$2; replace=$3
       test ! -L "$target"
       mkdir -p "$target"
       if [ -L "$target/$skill" ]; then
         echo "sbxskill: refusing to replace shared/symlinked skill: $skill" >&2
         exit 42
       fi
       if [ "$replace" != 1 ] && [ -e "$target/$skill" ]; then
         echo "sbxskill: skill path already exists; refusing to overwrite: $skill" >&2
         exit 43
       fi
       stage=$(mktemp -d /home/agent/.sbx-skill.XXXXXX)
       trap '\''rm -rf "$stage"'\'' EXIT HUP INT TERM
       tar -C "$stage" --no-same-owner -xf -
       [ -d "$stage/$skill" ] && [ -f "$stage/$skill/SKILL.md" ]
       if [ "$replace" = 1 ]; then
         rm -rf "$target/$skill"
       fi
       mv "$stage/$skill" "$target/$skill"
     ' sh "$target" "$skill" "$replace"
  )
}

# _sandshell_sbxskill_help — print sbxskill usage.
_sandshell_sbxskill_help() {
  printf '%s\n' \
    'Usage:' \
    '  sbxskill available                     List skills in the Docker shared catalog' \
    '  sbxskill ls SANDBOX                    List skills selected for a sandbox' \
    '  sbxskill add SANDBOX SKILL [...]       Add one or more skills' \
    '  sbxskill add SANDBOX --all             Add every available skill' \
    '  sbxskill remove SANDBOX SKILL [...]    Remove one or more managed skills' \
    '  sbxskill remove SANDBOX --all          Remove all managed skills' \
    '  sbxskill sync SANDBOX                  Refresh selected skills from the catalog' \
    '  sbxskill copy SOURCE TARGET            Add SOURCE selections to TARGET' \
    '' \
    "State: $(_sbx_config_dir)/skills/<sandbox>.skills" \
    'sbxc uses --skills off, so only explicitly selected skills are visible.' \
    'After skill changes, start a new agent session; Vibe can also use /reload.'
}

# Manage isolated per-sandbox skills selected from Docker's shared skill catalog.
sbxskill() {
  local command=${1:-available} sandbox='' source='' target='' skill file
  local sandbox_status agent skill_target skill_names started=0 rc=0
  local -a skills available

  case $command in
    -h|--help)
      _sandshell_sbxskill_help
      return 0 ;;
  esac
  # `sbxskill SUBCOMMAND --help` shows help instead of a confusing error.
  if [[ ${2:-} == -h || ${2:-} == --help ]]; then
    case $command in
      available|ls|add|remove|sync|copy)
        _sandshell_sbxskill_help
        return 0 ;;
    esac
  fi
  if ! command -v sbx >/dev/null 2>&1; then
    printf 'sbxskill: sbx CLI not found\n' >&2
    return 127
  fi

  case $command in
    available)
      (( $# > 0 )) && shift
      if (( $# != 0 )); then
        printf 'sbxskill: usage: sbxskill available\n' >&2
        return 2
      fi
      sbx skills ls
      return $? ;;

    ls)
      shift
      if (( $# != 1 )); then
        printf 'sbxskill: usage: sbxskill ls SANDBOX\n' >&2
        return 2
      fi
      sandbox=$1
      _sbx_sandbox_exists "$sandbox" || {
        printf 'sbxskill: sandbox not found: %s\n' "$sandbox" >&2
        return 1
      }
      _sbx_skill_state_require "$sandbox" || return
      file=$(_sbx_skill_state_file "$sandbox") || return
      if [[ -s $file ]]; then
        printf 'Selected skills for %s:\n' "$sandbox"
        cat -- "$file"
      else
        printf 'No skills selected for %s.\n' "$sandbox"
      fi
      return 0 ;;

    add)
      shift
      if (( $# < 2 )); then
        printf 'sbxskill: usage: sbxskill add SANDBOX SKILL [...] | --all\n' >&2
        return 2
      fi
      sandbox=$1; shift
      _sbx_sandbox_exists "$sandbox" || {
        printf 'sbxskill: sandbox not found: %s\n' "$sandbox" >&2
        return 1
      }
      _sbx_skill_state_require "$sandbox" || return
      if [[ ${1:-} == --all ]]; then
        if (( $# != 1 )); then
          printf 'sbxskill: --all cannot be combined with skill names\n' >&2
          return 2
        fi
        skill_names=$(sbx skills ls -q) || return
        available=()
        while IFS= read -r skill; do [[ -n $skill ]] && available+=("$skill"); done <<< "$skill_names"
        skills=("${available[@]}")
      else
        skills=("$@")
      fi
      if (( ${#skills[@]} == 0 )); then
        printf 'sbxskill: no available skills to add\n' >&2
        return 0
      fi

      sandbox_status=$(_sbx_sandbox_field "$sandbox" 3) || return
      agent=$(_sbx_sandbox_field "$sandbox" 2) || return
      skill_target=$(_sbx_skill_target "$agent") || return
      case $sandbox_status in
        running) ;;
        stopped)
          printf 'sbxskill: temporarily starting %s without launching the agent\n' "$sandbox" >&2
          sbx exec "$sandbox" true >/dev/null || return
          started=1 ;;
        *) printf 'sbxskill: sandbox is not in a usable state: %s (%s)\n' "$sandbox" "${sandbox_status:-unknown}" >&2; return 1 ;;
      esac

      for skill in "${skills[@]}"; do
        if _sbx_skill_state_has "$sandbox" "$skill"; then
          printf 'sbxskill: already selected: %s\n' "$skill" >&2
          continue
        fi
        printf 'Adding skill %s -> %s\n' "$skill" "$sandbox" >&2
        _sbx_skill_copy_into "$sandbox" "$agent" "$skill_target" "$skill" 0 || { rc=$?; break; }
        _sbx_skill_state_add "$sandbox" "$skill" || { rc=$?; break; }
      done
      if (( started )); then
        sbx stop "$sandbox" >/dev/null || { printf 'sbxskill: warning: failed to restore stopped state for %s\n' "$sandbox" >&2; (( rc == 0 )) && rc=1; }
      fi
      return "$rc" ;;

    remove)
      shift
      if (( $# < 2 )); then
        printf 'sbxskill: usage: sbxskill remove SANDBOX SKILL [...] | --all\n' >&2
        return 2
      fi
      sandbox=$1; shift
      _sbx_sandbox_exists "$sandbox" || {
        printf 'sbxskill: sandbox not found: %s\n' "$sandbox" >&2
        return 1
      }
      _sbx_skill_state_require "$sandbox" || return
      file=$(_sbx_skill_state_file "$sandbox") || return
      if [[ ${1:-} == --all ]]; then
        if (( $# != 1 )); then
          printf 'sbxskill: --all cannot be combined with skill names\n' >&2
          return 2
        fi
        skills=()
        while IFS= read -r skill; do [[ -n $skill ]] && skills+=("$skill"); done < "$file"
      else
        skills=("$@")
      fi
      (( ${#skills[@]} )) || { printf 'sbxskill: no managed skills to remove\n' >&2; return 0; }

      sandbox_status=$(_sbx_sandbox_field "$sandbox" 3) || return
      agent=$(_sbx_sandbox_field "$sandbox" 2) || return
      skill_target=$(_sbx_skill_target "$agent") || return
      case $sandbox_status in
        running) ;;
        stopped)
          printf 'sbxskill: temporarily starting %s without launching the agent\n' "$sandbox" >&2
          sbx exec "$sandbox" true >/dev/null || return
          started=1 ;;
        *) printf 'sbxskill: sandbox is not in a usable state: %s (%s)\n' "$sandbox" "${sandbox_status:-unknown}" >&2; return 1 ;;
      esac

      for skill in "${skills[@]}"; do
        if ! _sbx_skill_state_has "$sandbox" "$skill"; then
          printf 'sbxskill: not managed for this sandbox: %s\n' "$skill" >&2
          continue
        fi
        if [[ ! $skill =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ || $skill == .. ]]; then
          printf 'sbxskill: invalid tracked skill name: %s\n' "$skill" >&2
          rc=2; break
        fi
        printf 'Removing skill %s <- %s\n' "$skill" "$sandbox" >&2
        sbx exec -u agent "$sandbox" sh -c '
          set -e
          target=$1; skill=$2
          test ! -L "$target"
          if [ -L "$target/$skill" ]; then
            echo "sbxskill: refusing to remove shared/symlinked skill: $skill" >&2
            exit 42
          fi
          rm -rf "$target/$skill"
        ' sh "$skill_target" "$skill" || { rc=$?; break; }
        _sbx_skill_state_remove "$sandbox" "$skill" || { rc=$?; break; }
      done
      if (( started )); then
        sbx stop "$sandbox" >/dev/null || { printf 'sbxskill: warning: failed to restore stopped state for %s\n' "$sandbox" >&2; (( rc == 0 )) && rc=1; }
      fi
      return "$rc" ;;

    sync)
      shift
      if (( $# != 1 )); then
        printf 'sbxskill: usage: sbxskill sync SANDBOX\n' >&2
        return 2
      fi
      sandbox=$1
      _sbx_sandbox_exists "$sandbox" || {
        printf 'sbxskill: sandbox not found: %s\n' "$sandbox" >&2
        return 1
      }
      _sbx_skill_state_require "$sandbox" || return
      file=$(_sbx_skill_state_file "$sandbox") || return
      skills=()
      while IFS= read -r skill; do [[ -n $skill ]] && skills+=("$skill"); done < "$file"
      (( ${#skills[@]} )) || { printf 'No skills selected for %s.\n' "$sandbox"; return 0; }

      sandbox_status=$(_sbx_sandbox_field "$sandbox" 3) || return
      agent=$(_sbx_sandbox_field "$sandbox" 2) || return
      skill_target=$(_sbx_skill_target "$agent") || return
      case $sandbox_status in
        running) ;;
        stopped)
          printf 'sbxskill: temporarily starting %s without launching the agent\n' "$sandbox" >&2
          sbx exec "$sandbox" true >/dev/null || return
          started=1 ;;
        *) printf 'sbxskill: sandbox is not in a usable state: %s (%s)\n' "$sandbox" "${sandbox_status:-unknown}" >&2; return 1 ;;
      esac

      for skill in "${skills[@]}"; do
        printf 'Syncing skill %s -> %s\n' "$skill" "$sandbox" >&2
        _sbx_skill_copy_into "$sandbox" "$agent" "$skill_target" "$skill" 1 || { rc=$?; break; }
      done
      if (( started )); then
        sbx stop "$sandbox" >/dev/null || { printf 'sbxskill: warning: failed to restore stopped state for %s\n' "$sandbox" >&2; (( rc == 0 )) && rc=1; }
      fi
      return "$rc" ;;

    copy)
      shift
      if (( $# != 2 )); then
        printf 'sbxskill: usage: sbxskill copy SOURCE TARGET\n' >&2
        return 2
      fi
      source=$1; target=$2
      [[ $source != "$target" ]] || { printf 'sbxskill: source and target are the same sandbox\n' >&2; return 2; }
      _sbx_sandbox_exists "$source" || { printf 'sbxskill: source sandbox not found: %s\n' "$source" >&2; return 1; }
      _sbx_sandbox_exists "$target" || { printf 'sbxskill: target sandbox not found: %s\n' "$target" >&2; return 1; }
      _sbx_skill_state_require "$source" || return
      _sbx_skill_state_require "$target" || return
      file=$(_sbx_skill_state_file "$source") || return
      skills=()
      while IFS= read -r skill; do [[ -n $skill ]] && skills+=("$skill"); done < "$file"
      (( ${#skills[@]} )) || { printf 'sbxskill: no skills selected for %s\n' "$source" >&2; return 0; }
      sbxskill add "$target" "${skills[@]}"
      ;;

    *)
      printf 'sbxskill: unknown command: %s\n' "$command" >&2
      printf 'Run sbxskill --help for usage.\n' >&2
      return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# src/worktree.sh
# ---------------------------------------------------------------------------

# shellcheck shell=bash
# Host Git worktree sandboxes: sbxwt, managed worktree metadata, and the Git
# worktree lookup helpers shared with sbxr.

# _sbx_git_worktrees — print "path<TAB>branch" for every worktree of DIR.
_sbx_git_worktrees() {
  local dir=$1 line wt_path='' branch=''
  git -C "$dir" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case $line in
      'worktree '*) wt_path=${line#worktree }; branch='' ;;
      'branch refs/heads/'*) branch=${line#branch refs/heads/} ;;
      '')
        [[ -n $wt_path ]] && printf '%s\t%s\n' "$wt_path" "${branch:--}"
        wt_path=''; branch='' ;;
    esac
  done
}

# _sbx_git_main_worktree — print the primary worktree path of DIR.
_sbx_git_main_worktree() {
  local line
  line=$(git -C "$1" worktree list --porcelain 2>/dev/null | grep -m1 '^worktree ') || return
  printf '%s\n' "${line#worktree }"
}

# _sbx_git_worktree_for_branch — print the worktree path checked out on BRANCH.
_sbx_git_worktree_for_branch() {
  local dir=$1 wanted=$2 wt_path branch
  while IFS=$'\t' read -r wt_path branch; do
    [[ $branch == "$wanted" ]] && { printf '%s\n' "$wt_path"; return 0; }
  done < <(_sbx_git_worktrees "$dir")
  return 1
}

# _sbx_worktree_state_file — path of the managed-worktree metadata for SANDBOX.
_sbx_worktree_state_file() {
  local sandbox=$1
  if [[ ! $sandbox =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    printf 'sbxwt: invalid sandbox name: %s\n' "$sandbox" >&2
    return 2
  fi
  printf '%s/worktrees/%s.meta\n' "$(_sbx_config_dir)" "$sandbox"
}

# _sbx_worktree_state_write — atomically record worktree metadata.
_sbx_worktree_state_write() {
  local sandbox=$1 repository=$2 worktree=$3 branch=$4 base_branch=$5
  local dir file tmp
  dir="$(_sbx_config_dir)/worktrees"
  file="$dir/$sandbox.meta"
  [[ ! -L $dir && ! -L $file && ( ! -e $file || -f $file ) ]] || {
    printf 'sbxwt: refusing symlink or non-file metadata path: %s\n' "$file" >&2
    return 2
  }
  (umask 077; mkdir -p -- "$dir") || return
  tmp=$(umask 077; mktemp "$dir/.${sandbox}.meta.XXXXXX") || return
  {
    printf 'repository\t%s\n' "$repository"
    printf 'worktree\t%s\n' "$worktree"
    printf 'branch\t%s\n' "$branch"
    printf 'base_branch\t%s\n' "$base_branch"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$file"
}

# _sbx_worktree_state_read — print "repository<TAB>worktree<TAB>branch<TAB>base".
_sbx_worktree_state_read() {
  local sandbox=$1 file
  file=$(_sbx_worktree_state_file "$sandbox") || return
  if [[ -L $file || ! -f $file ]]; then
    printf 'sbxwt: managed worktree metadata not found: %s\n' "$sandbox" >&2
    return 1
  fi
  awk -F '\t' '
    $1 == "repository"  { repository = substr($0, index($0, "\t") + 1) }
    $1 == "worktree"    { worktree = substr($0, index($0, "\t") + 1) }
    $1 == "branch"      { branch = substr($0, index($0, "\t") + 1) }
    $1 == "base_branch" { base = substr($0, index($0, "\t") + 1) }
    END {
      if (!repository || !worktree || !branch || !base) exit 1
      printf "%s\t%s\t%s\t%s\n", repository, worktree, branch, base
    }
  ' "$file"
}

# _sandshell_sbxwt_help — print sbxwt usage.
_sandshell_sbxwt_help() {
  printf '%s\n' \
    'Usage:' \
    '  sbxwt create BRANCH [-a AGENT] [-s SIZE] [--base BRANCH] [--env-file FILE]' \
    '  sbxwt ls' \
    '  sbxwt commit SANDBOX [-m MESSAGE]' \
    '  sbxwt merge SANDBOX [--into BRANCH]' \
    '  sbxwt done SANDBOX' \
    '' \
    'create  Create a host worktree and a sandbox for it.' \
    'ls      Show repository worktrees and associated sandboxes.' \
    'commit  Stage all worktree changes and commit them after confirmation.' \
    'merge   Merge the worktree branch into its recorded base branch.' \
    'done    Remove the sandbox and clean worktree after confirmation; preserve the branch.' \
    '' \
    "Metadata: $(_sbx_config_dir)/worktrees/<sandbox>.meta"
}

# Manage host Git worktrees paired with Docker sandboxes.
sbxwt() {
  local command=${1:-ls}
  local branch='' base_branch='' target_branch='' agent=claude size=micro env_file='' default_env=''
  local repository worktree_root worktree project branch_slug sandbox listing rows row
  local wt_path wt_branch sandbox_name sandbox_agent sandbox_status rest
  local metadata changes commits target_worktree registered=0 merged=0
  local mcp_state skill_state sandbox_meta
  local -a create_args

  case $command in
    -h|--help)
      _sandshell_sbxwt_help
      return 0 ;;
  esac
  # `sbxwt SUBCOMMAND --help` shows help instead of a confusing error.
  if [[ ${2:-} == -h || ${2:-} == --help ]]; then
    case $command in
      create|ls|commit|merge|done)
        _sandshell_sbxwt_help
        return 0 ;;
    esac
  fi

  if ! command -v git >/dev/null 2>&1; then
    printf 'sbxwt: git not found\n' >&2
    return 127
  fi

  case $command in
    create)
      shift
      if (( $# < 1 )); then
        printf 'sbxwt: usage: sbxwt create BRANCH [-a AGENT] [-s SIZE] [--base BRANCH] [--env-file FILE]\n' >&2
        return 2
      fi
      branch=$1; shift
      while (( $# )); do
        case $1 in
          -a|--agent|-s|--size|--base|--env-file)
            if (( $# < 2 )) || [[ -z $2 ]]; then
              printf 'sbxwt: missing value for %s\n' "$1" >&2
              return 2
            fi
            case $1 in
              -a|--agent) agent=$2 ;;
              -s|--size) size=$2 ;;
              --base) base_branch=$2 ;;
              --env-file) env_file=$2 ;;
            esac
            shift 2 ;;
          *) printf 'sbxwt: unknown option: %s\n' "$1" >&2; return 2 ;;
        esac
      done

      git check-ref-format --branch "$branch" >/dev/null 2>&1 || {
        printf 'sbxwt: invalid branch name: %s\n' "$branch" >&2
        return 2
      }
      _sbx_agent_target "$agent" >/dev/null || {
        printf 'sbxwt: unsupported agent: %s\n' "$agent" >&2
        return 2
      }
      case $size in micro|small|medium) ;; *) printf 'sbxwt: invalid size: %s\n' "$size" >&2; return 2 ;; esac
      git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        printf 'sbxwt: current directory is not inside a Git working tree\n' >&2
        return 2
      }

      repository=$(_sbx_git_main_worktree "$PWD") || {
        printf 'sbxwt: could not resolve the main Git worktree\n' >&2
        return 1
      }
      if [[ -z $base_branch ]]; then
        base_branch=$(git -C "$PWD" branch --show-current) || return
        [[ -n $base_branch ]] || {
          printf 'sbxwt: detached HEAD; specify --base BRANCH\n' >&2
          return 2
        }
      fi
      git -C "$repository" show-ref --verify --quiet "refs/heads/$base_branch" || {
        printf 'sbxwt: base must be an existing local branch: %s\n' "$base_branch" >&2
        return 2
      }
      [[ $branch != "$base_branch" ]] || {
        printf 'sbxwt: worktree branch must differ from its base branch\n' >&2
        return 2
      }

      branch_slug=${branch//\//-}
      branch_slug=${branch_slug//[^a-zA-Z0-9.-]/-}
      branch_slug=${branch_slug:0:32}
      project=$(_sbx_project_name "$repository") || return
      worktree_root="${repository}.worktrees"
      worktree="$worktree_root/$branch_slug"
      sandbox="sbx-${project}-${branch_slug}-${agent}-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"

      if [[ -L $worktree_root || -e $worktree ]]; then
        printf 'sbxwt: worktree path already exists or is unsafe: %s\n' "$worktree" >&2
        return 2
      fi
      if [[ -n $env_file && ( ! -f $env_file || ! -r $env_file ) ]]; then
        printf 'sbxwt: env file not readable: %s\n' "$env_file" >&2
        return 2
      fi

      mkdir -p -- "$worktree_root" || return
      if git -C "$repository" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$repository" worktree add "$worktree" "$branch" || return
      else
        git -C "$repository" worktree add -b "$branch" "$worktree" "$base_branch" || return
      fi

      create_args=(-a "$agent" -s "$size" -d "$worktree" -n "$sandbox")
      if [[ -n $env_file ]]; then
        create_args+=(--env-file "$env_file")
      else
        default_env="$(_sbx_config_dir)/envs/$project.env"
        [[ -r $default_env ]] && create_args+=(--env-file "$default_env")
      fi

      # sbxc prints a resume hint of its own; the worktree summary below ends
      # with the same hint, so suppress the duplicate for this call only.
      if ! ( _sandshell_skip_resume_hint=1; sbxc "${create_args[@]}" ); then
        printf 'sbxwt: sandbox creation failed; worktree was left intact at %s\n' "$worktree" >&2
        return 1
      fi
      if ! _sbx_worktree_state_write "$sandbox" "$repository" "$worktree" "$branch" "$base_branch"; then
        printf 'sbxwt: warning: sandbox and worktree exist, but metadata could not be saved\n' >&2
        return 1
      fi
      printf 'Worktree: %s\nBranch:   %s\nSandbox:  %s\n' "$worktree" "$branch" "$sandbox"
      printf 'Resume with: sbxr %s\n' "$sandbox" >&2
      ;;

    ls)
      shift
      (( $# == 0 )) || { printf 'sbxwt: usage: sbxwt ls\n' >&2; return 2; }
      git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        printf 'sbxwt: current directory is not inside a Git working tree\n' >&2
        return 2
      }
      listing=$(sbx ls) || return
      printf 'BRANCH\tWORKTREE\tSANDBOX\tSTATE\n'
      while IFS=$'\t' read -r wt_path wt_branch; do
        rows=$(_sbx_workspace_rows "$wt_path" "$listing") || return
        if [[ -z $rows ]]; then
          printf '%s\t%s\t-\t-\n' "$wt_branch" "$wt_path"
          continue
        fi
        while IFS= read -r row; do
          # sandbox_agent is intentionally ignored; only name and status are shown.
          # shellcheck disable=SC2034
          IFS=$' \t' read -r sandbox_name sandbox_agent sandbox_status rest <<< "$row"
          printf '%s\t%s\t%s\t%s\n' "$wt_branch" "$wt_path" "$sandbox_name" "$sandbox_status"
        done <<< "$rows"
      done < <(_sbx_git_worktrees "$PWD")
      ;;

    commit)
      shift
      if (( $# < 1 || $# > 3 )); then
        printf 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]\n' >&2
        return 2
      fi
      sandbox=$1; shift
      local message=''
      if (( $# )); then
        [[ $1 == -m && $# == 2 && -n $2 ]] || { printf 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]\n' >&2; return 2; }
        message=$2
      fi
      metadata=$(_sbx_worktree_state_read "$sandbox") || return
      IFS=$'\t' read -r repository worktree branch base_branch <<< "$metadata"
      [[ -d $worktree ]] || { printf 'sbxwt: worktree directory missing: %s\n' "$worktree" >&2; return 1; }
      [[ $(git -C "$worktree" branch --show-current) == "$branch" ]] || {
        printf 'sbxwt: worktree is no longer on expected branch: %s\n' "$branch" >&2
        return 1
      }
      if [[ -n $(git -C "$worktree" diff --name-only --diff-filter=U) ]]; then
        printf 'sbxwt: resolve merge conflicts before committing\n' >&2
        return 1
      fi
      changes=$(git -C "$worktree" status --short) || return
      if [[ -z $changes ]]; then
        printf 'sbxwt: no changes to commit in %s\n' "$branch"
        return 0
      fi
      printf '%s\n' "$changes"
      _sbx_confirm sbxwt "Stage all changes and commit on $branch?" || { printf 'sbxwt: cancelled\n' >&2; return 1; }
      git -C "$worktree" add -A || return
      if [[ -n $message ]]; then
        git -C "$worktree" commit -m "$message"
      else
        git -C "$worktree" commit
      fi
      ;;

    merge)
      shift
      if (( $# < 1 || $# > 3 )); then
        printf 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]\n' >&2
        return 2
      fi
      sandbox=$1; shift
      if (( $# )); then
        [[ $1 == --into && $# == 2 && -n $2 ]] || { printf 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]\n' >&2; return 2; }
        target_branch=$2
      fi
      metadata=$(_sbx_worktree_state_read "$sandbox") || return
      IFS=$'\t' read -r repository worktree branch base_branch <<< "$metadata"
      [[ -n $target_branch ]] || target_branch=$base_branch
      [[ $target_branch != "$branch" ]] || { printf 'sbxwt: source and target branches are the same\n' >&2; return 2; }
      git -C "$repository" show-ref --verify --quiet "refs/heads/$target_branch" || {
        printf 'sbxwt: target branch does not exist locally: %s\n' "$target_branch" >&2
        return 1
      }
      target_worktree=$(_sbx_git_worktree_for_branch "$repository" "$target_branch") || {
        printf 'sbxwt: target branch must be checked out in a worktree: %s\n' "$target_branch" >&2
        return 1
      }
      [[ -z $(git -C "$worktree" status --porcelain) ]] || {
        printf 'sbxwt: source worktree has uncommitted changes; commit them first\n' >&2
        return 1
      }
      [[ -z $(git -C "$target_worktree" status --porcelain) ]] || {
        printf 'sbxwt: target worktree has uncommitted changes: %s\n' "$target_worktree" >&2
        return 1
      }
      if git -C "$repository" merge-base --is-ancestor "$branch" "$target_branch"; then
        printf 'sbxwt: %s is already merged into %s\n' "$branch" "$target_branch"
        return 0
      fi
      commits=$(git -C "$repository" log --oneline "$target_branch..$branch") || return
      printf 'Merge %s -> %s\n' "$branch" "$target_branch"
      [[ -n $commits ]] && printf '%s\n' "$commits"
      _sbx_confirm sbxwt "Merge $branch into $target_branch?" || { printf 'sbxwt: cancelled\n' >&2; return 1; }
      git -C "$target_worktree" merge "$branch"
      ;;

    done)
      shift
      (( $# == 1 )) || { printf 'sbxwt: usage: sbxwt done SANDBOX\n' >&2; return 2; }
      sandbox=$1
      metadata=$(_sbx_worktree_state_read "$sandbox") || return
      IFS=$'\t' read -r repository worktree branch base_branch <<< "$metadata"
      registered=0
      while IFS=$'\t' read -r wt_path wt_branch; do
        [[ $wt_path == "$worktree" ]] && { registered=1; break; }
      done < <(_sbx_git_worktrees "$repository")

      if (( registered )); then
        [[ -z $(git -C "$worktree" status --porcelain) ]] || {
          printf 'sbxwt: worktree has uncommitted or untracked changes; commit or remove them first\n' >&2
          git -C "$worktree" status --short >&2
          return 1
        }
      elif [[ -e $worktree ]]; then
        printf 'sbxwt: path exists but is no longer a registered worktree; refusing to remove it: %s\n' "$worktree" >&2
        return 1
      fi

      if git -C "$repository" show-ref --verify --quiet "refs/heads/$base_branch" && \
         git -C "$repository" merge-base --is-ancestor "$branch" "$base_branch" 2>/dev/null; then
        merged=1
      fi
      printf 'Sandbox:  %s\nWorktree: %s\nBranch:   %s (preserved)\nBase:     %s\n' \
        "$sandbox" "$worktree" "$branch" "$base_branch"
      (( merged )) || printf 'Warning: %s is not merged into %s; the branch will still be preserved.\n' "$branch" "$base_branch" >&2
      _sbx_confirm sbxwt 'Remove this sandbox and host worktree?' || { printf 'sbxwt: cancelled\n' >&2; return 1; }

      if _sbx_sandbox_exists "$sandbox"; then
        sbx rm --force "$sandbox" || return
      fi
      if (( registered )); then
        git -C "$repository" worktree remove "$worktree" || return
      fi

      mcp_state="$(_sbx_config_dir)/mcp/$sandbox.servers"
      skill_state="$(_sbx_config_dir)/skills/$sandbox.skills"
      sandbox_meta=$(_sbx_sandbox_meta_file "$sandbox") || return
      metadata=$(_sbx_worktree_state_file "$sandbox") || return
      rm -f -- "$metadata" "$mcp_state" "$skill_state" "$sandbox_meta" || return
      printf 'Removed sandbox and worktree. Branch preserved: %s\n' "$branch"
      ;;

    *)
      printf 'sbxwt: unknown command: %s\n' "$command" >&2
      printf 'Run sbxwt --help for usage.\n' >&2
      return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# src/commands.sh
# ---------------------------------------------------------------------------

# shellcheck shell=bash
# Top-level UX helpers that do not deserve their own domain.

# Show the available Docker Sandbox helper commands.
sbxcmd() {
  case ${1:-} in
    '')
      printf '%s\n' \
        'Docker Sandbox helpers:' \
        '  sbxc      Create and configure a new sandbox' \
        '  sbxr      List or resume existing sandboxes' \
        '  sbxenv    Edit the current project environment file' \
        '  sbxmcp    List, attach, or copy MCP servers per sandbox' \
        '  sbxskill  Manage isolated skills per sandbox' \
        '  sbxwt     Create and manage host Git worktree sandboxes' \
        '  sbxcmd    Show this command summary' \
        '' \
        'Use <command> --help for detailed usage.'
      ;;
    -h|--help)
      printf '%s\n' \
        'Usage: sbxcmd' \
        'List the sandshell helper commands.'
      ;;
    *)
      printf 'sbxcmd: unexpected argument: %s\n' "$1" >&2
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# embedded Vibe preset (generated from examples/vibe.toml)
# ---------------------------------------------------------------------------

# _sbx_vibe_default_config — print the bundled sandshell Vibe preset, the
# built-in fallback synchronized into Vibe sandboxes when the user has no
# <config-root>/agents/vibe.toml. Generated from examples/vibe.toml by
# scripts/build.sh; do not edit by hand.
_sbx_vibe_default_config() {
  cat <<'SANDSHELL_VIBE_PRESET'
# sandshell's bundled Vibe preset.
#
# This file is the canonical source of the Vibe configuration sandshell
# synchronizes into Vibe sandboxes when you have no custom configuration at
# <config-root>/agents/vibe.toml (by default ~/.config/sandshell/agents/vibe.toml).
# The build embeds it into sandshell.sh, so the runtime works without this file.
#
# To customize Vibe, copy this file to <config-root>/agents/vibe.toml and edit
# the copy; your file then takes priority over the bundled preset.

# Default model: Mistral Large 4.
# active_model = "mistral-large-4"
allowed_models = ["mistral-large-*", "mistral-small-*", "zai-glm-5-*"]

[compaction_model]
name = "mistral-large-4"
provider = "mistral"

[tools.web_search]
permission = "ask"
timeout = 120
model = "mistral-small-latest"

[[models]]
name = "mistral-small-latest"
provider = "mistral"
alias = "mistral-small-4"
display_name = "Mistral Small 4"
supports_images = true
temperature = 0.6
thinking = "off"
thinking_levels = ["off", "high"]
max_context_length = 256000
auto_compact_threshold = 200000
input_price = 0.15
cached_input_price = 0.015
output_price = 0.60

[[models]]
name = "mistral-large-4"
provider = "mistral"
alias = "mistral-large-4"
display_name = "Mistral Large 4"
temperature = 0.2
input_price = 0.68
output_price = 2.09
cached_input_price = 0.07
thinking = "medium"
supports_images = true
max_context_length = 1000000
auto_compact_threshold = 500000

[[models]]
name = "zai-glm-5-3"
provider = "mistral"
alias = "zai-glm-5-3"
display_name = "Z.ai GLM 5.3"
temperature = 1.0
input_price = 1.4
output_price = 4.4
cached_input_price = 0.14
thinking = "high"
thinking_levels = ["low", "high", "max"]
supports_images = false
max_context_length = 1000000
auto_compact_threshold = 500000
SANDSHELL_VIBE_PRESET
}
