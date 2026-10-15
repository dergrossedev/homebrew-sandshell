# shellcheck shell=bash
# Noninteractive agent CLI updates. No installer fallback or image recreation.

# Read the native {"rules": [...]} response, using only direct rule fields.
# Tokenize strings before delimiters so braces/escaped quotes in names cannot
# mix rules or scopes. Unknown/malformed representations fail before any grant.
# Print HOST or conflict:HOST for the requested exact HTTPS destinations.
_sandshell_update_policy_resources() { # SANDBOX JSON HOSTS (space-separated)
  awk -v sandbox="sandbox:$1" -v resources="$3" '
    BEGIN { split(resources, hosts, " ") }
    { json = json $0 "\n" }
    END {
      while (length(json)) {
        if (match(json, /^[[:space:]]+/)) { json = substr(json, RLENGTH + 1); continue }
        if (!match(json, /^("([^"\\]|\\.)*"|[][{}:,]|true|false|null|-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?)/)) exit 2
        token = substr(json, 1, RLENGTH); json = substr(json, RLENGTH + 1)
        if (token == "{" || token == "[") {
          depth++; kind[depth] = token; value[depth] = 0
          if (depth == 1 && token != "{") exit 2
          if (depth == 2 && key[1] == "rules" && token == "[") rules = 1
          if (depth == 3 && key[1] == "rules" && token == "{") {
            scope = layer = type = decision = ""; tcp = 0
            for (host in matched) delete matched[host]
          }
        } else if (token == "}" || token == "]") {
          if (depth < 1 || (token == "}" && kind[depth] != "{") || (token == "]" && kind[depth] != "[")) exit 2
          if (depth == 3 && key[1] == "rules" && token == "}") {
            if (scope == "" || layer == "" || type == "" || decision == "") exit 2
            if (scope == sandbox && layer == "local" && type == "network") {
              equivalent = (decision == "allow" && tcp)
              for (host in matched) { if (equivalent) allow[host] = 1; else conflict[host] = 1 }
            }
          }
          depth--
        } else if (token == ":") {
          value[depth] = 1
        } else if (token == ",") {
          value[depth] = 0
        } else if (substr(token, 1, 1) == "\"") {
          item = substr(token, 2, length(token) - 2)
          if (kind[depth] == "{" && !value[depth]) { key[depth] = item; continue }
          if (key[1] != "rules") continue
          if (depth == 3) {
            if (key[depth] ~ /^(scope|layer|resource_type|decision)$/ && index(item, "\\")) exit 2
            if (key[depth] == "scope") scope = item
            if (key[depth] == "layer") layer = item
            if (key[depth] == "resource_type") type = item
            if (key[depth] == "decision") decision = item
          } else if (depth == 4 && kind[depth] == "[") {
            if (key[3] == "actions" && item == "net:connect:tcp") tcp = 1
            if (key[3] == "resources") {
              if (index(item, "\\")) exit 2
              item = tolower(item)
              for (i in hosts) if (item == hosts[i] || item == hosts[i] ":443") matched[hosts[i]] = 1
            }
          }
        }
      }
      if (depth != 0 || !rules) exit 2
      for (host in allow) print host
      for (host in conflict) if (!allow[host]) print "conflict:" host
    }
  ' <<< "$2"
}

# Runs from the scoped EXIT trap; attempt every cleanup even after a failure.
_sandshell_update_cleanup() { # RC SANDBOX RESTORE RESOURCE...
  local rc=$1 sandbox=$2 restore=$3 resource
  shift 3
  trap '' HUP INT TERM
  for resource in "$@"; do
    sbx policy rm network --sandbox "$sandbox" --resource "$resource" --force >/dev/null || {
      printf 'sbxupdate: failed to remove temporary rule for %s in %s\n' "$resource" "$sandbox" >&2
      (( rc == 0 )) && rc=1
    }
  done
  if (( restore )); then
    _sandshell_sandbox_restore sbxupdate "$sandbox" || { (( rc == 0 )) && rc=1; }
  fi
  exit "$rc"
}

_sandshell_update_run() ( # SANDBOX AGENT STATUS
  # Return from this function subshell: Bash 3.2 unwinds function locals before
  # an explicit exit runs its EXIT trap, losing the cleanup state.
  local sandbox=$1 agent=$2 sandbox_status=$3 restore=0 interrupted=0
  local before after rc=0 listing policies resource existing line
  local -a owned=() updater=() resources=()
  case $agent in
    vibe)
      updater=(uv tool install --force mistral-vibe@latest --with 'httpx[socks]')
      resources=(pypi.org files.pythonhosted.org) ;;
    opencode|opencode-ollama) updater=(opencode upgrade --method npm); agent=opencode ;;
    claude-ollama) updater=(claude update); agent=claude; resources=(downloads.claude.ai) ;;
    claude|codex) updater=("$agent" update) ;;
  esac

  # Bash 3.2 nounset treats an empty array as unset; pass no resource arguments.
  trap '_sandshell_update_cleanup "$?" "$sandbox" "$restore" ${owned[@]+"${owned[@]}"}' EXIT
  # Defer exiting until the current sbx call returns, so a successful grant is
  # recorded before cleanup. These traps/options live only in this subshell.
  trap 'interrupted=129' HUP
  trap 'interrupted=130' INT
  trap 'interrupted=143' TERM

  [[ $sandbox_status == stopped ]] && restore=1
  _sandshell_sandbox_start sbxupdate "$sandbox" "$sandbox_status" -u agent -w /tmp || return "$?"
  (( interrupted == 0 )) || return "$interrupted"

  printf 'Updating %s in %s\n' "$agent" "$sandbox"
  before=$(sbx exec -u agent -w /tmp "$sandbox" "$agent" --version 2>&1) || before=unavailable
  printf 'Before: %s\n' "$before"
  (( interrupted == 0 )) || return "$interrupted"

  if [[ -n ${resources[*]:-} ]]; then
    listing=$(sbx policy ls "$sandbox" --json --include-inactive) || {
      rc=$?
      printf 'sbxupdate: policy listing failed for %s\n' "$sandbox" >&2
      return "$rc"
    }
    policies=$(_sandshell_update_policy_resources "$sandbox" "$listing" "${resources[*]}") || {
      printf 'sbxupdate: cannot read network policy rules for %s\n' "$sandbox" >&2
      return 1
    }
    (( interrupted == 0 )) || return "$interrupted"
    for resource in "${resources[@]}"; do
      existing=0
      while IFS= read -r line; do
        case $line in
          "$resource") existing=1 ;;
          "conflict:$resource")
            printf 'sbxupdate: conflicting local rule for %s; refusing temporary grant\n' "$resource" >&2
            return 1 ;;
        esac
      done <<< "$policies"
      (( existing == 0 )) || continue
      resource=$resource:443
      sbx policy allow network --sandbox "$sandbox" "$resource" >/dev/null || {
        printf 'sbxupdate: failed to allow %s in %s\n' "$resource" "$sandbox" >&2
        return 1
      }
      owned+=("$resource")
      (( interrupted == 0 )) || return "$interrupted"
    done
  fi

  sbx exec -u agent -w /tmp "$sandbox" "${updater[@]}" || {
    rc=$?
    printf 'sbxupdate: updater failed for %s (exit %s)\n' "$sandbox" "$rc" >&2
  }
  (( interrupted == 0 )) || return "$interrupted"
  after=$(sbx exec -u agent -w /tmp "$sandbox" "$agent" --version 2>&1) || after=unavailable
  printf 'After:  %s\n' "$after"
  (( interrupted == 0 )) || return "$interrupted"
  return "$rc"
)

sbxupdate() {
  local sandbox='' listing matches line agent agent_family sandbox_status count=0 rc
  case $# in
    0) ;;
    1)
      case $1 in
        -h|--help)
          printf '%s\n' \
            'Usage: sbxupdate [SANDBOX]' \
            'Update the installed agent CLI in an existing sandbox.' \
            'Without SANDBOX, use the only sandbox matching the current physical workspace.' \
            'Supports: vibe, opencode, opencode-ollama, claude, claude-ollama, codex.' \
            '  -h, --help  Show help'
          return 0 ;;
        -*) printf 'sbxupdate: unknown option: %s\n' "$1" >&2; return 2 ;;
        '') printf 'sbxupdate: empty sandbox name\n' >&2; return 2 ;;
        *) sandbox=$1 ;;
      esac ;;
    *) printf 'sbxupdate: expected at most one SANDBOX; use sbxupdate --help\n' >&2; return 2 ;;
  esac
  if ! command -v sbx >/dev/null 2>&1; then
    printf 'sbxupdate: sbx CLI not found\n' >&2
    return 127
  fi
  listing=$(sbx ls) || {
    rc=$?
    printf 'sbxupdate: sandbox listing failed\n' >&2
    return "$rc"
  }
  if [[ -z $sandbox ]]; then
    matches=$(_sbx_workspace_rows "$PWD" "$listing") || return
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      count=$(( count + 1 ))
      sandbox=${line%%[[:space:]]*}
    done <<< "$matches"
    case $count in
      0) printf 'sbxupdate: no sandbox for the current workspace; specify SANDBOX\n' >&2; return 2 ;;
      1) ;;
      *) printf 'sbxupdate: multiple sandboxes for the current workspace; specify SANDBOX:\n%s\n' "$matches" >&2; return 2 ;;
    esac
  fi
  agent=$(_sbx_sandbox_field "$sandbox" 2 "$listing") || return
  if [[ -z $agent ]]; then
    printf 'sbxupdate: sandbox not found: %s\n' "$sandbox" >&2
    return 1
  fi
  # Exact known listing identities; never infer the agent from the sandbox name.
  # Keep the raw identifier for diagnostics; dispatch using its agent family.
  case $agent in
    vibe|sbx-kit-vibe|docker.io/docker/sbx-kit-vibe:latest) agent_family=vibe ;;
    opencode|opencode-ollama|claude|claude-ollama|codex) agent_family=$agent ;;
    *)
      printf 'sbxupdate: unsupported update for agent %s in %s\n' "$agent" "$sandbox" >&2
      return 1 ;;
  esac
  sandbox_status=$(_sandshell_sandbox_status "$sandbox") || return
  _sandshell_update_run "$sandbox" "$agent_family" "$sandbox_status" </dev/null || return
  printf 'Note: restart/resume any already-running agent session to use the installed CLI.\n'
}
