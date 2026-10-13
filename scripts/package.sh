#!/usr/bin/env bash
# Package the public sandshell runtime assets into a release archive.
#
# Usage:
#   scripts/package.sh VERSION
#
# Produces, under dist/:
#   dist/sandshell-VERSION.tar.gz
#   dist/sandshell-VERSION.tar.gz.sha256
#
# The archive contains only public runtime assets under one versioned
# top-level directory:
#   sandshell-VERSION/sandshell.sh
#   sandshell-VERSION/completions/sandshell.bash
#   sandshell-VERSION/completions/_sandshell
#   sandshell-VERSION/examples/vibe.toml
#   sandshell-VERSION/README.md
#   sandshell-VERSION/LICENSE
#
# The generated sandshell.sh must be current: this script runs
# ./scripts/build.sh --check first and refuses to package a stale artifact.
# Run ./scripts/build.sh to regenerate it.
#
# Archives are deterministic on a given platform: fixed member order,
# fixed mtimes (epoch, UTC), fixed modes, normalized ownership, and gzip
# without a timestamp. Byte-identical archives across macOS (BSD tar) and
# Linux (GNU tar) are not guaranteed because the tar container formats
# differ; the archive contents and paths are identical on both platforms.
#
# Written in the POSIX shell subset so it also runs under Zsh and plain sh.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

usage() {
  printf 'usage: scripts/package.sh VERSION\n'
  printf '  VERSION  pre-1.0 semantic version, e.g. 0.1.0\n'
}

if [ $# -ne 1 ]; then
  usage >&2
  exit 2
fi

case $1 in
  -h|--help)
    usage
    exit 0
    ;;
esac

version=$1
version_re='^0\.[0-9]+\.[0-9]+$'
if ! [[ $version =~ $version_re ]]; then
  printf 'package.sh: invalid version: %s (expected a pre-1.0 version like 0.1.0)\n' "$version" >&2
  exit 2
fi

cd "$root"

# Refuse to package a stale generated artifact; the developer must rebuild.
if ! ./scripts/build.sh --check; then
  printf 'package.sh: refusing to package a stale sandshell.sh; run ./scripts/build.sh first\n' >&2
  exit 1
fi

# The release archive carries only public runtime assets.
for asset in sandshell.sh README.md LICENSE completions/sandshell.bash completions/_sandshell examples/vibe.toml; do
  if [ ! -f "$asset" ]; then
    printf 'package.sh: missing release asset: %s\n' "$asset" >&2
    exit 1
  fi
done

top="sandshell-$version"
stage=$(mktemp -d "${TMPDIR:-/tmp}/sandshell-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/$top/completions" "$stage/$top/examples"
cp sandshell.sh README.md LICENSE "$stage/$top/"
cp completions/sandshell.bash completions/_sandshell "$stage/$top/completions/"
cp examples/vibe.toml "$stage/$top/examples/"

# Deterministic metadata: fixed modes and a fixed mtime. TZ=UTC keeps the
# touch -t timestamp independent of the local timezone.
find "$stage" -type f -exec chmod 644 {} +
TZ=UTC find "$stage" -type f -exec touch -t 197001010000.00 {} +

# Normalize ownership so no username or host uid/gid is embedded.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  set -- --owner=0 --group=0 --numeric-owner
else
  # BSD tar (macOS) spells the same normalization differently.
  set -- --uid=0 --gid=0 --uname=root --gname=root
fi

# The member list is fixed and stored in C-locale sorted order, so the
# archive layout never depends on readdir order. Only files are stored
# (tar creates parent directories on extraction), which keeps the member
# set identical on GNU and BSD tar.
tar -cf "$stage/archive.tar" "$@" -C "$stage" \
  "$top/LICENSE" \
  "$top/README.md" \
  "$top/completions/_sandshell" \
  "$top/completions/sandshell.bash" \
  "$top/examples/vibe.toml" \
  "$top/sandshell.sh"
gzip -n "$stage/archive.tar"

dist="$root/dist"
mkdir -p "$dist"
archive="$dist/sandshell-$version.tar.gz"
mv -f "$stage/archive.tar.gz" "$archive"

# sha256sum on Linux, shasum on macOS; both print "<hash>  <name>".
if command -v sha256sum >/dev/null 2>&1; then
  checksum=$(cd "$dist" && sha256sum "sandshell-$version.tar.gz")
else
  checksum=$(cd "$dist" && shasum -a 256 "sandshell-$version.tar.gz")
fi
printf '%s\n' "$checksum" >"$dist/sandshell-$version.tar.gz.sha256"

printf 'package.sh: wrote %s\n' "$archive"
printf 'package.sh: wrote %s\n' "$dist/sandshell-$version.tar.gz.sha256"
printf 'package.sh: sha256 %s\n' "$(printf '%s' "$checksum" | cut -d' ' -f1)"
