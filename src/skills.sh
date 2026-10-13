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
