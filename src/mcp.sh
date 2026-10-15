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
  _sandshell_sandbox_start sbxmcp "$sandbox" "$sandbox_status" || return
  [[ $sandbox_status == stopped ]] && started=1

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
    _sandshell_sandbox_restore sbxmcp "$sandbox" || {
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
