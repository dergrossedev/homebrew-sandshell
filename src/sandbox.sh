# shellcheck shell=bash
# Sandbox lifecycle and environment: sbxc, sbxr, sbxenv, agent/kit mapping,
# Vibe setup, and the sandbox lookup helpers shared across commands.

# _sbx_workspace_rows — print `sbx ls` rows whose WORKSPACE column matches.
_sbx_workspace_rows() {
  local workspace listing line row_workspace column
  workspace=$(_sandshell_physical_path "$1") || return
  if (( $# == 2 )); then
    listing=$2
  else
    listing=$(sbx ls) || return
  fi
  while IFS= read -r line; do
    # The first three columns are single fields; WORKSPACE is the remainder,
    # including spaces. Keep the original row for display.
    row_workspace=$line
    for (( column=0; column<3; column++ )); do
      row_workspace=${row_workspace#*[[:space:]]}
      row_workspace=${row_workspace#"${row_workspace%%[![:space:]]*}"}
    done
    [[ -n $row_workspace ]] || continue
    [[ $(_sandshell_physical_path "$row_workspace") == "$workspace" ]] && printf '%s\n' "$line"
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
    first=${line%%[[:space:]]*}
    [[ $first == "$name" ]] && return 0
  done < <(_sbx_workspace_rows "$workspace" "$listing")
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
  local agent=opencode workspace="$PWD" size=micro name='' clone=0 model=''
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
          'Agents: claude, codex, opencode (default), vibe, claude-ollama, opencode-ollama' \
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
        if [[ -n $match ]]; then
          [[ -n $rows ]] && rows+=$'\n'
          rows+=$match
        fi
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
            'Editor priority: EDITOR argument, then VISUAL, EDITOR, micro, nano, vim, or vi.' \
            'Creates a missing env file with permissions 600.'
          return 0 ;;
        -*) printf 'sbxenv: unknown option: %s\n' "$1" >&2; return 2 ;;
        *) editor=$1 ;;
      esac ;;
    *) printf 'sbxenv: expected at most one editor argument\n' >&2; return 2 ;;
  esac

  if [[ -z $editor ]]; then
    editor=${VISUAL:-${EDITOR:-}}
    if [[ -z $editor ]]; then
      for selection in micro nano vim vi; do
        if command -v "$selection" >/dev/null 2>&1; then
          editor=$selection
          break
        fi
      done
    fi
  fi
  if [[ -n $editor ]]; then
    if command -v "$editor" >/dev/null 2>&1; then
      editor_args=("$editor")
    elif [[ -n ${ZSH_VERSION:-} ]]; then
      # Zsh-only (z) flag word splitting, guarded by the ZSH_VERSION check.
      # shellcheck disable=SC2296,SC2206
      editor_args=(${(z)editor})
      editor=${editor_args[1]-}
    else
      IFS=$' \t' read -r -a editor_args <<< "$editor"
      editor=${editor_args[0]-}
    fi
  fi
  if [[ -z $editor ]]; then
    printf 'sbxenv: no editor found; set VISUAL or EDITOR, or pass one: sbxenv EDITOR\n' >&2
    return 127
  fi
  if ! command -v "$editor" >/dev/null 2>&1; then
    printf 'sbxenv: editor not found: %s; set VISUAL or EDITOR, or pass one: sbxenv EDITOR\n' "$editor" >&2
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
