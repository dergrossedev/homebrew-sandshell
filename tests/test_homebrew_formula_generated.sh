#!/usr/bin/env bash
# Test that the repository contains a valid generated Formula/sandshell.rb
# matching the template inputs.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
formula_path="$root/Formula/sandshell.rb"
template_path="$root/packaging/homebrew/Formula/sandshell.rb.in"

usage() {
  printf 'usage: tests/test_homebrew_formula_generated.sh
'
}

if [ $# -ne 0 ]; then
  usage >&2
  exit 2
fi

# Ensure the generated formula exists
if [ ! -f "$formula_path" ]; then
  printf 'test_homebrew_formula_generated.sh: Formula/sandshell.rb does not exist\n' >&2
  exit 1
fi

# Ensure the template exists (source of truth)
if [ ! -f "$template_path" ]; then
  printf 'test_homebrew_formula_generated.sh: template missing: %s\n' "$template_path" >&2
  exit 1
fi

# Validate the formula is syntactically valid Ruby (basic check)
if command -v ruby >/dev/null 2>&1; then
  if ! ruby -c "$formula_path" >/dev/null 2>&1; then
    printf 'test_homebrew_formula_generated.sh: Formula/sandshell.rb is not valid Ruby\n' >&2
    exit 1
  fi
else
  printf 'test_homebrew_formula_generated.sh: ruby not available; skipping Ruby syntax check\n' >&2
fi

# Ensure placeholders were substituted (no @PLACEHOLDER@ remain)
if grep -q '@[A-Z_][A-Z_]*@' "$formula_path"; then
  printf 'test_homebrew_formula_generated.sh: Formula/sandshell.rb still contains placeholders\n' >&2
  exit 1
fi

# Ensure required fields are present
if ! grep -q 'class Sandshell < Formula' "$formula_path"; then
  printf 'test_homebrew_formula_generated.sh: Formula/sandshell.rb missing Sandshell class\n' >&2
  exit 1
fi

if ! grep -q 'homepage "https://github.com/dergrossedev/homebrew-sandshell"' "$formula_path"; then
  printf 'test_homebrew_formula_generated.sh: Formula/sandshell.rb has incorrect homepage\n' >&2
  exit 1
fi

if ! grep -q 'url "https://github.com/dergrossedev/homebrew-sandshell/releases/download/v0.1.0/sandshell-0.1.0.tar.gz"' "$formula_path"; then
  printf 'test_homebrew_formula_generated.sh: Formula/sandshell.rb has incorrect URL\n' >&2
  exit 1
fi

if ! grep -q 'sha256 "fe6e08f5548e5553be9e94b28b3f051752bc73af3cfc518bbf15d58d544bf03c"' "$formula_path"; then
  printf 'test_homebrew_formula_generated.sh: Formula/sandshell.rb has incorrect SHA256\n' >&2
  exit 1
fi

if ! grep -q 'version "0.1.0"' "$formula_path"; then
  printf 'test_homebrew_formula_generated.sh: Formula/sandshell.rb has incorrect version\n' >&2
  exit 1
fi

printf 'test_homebrew_formula_generated.sh: PASS: Formula/sandshell.rb exists and is valid\n'
