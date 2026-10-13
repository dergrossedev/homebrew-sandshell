#!/usr/bin/env bash
# Test that the repository contains a valid generated Formula/sandshell.rb
# matching the template inputs.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
formula_path="$root/Formula/sandshell.rb"
template_path="$root/packaging/homebrew/Formula/sandshell.rb.in"

# Load helpers to set up test environment
_helpers_dir=$(cd "$(dirname "$0")" && pwd)
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

usage() {
  printf 'usage: tests/test_homebrew_formula_generated.sh\n'
}

if [ $# -ne 0 ]; then
  usage >&2
  exit 2
fi

test_formula_generated_exists() {
  if [ ! -f "$formula_path" ]; then
    assert_fail "Formula/sandshell.rb does not exist"
  fi
}

test_formula_template_exists() {
  if [ ! -f "$template_path" ]; then
    assert_fail "template missing: $template_path"
  fi
}

test_formula_generated_is_valid_ruby() {
  if command -v ruby >/dev/null 2>&1; then
    if ! ruby -c "$formula_path" >/dev/null 2>&1; then
      assert_fail "Formula/sandshell.rb is not valid Ruby"
    fi
  else
    printf '    ruby not available; skipping the optional ruby -c syntax check\n'
  fi
}

test_formula_generated_has_no_placeholders() {
  if grep -q '@[A-Z_][A-Z_]*@' "$formula_path"; then
    assert_fail "Formula/sandshell.rb still contains placeholders"
  fi
}

test_formula_generated_has_sandshell_class() {
  if ! grep -q 'class Sandshell < Formula' "$formula_path"; then
    assert_fail "Formula/sandshell.rb missing Sandshell class"
  fi
}

test_formula_generated_has_correct_homepage() {
  if ! grep -q 'homepage "https://github.com/dergrossedev/homebrew-sandshell"' "$formula_path"; then
    assert_fail "Formula/sandshell.rb has incorrect homepage"
  fi
}

test_formula_generated_has_correct_url() {
  if ! grep -q 'url "https://github.com/dergrossedev/homebrew-sandshell/releases/download/v0.1.0/sandshell-0.1.0.tar.gz"' "$formula_path"; then
    assert_fail "Formula/sandshell.rb has incorrect URL"
  fi
}

test_formula_generated_has_correct_sha256() {
  if ! grep -q 'sha256 "fe6e08f5548e5553be9e94b28b3f051752bc73af3cfc518bbf15d58d544bf03c"' "$formula_path"; then
    assert_fail "Formula/sandshell.rb has incorrect SHA256"
  fi
}

test_formula_generated_has_correct_version() {
  if ! grep -q 'version "0.1.0"' "$formula_path"; then
    assert_fail "Formula/sandshell.rb has incorrect version"
  fi
}

run_tests \
  test_formula_generated_exists \
  test_formula_template_exists \
  test_formula_generated_is_valid_ruby \
  test_formula_generated_has_no_placeholders \
  test_formula_generated_has_sandshell_class \
  test_formula_generated_has_correct_homepage \
  test_formula_generated_has_correct_url \
  test_formula_generated_has_correct_sha256 \
  test_formula_generated_has_correct_version
