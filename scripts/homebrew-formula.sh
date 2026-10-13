#!/usr/bin/env bash
# Generate the Homebrew formula for sandshell from release metadata.
#
# Usage:
#   scripts/homebrew-formula.sh --owner OWNER --version VERSION --sha256 SHA256
#
# Writes the formula to stdout, so it can be redirected into the tap:
#   scripts/homebrew-formula.sh --owner OWNER --version 0.1.0 --sha256 SHA256 \
#     > /tmp/sandshell.rb
#
# The formula is generated from packaging/homebrew/Formula/sandshell.rb.in.
# The GitHub owner, version, and release-archive SHA256 are release metadata;
# they are never hardcoded in this repository. The generated formula belongs
# in the separate homebrew-sandshell tap repository.
#
# No network access and no Homebrew installation are required. Written in
# the POSIX shell subset so it also runs under Zsh and plain sh.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
template="$root/packaging/homebrew/Formula/sandshell.rb.in"

usage() {
  printf 'usage: scripts/homebrew-formula.sh --owner OWNER --version VERSION --sha256 SHA256\n'
}

owner='' version='' sha256=''
while [ $# -gt 0 ]; do
  case $1 in
    --owner)
      if [ $# -lt 2 ]; then
        printf 'homebrew-formula.sh: --owner requires a value\n' >&2
        exit 2
      fi
      owner=$2
      shift 2
      ;;
    --version)
      if [ $# -lt 2 ]; then
        printf 'homebrew-formula.sh: --version requires a value\n' >&2
        exit 2
      fi
      version=$2
      shift 2
      ;;
    --sha256)
      if [ $# -lt 2 ]; then
        printf 'homebrew-formula.sh: --sha256 requires a value\n' >&2
        exit 2
      fi
      sha256=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'homebrew-formula.sh: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$owner" ] || [ -z "$version" ] || [ -z "$sha256" ]; then
  printf 'homebrew-formula.sh: --owner, --version, and --sha256 are all required\n' >&2
  usage >&2
  exit 2
fi

# GitHub owner/org names: alphanumeric characters or single hyphens, at
# most 39 characters, no leading or trailing hyphen.
owner_re='^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$'
if ! [[ $owner =~ $owner_re ]]; then
  printf 'homebrew-formula.sh: invalid GitHub owner: %s\n' "$owner" >&2
  exit 2
fi

version_re='^0\.[0-9]+\.[0-9]+$'
if ! [[ $version =~ $version_re ]]; then
  printf 'homebrew-formula.sh: invalid version: %s (expected a pre-1.0 version like 0.1.0)\n' "$version" >&2
  exit 2
fi

sha256_re='^[0-9a-fA-F]{64}$'
if ! [[ $sha256 =~ $sha256_re ]]; then
  printf 'homebrew-formula.sh: invalid SHA256: %s (expected 64 hexadecimal characters)\n' "$sha256" >&2
  exit 2
fi

if [ ! -f "$template" ]; then
  printf 'homebrew-formula.sh: missing formula template: %s\n' "$template" >&2
  exit 1
fi

# Plain substitution; the validated values contain no sed metacharacters.
formula=$(sed -e "s|@OWNER@|$owner|g" \
               -e "s|@VERSION@|$version|g" \
               -e "s|@SHA256@|$sha256|g" \
               "$template")

if printf '%s\n' "$formula" | grep -q '@[A-Z_][A-Z_]*@'; then
  printf 'homebrew-formula.sh: generated formula still contains a placeholder\n' >&2
  exit 1
fi

printf '%s\n' "$formula"
