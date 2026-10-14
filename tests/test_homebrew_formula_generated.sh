#!/usr/bin/env bash
# Test that the repository contains a valid generated Formula/sandshell.rb
# matching the canonical generator for its current release metadata.

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

_sandshell_formula_version() {
  formula_version=$(sed -n 's|^[[:space:]]*url "[^"]*/sandshell-\([^"/]*\)\.tar\.gz"$|\1|p' "$formula_path")
  assert_match '^[0-9]+\.[0-9]+\.[0-9]+$' "$formula_version" \
    'Could not extract a valid release version from Formula/sandshell.rb URL'
}

_sandshell_formula_sha256() {
  formula_sha256=$(sed -n 's/^[[:space:]]*sha256 "\([^"]*\)"$/\1/p' "$formula_path")
  assert_match '^[0-9a-fA-F]{64}$' "$formula_sha256" \
    'Could not extract a valid SHA256 from Formula/sandshell.rb (expected 64 hexadecimal characters)'
}

test_formula_generated_matches_template() {
  setup_test_env
  _sandshell_formula_version
  _sandshell_formula_sha256
  if ! "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" \
    --owner dergrossedev --version "$formula_version" \
    --sha256 "$formula_sha256" >"$TEST_TMP/expected.rb"; then
    assert_fail "Could not generate expected Formula/sandshell.rb"
  fi
  assert_file_eq "$TEST_TMP/expected.rb" "$formula_path"
  assert_contains "$(cat "$formula_path")" '  desc "Bash and Zsh helpers for Docker Sandboxes"'
}

test_formula_generated_has_correct_url() {
  _sandshell_formula_version
  if ! grep -Fqx "  url \"https://github.com/dergrossedev/homebrew-sandshell/releases/download/v$formula_version/sandshell-$formula_version.tar.gz\"" "$formula_path"; then
    assert_fail "Formula/sandshell.rb has incorrect URL"
  fi
}

test_formula_generated_has_correct_sha256() {
  _sandshell_formula_sha256
}

test_formula_template_has_no_version_placeholder() {
  if grep -q 'version "@VERSION@"' "$template_path"; then
    assert_fail "Template still contains version placeholder"
  fi
}

test_formula_generated_has_no_version_declaration() {
  if grep -q '^[[:space:]]*version ' "$formula_path"; then
    assert_fail "Generated formula contains explicit version declaration"
  fi
}

run_tests \
  test_formula_generated_exists \
  test_formula_template_exists \
  test_formula_generated_is_valid_ruby \
  test_formula_generated_has_no_placeholders \
  test_formula_template_has_no_version_placeholder \
  test_formula_generated_has_sandshell_class \
  test_formula_generated_has_no_version_declaration \
  test_formula_generated_has_correct_homepage \
  test_formula_generated_matches_template \
  test_formula_generated_has_correct_url \
  test_formula_generated_has_correct_sha256
