#!/usr/bin/env bash
# Release preparation automation for sandshell.
#
# Usage:
#   scripts/release.sh VERSION
#
# Prepares and verifies a release locally, including the package and committed
# Homebrew formula, but stops before any public action.
#
# Stages:
#   1. Input validation (version format, arguments)
#   2. Preconditions (clean tree, required files, no existing tag)
#   3. Changelog check (must contain release entry for VERSION)
#   4. Quality gate (check.sh)
#   5. Build package (package.sh VERSION)
#   6. Generate Homebrew formula (homebrew-formula.sh)
#   7. Verify generated formula
#   8. Print summary
#
# Exits non-zero on any failure before side effects.
# Does not tag, push, publish, or modify GitHub/Homebrew state.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# --- Usage and argument validation -------------------------------------------

usage() {
  printf 'usage: scripts/release.sh VERSION\n'
  printf '  VERSION  calendar version YYYY.M.PATCH, e.g. 2026.10.0\n'
}

if [ $# -ne 1 ]; then
  usage >&2
  exit 2
fi

version=$1

# Reject leading 'v' prefix
if [[ $version == v* ]]; then
  printf 'release.sh: version must not start with "v": %s\n' "$version" >&2
  usage >&2
  exit 2
fi

# Validate calendar syntax without consulting the current date.
version_re='^[0-9]{4}\.(1[0-2]|[1-9])\.(0|[1-9][0-9]*)$'
if ! [[ $version =~ $version_re ]]; then
  printf 'release.sh: invalid version: %s (expected YYYY.M.PATCH)\n' "$version" >&2
  usage >&2
  exit 2
fi

# --- Preconditions -----------------------------------------------------------

# Require clean Git working tree
git_status=$(git status --porcelain 2>/dev/null || echo "")
if [ -n "$git_status" ]; then
  printf 'release.sh: working tree is dirty; commit or stash changes first\n' >&2
  exit 1
fi

# Require expected release files/scripts
expected_files=(
  "scripts/package.sh"
  "scripts/homebrew-formula.sh"
  "scripts/check.sh"
  "scripts/build.sh"
)

for file in "${expected_files[@]}"; do
  if [ ! -f "$root/$file" ]; then
    printf 'release.sh: missing required file: %s\n' "$file" >&2
    exit 1
  fi

done

# Require that tag vVERSION does not already exist locally
tag_exists=$(git tag -l "v$version" 2>/dev/null || echo "")
if [ -n "$tag_exists" ]; then
  printf 'release.sh: tag v%s already exists locally\n' "$version" >&2
  exit 1
fi

# --- Changelog check --------------------------------------------------------

changelog="$root/CHANGELOG.md"
if [ ! -f "$changelog" ]; then
  printf 'release.sh: missing CHANGELOG.md\n' >&2
  exit 1
fi

# Check for release entry with actual date (not "Unreleased")
# Format: ## [VERSION] - DATE
# We look for the version in brackets followed by a date with dashes
if ! grep -q "^## \\[${version}\\] - " "$changelog"; then
  printf 'release.sh: CHANGELOG.md must contain a release entry for version %s with a real release date\n' "$version" >&2
  printf 'release.sh: Expected format: ## [%s] - YYYY.MM.DD\n' "$version" >&2
  exit 1
fi

# --- Quality gate ------------------------------------------------------------
# Run the full quality gate once

printf '==> Running quality gate: ./scripts/check.sh\n'
./scripts/check.sh || {
  printf 'release.sh: quality gate failed\n' >&2
  exit 1
}

# --- Build package ----------------------------------------------------------

printf '==> Building package: ./scripts/package.sh %s\n' "$version"
./scripts/package.sh "$version" || {
  printf 'release.sh: package.sh failed\n' >&2
  exit 1
}

# Verify outputs exist
dist_dir="$root/dist"
archive="$dist_dir/sandshell-$version.tar.gz"
checksum="$dist_dir/sandshell-$version.tar.gz.sha256"

if [ ! -f "$archive" ]; then
  printf 'release.sh: package.sh did not produce expected archive: %s\n' "$archive" >&2
  exit 1
fi

if [ ! -f "$checksum" ]; then
  printf 'release.sh: package.sh did not produce expected checksum: %s\n' "$checksum" >&2
  exit 1
fi

# Verify checksum from inside dist/ (checksum file contains archive basename)
printf '==> Verifying checksum\n'
(
  cd "$dist_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "sandshell-$version.tar.gz.sha256"
  else
    shasum -a 256 -c "sandshell-$version.tar.gz.sha256"
  fi
) || {
  printf 'release.sh: checksum verification failed\n' >&2
  exit 1
}

# Extract SHA256 from checksum file (format: "HASH  sandshell-VERSION.tar.gz")
package_sha=$(awk '{print $1}' "$checksum")
if [ -z "$package_sha" ]; then
  printf 'release.sh: could not extract SHA256 from checksum file\n' >&2
  exit 1
fi

# --- Generate Homebrew formula ----------------------------------------------

formula_file="$root/Formula/sandshell.rb"
formula_dir=$(dirname "$formula_file")

if [ ! -d "$formula_dir" ]; then
  printf 'release.sh: missing Formula directory: %s\n' "$formula_dir" >&2
  exit 1
fi

printf '==> Generating Homebrew formula: %s\n' "$formula_file"

# Generate formula using existing homebrew-formula.sh
"$root/scripts/homebrew-formula.sh" \
  --owner dergrossedev \
  --version "$version" \
  --sha256 "$package_sha" \
  > "$formula_file" || {
  printf 'release.sh: homebrew-formula.sh failed\n' >&2
  rm -f "$formula_file"
  exit 1
}

# --- Verify generated formula -----------------------------------------------

if [ ! -f "$formula_file" ]; then
  printf 'release.sh: homebrew-formula.sh did not produce expected file: %s\n' "$formula_file" >&2
  exit 1
fi

# Verify the formula references the correct versioned archive
formula_content=$(cat "$formula_file")
if ! grep -q "url \"https://github.com/dergrossedev/homebrew-sandshell/releases/download/v${version}/sandshell-${version}.tar.gz\"" <<< "$formula_content"; then
  printf 'release.sh: generated formula has incorrect URL\n' >&2
  rm -f "$formula_file"
  exit 1
fi

# Verify the formula contains the exact package SHA
if ! grep -q "sha256 \"${package_sha}\"" <<< "$formula_content"; then
  printf 'release.sh: generated formula has incorrect SHA256\n' >&2
  rm -f "$formula_file"
  exit 1
fi

# Verify formula does NOT contain explicit Ruby version declaration
if grep -q '^[[:space:]]*version ' "$formula_file"; then
  printf 'release.sh: generated formula contains explicit Ruby version declaration\n' >&2
  rm -f "$formula_file"
  exit 1
fi

# --- Run focused formula consistency test -----------------------------------

printf '==> Running focused formula consistency test\n'
./tests/test_homebrew_formula_generated.sh || {
  printf 'release.sh: formula consistency test failed\n' >&2
  rm -f "$formula_file"
  exit 1
}

# --- Final summary ----------------------------------------------------------

printf 'Prepared v%s\n\n' "$version"
printf 'Package: %s\n' "$archive"
printf 'SHA256:  %s\n' "$package_sha"
printf 'Formula: %s\n\n' "$formula_file"
printf 'Next:\n'
printf '  review git diff\n'
printf '  commit release preparation\n'
printf '  push and wait for CI\n'
printf '  publish v%s\n' "$version"
