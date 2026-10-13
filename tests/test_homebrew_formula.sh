#!/usr/bin/env bash
# Tests for scripts/homebrew-formula.sh and the Homebrew formula template.
#
# The generator is plain shell substitution over release metadata: no
# network access, no Homebrew installation, and no mutation of any Homebrew
# state. These tests validate the generated formula statically and execute
# its test-block logic against the repository artifact (the simpler
# boundary, without Homebrew).

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

OWNER=example-owner
VERSION=0.1.0
SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# generate_formula — run the generator with the default metadata; sets
# RC/OUT/ERR through run.
generate_formula() {
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" \
    --owner "$OWNER" --version "$VERSION" --sha256 "$SHA256"
}

test_formula_generator_is_executable() {
  setup_test_env
  [ -x "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" ] || assert_fail 'scripts/homebrew-formula.sh is not executable'
}

test_formula_template_and_docs_exist() {
  setup_test_env
  assert_file_exists "$SANDSHELL_ROOT/packaging/homebrew/Formula/sandshell.rb.in"
  assert_file_exists "$SANDSHELL_ROOT/packaging/homebrew/README.md"
  template=$(cat "$SANDSHELL_ROOT/packaging/homebrew/Formula/sandshell.rb.in")
  assert_contains "$template" '@OWNER@'
  assert_contains "$template" '@VERSION@'
  assert_contains "$template" '@SHA256@'
}

test_formula_generator_produces_expected_formula() {
  setup_test_env
  generate_formula
  assert_rc 0
  formula=$OUT
  assert_contains "$formula" 'class Sandshell < Formula'
  assert_contains "$formula" "url \"https://github.com/$OWNER/sandshell/releases/download/v$VERSION/sandshell-$VERSION.tar.gz\""
  assert_contains "$formula" "sha256 \"$SHA256\""
  assert_contains "$formula" "version \"$VERSION\""
  assert_contains "$formula" 'license "MIT"'
  assert_contains "$formula" 'libexec.install "sandshell.sh"'
  assert_contains "$formula" 'bash_completion.install "completions/sandshell.bash"'
  assert_contains "$formula" 'zsh_completion.install "completions/_sandshell" => "_sandshell"'
  assert_contains "$formula" 'test do'
  assert_contains "$formula" 'source "$(brew --prefix sandshell)/libexec/sandshell.sh"'
}

test_formula_installs_example_under_pkgshare() {
  setup_test_env
  generate_formula
  assert_rc 0
  # The example Vibe config is installed as a public data asset under
  # pkgshare (share/sandshell/examples/vibe.toml), using Homebrew path
  # helpers rather than a hardcoded prefix.
  assert_contains "$OUT" '(pkgshare/"examples").install "examples/vibe.toml"'
  assert_not_contains "$OUT" '/opt/homebrew/share'
  assert_not_contains "$OUT" '/usr/local/share'
  # The formula test block verifies the installed example.
  block=$(printf '%s\n' "$OUT" | sed -n '/^  test do$/,/^  end$/p')
  assert_contains "$block" 'pkgshare/"examples/vibe.toml"'
  assert_contains "$block" ':exist?'
  # The caveats mention where the example is installed.
  caveats=$(printf '%s\n' "$OUT" | sed -n '/def caveats/,/^  end$/p')
  assert_contains "$caveats" 'share/sandshell/examples/vibe.toml'
}

test_formula_generator_leaves_no_unresolved_placeholders() {
  setup_test_env
  generate_formula
  assert_rc 0
  assert_not_contains "$OUT" '@OWNER@'
  assert_not_contains "$OUT" '@VERSION@'
  assert_not_contains "$OUT" '@SHA256@'
  if printf '%s\n' "$OUT" | grep -q '@[A-Z_][A-Z_]*@'; then
    assert_fail 'generated formula contains an unresolved placeholder'
  fi
}

test_formula_generator_has_no_hardcoded_prefixes() {
  setup_test_env
  generate_formula
  assert_rc 0
  assert_not_contains "$OUT" '/opt/homebrew'
  assert_not_contains "$OUT" '/usr/local'
}

test_formula_generator_declares_no_dependencies() {
  setup_test_env
  generate_formula
  assert_rc 0
  # No depends_on at all: no ShellCheck, no Bash/Zsh, no Docker/sbx.
  if printf '%s\n' "$OUT" | grep -q 'depends_on'; then
    assert_fail 'formula declares a dependency'
  fi
  assert_not_contains "$OUT" 'shellcheck'
  assert_not_contains "$OUT" 'ShellCheck'
}

test_formula_generator_rejects_invalid_input() {
  setup_test_env
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh"
  assert_rc 2
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner "$OWNER"
  assert_rc 2
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner
  assert_rc 2
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --bogus x
  assert_rc 2
  for owner in '' 'bad owner' '-bad' 'bad-' 'bad_owner' 'bad..owner'; do
    run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner "$owner" --version "$VERSION" --sha256 "$SHA256"
    assert_rc 2 "owner [$owner] must be rejected"
  done
  long_owner=$(printf '%040d' 0 | tr '0' 'a')
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner "$long_owner" --version "$VERSION" --sha256 "$SHA256"
  assert_rc 2
  for version in '1.0.0' '0.1' 'v0.1.0' 'abc' '0.1.0.1'; do
    run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner "$OWNER" --version "$version" --sha256 "$SHA256"
    assert_rc 2 "version [$version] must be rejected"
  done
  short63=$(printf '%s' "$SHA256" | cut -c1-63)
  nonhex=$(printf '%s' "$SHA256" | sed 's/[0-9a-f]/g/g')
  for sha in '' 'abc' "$short63" "${SHA256}a" "$nonhex"; do
    run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner "$OWNER" --version "$VERSION" --sha256 "$sha"
    assert_rc 2 "sha256 [$sha] must be rejected"
  done
}

test_formula_generator_accepts_valid_edge_inputs() {
  setup_test_env
  # Hyphens and digits in the owner; a 39-character owner; uppercase hex.
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner 'my-org-2' --version 0.2.0 --sha256 "$SHA256"
  assert_rc 0
  assert_contains "$OUT" 'https://github.com/my-org-2/sandshell/releases/download/v0.2.0/sandshell-0.2.0.tar.gz'
  owner39=$(printf '%039d' 0 | tr '0' 'a')
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner "$owner39" --version "$VERSION" --sha256 "$SHA256"
  assert_rc 0
  upper=$(printf '%s' "$SHA256" | tr 'a-f' 'A-F')
  run "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" --owner "$OWNER" --version "$VERSION" --sha256 "$upper"
  assert_rc 0
  assert_contains "$OUT" "sha256 \"$upper\""
}

test_formula_generator_supports_stdout_redirection() {
  setup_test_env
  run sh -c '"$1" --owner "$2" --version "$3" --sha256 "$4" >"$5"' \
    sh "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" "$OWNER" "$VERSION" "$SHA256" "$TEST_TMP/sandshell.rb"
  assert_rc 0
  assert_file_exists "$TEST_TMP/sandshell.rb"
  assert_contains "$(cat "$TEST_TMP/sandshell.rb")" 'class Sandshell < Formula'
}

test_formula_generator_runs_under_zsh() {
  setup_test_env
  run zsh "$SANDSHELL_ROOT/scripts/homebrew-formula.sh" \
    --owner "$OWNER" --version "$VERSION" --sha256 "$SHA256"
  assert_rc 0
  assert_contains "$OUT" 'class Sandshell < Formula'
}

test_formula_generator_ruby_syntax_check() {
  setup_test_env
  generate_formula
  assert_rc 0
  printf '%s\n' "$OUT" >"$TEST_TMP/sandshell.rb"
  if command -v ruby >/dev/null 2>&1; then
    run ruby -c "$TEST_TMP/sandshell.rb"
    assert_rc 0
    assert_contains "$OUT" 'Syntax OK'
  else
    printf '    ruby not found; skipping the optional ruby -c syntax check\n'
  fi
}

test_formula_test_block_logic_against_runtime() {
  setup_test_env
  # The formula's test block sources the installed runtime in Bash and
  # confirms the public helper functions exist. Run the same logic against
  # the repository artifact — the simpler boundary, without Homebrew.
  run bash -c '. "$1" && command -v sbxc && command -v sbxr && command -v sbxenv && command -v sbxmcp && command -v sbxskill && command -v sbxwt && command -v sbxcmd && sbxcmd' sh "$SANDSHELL_SH"
  assert_rc 0
  assert_contains "$OUT" 'Docker Sandbox helpers:'
}

test_formula_test_block_does_not_invoke_docker() {
  setup_test_env
  generate_formula
  assert_rc 0
  block=$(printf '%s\n' "$OUT" | sed -n '/^  test do$/,/^  end$/p')
  assert_contains "$block" 'test do'
  assert_not_contains "$block" 'sbx '
  assert_not_contains "$block" 'docker'
}

run_tests \
  test_formula_generator_is_executable \
  test_formula_template_and_docs_exist \
  test_formula_generator_produces_expected_formula \
  test_formula_installs_example_under_pkgshare \
  test_formula_generator_leaves_no_unresolved_placeholders \
  test_formula_generator_has_no_hardcoded_prefixes \
  test_formula_generator_declares_no_dependencies \
  test_formula_generator_rejects_invalid_input \
  test_formula_generator_accepts_valid_edge_inputs \
  test_formula_generator_supports_stdout_redirection \
  test_formula_generator_runs_under_zsh \
  test_formula_generator_ruby_syntax_check \
  test_formula_test_block_logic_against_runtime \
  test_formula_test_block_does_not_invoke_docker
