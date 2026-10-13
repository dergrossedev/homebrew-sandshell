#!/usr/bin/env bash
# Build the public sandshell.sh artifact from the source modules in src/.
#
# Usage:
#   scripts/build.sh          Regenerate sandshell.sh (atomic write).
#   scripts/build.sh --check  Verify the committed artifact is current;
#                             never modifies it. Exits non-zero when stale.
#
# The build is deterministic: identical source modules always produce
# byte-identical output. No timestamps, absolute paths, or machine-specific
# data are embedded. The build also embeds examples/vibe.toml (the canonical
# bundled Vibe preset) into the artifact, so the standalone runtime never
# depends on repository files. Written in the POSIX shell subset so it also
# runs under Zsh and plain sh.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
src_dir="$root/src"
artifact="$root/sandshell.sh"

mode=build
case ${1:-} in
  '') ;;
  --check) mode=check ;;
  -h|--help)
    printf 'usage: scripts/build.sh [--check]\n'
    exit 0
    ;;
  *)
    printf 'build.sh: unknown argument: %s\n' "$1" >&2
    printf 'usage: scripts/build.sh [--check]\n' >&2
    exit 2
    ;;
esac

# Explicit module order. The artifact is a single sourced file, so this order
# is for readability; dependencies flow top-down.
set -- core.sh sandbox.sh mcp.sh skills.sh worktree.sh commands.sh

# Fail fast on missing source modules.
for module in "$@"; do
  if [ ! -f "$src_dir/$module" ]; then
    printf 'build.sh: missing source module: src/%s\n' "$module" >&2
    exit 1
  fi
done

# The bundled Vibe preset is a build input: examples/vibe.toml is the
# canonical source, embedded into the artifact so the standalone runtime never
# depends on repository files.
preset="$root/examples/vibe.toml"
if [ ! -f "$preset" ]; then
  printf 'build.sh: missing Vibe preset: examples/vibe.toml\n' >&2
  exit 1
fi

generate() {
  printf '%s\n' \
    '# sandshell.sh is a generated file. Do not edit it directly.' \
    '# Source of truth: src/. Regenerate with: ./scripts/build.sh'
  for module in "$@"; do
    printf '\n# ---------------------------------------------------------------------------\n# src/%s\n# ---------------------------------------------------------------------------\n\n' "$module"
    cat "$src_dir/$module"
  done
  printf '\n# ---------------------------------------------------------------------------\n# embedded Vibe preset (generated from examples/vibe.toml)\n# ---------------------------------------------------------------------------\n\n'
  printf '%s\n' \
    '# _sbx_vibe_default_config — print the bundled sandshell Vibe preset, the' \
    '# built-in fallback synchronized into Vibe sandboxes when the user has no' \
    '# <config-root>/agents/vibe.toml. Generated from examples/vibe.toml by' \
    '# scripts/build.sh; do not edit by hand.'
  printf '_sbx_vibe_default_config() {\n'
  printf "  cat <<'SANDSHELL_VIBE_PRESET'\n"
  # Normalize the trailing newline so the here-document delimiter always
  # starts on its own line.
  printf '%s\n' "$(cat "$preset")"
  printf 'SANDSHELL_VIBE_PRESET\n'
  printf '}\n'
}

if [ "$mode" = check ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/sandshell-build.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  generate "$@" >"$tmp"
  if cmp -s "$tmp" "$artifact"; then
    printf 'build.sh: sandshell.sh is up to date\n'
  else
    printf 'build.sh: sandshell.sh is stale; run ./scripts/build.sh to regenerate\n' >&2
    exit 1
  fi
else
  # Write next to the artifact so the final rename is atomic.
  tmp=$(mktemp "$root/.sandshell.sh.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  generate "$@" >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$artifact"
  printf 'build.sh: wrote %s\n' "$artifact"
fi
