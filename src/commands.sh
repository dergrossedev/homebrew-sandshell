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
