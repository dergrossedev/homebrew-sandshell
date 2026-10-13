#!/usr/bin/env bash
# Tests for the public example files shipped with Sandshell (examples/).
#
# examples/vibe.toml is the canonical source of Sandshell's bundled Vibe
# preset: the build embeds it into sandshell.sh, and the runtime synchronizes
# it into Vibe sandboxes when the user has no <config-root>/agents/vibe.toml.
# These tests pin its public contract: it exists, is safe to publish (no
# credentials, no private paths), defaults to Mistral Large 4, is linked from
# the README, and cannot drift from the preset embedded in the runtime.

_helpers_dir=${0%/*}
[ "$_helpers_dir" = "$0" ] && _helpers_dir=.
. "$_helpers_dir/helpers.sh"
unset _helpers_dir

VIBE_EXAMPLE="$SANDSHELL_ROOT/examples/vibe.toml"

test_examples_vibe_toml_exists() {
  setup_test_env
  assert_file_exists "$VIBE_EXAMPLE"
}

test_examples_vibe_toml_defaults_to_mistral_large_4() {
  setup_test_env
  config=$(cat "$VIBE_EXAMPLE")
  assert_contains "$config" 'active_model = "mistral-large-4"'
  assert_contains "$config" 'name = "mistral-large-4"'
  assert_contains "$config" 'alias = "mistral-large-4"'
}

test_examples_vibe_toml_includes_glm_5_3_and_mistral_small() {
  setup_test_env
  config=$(cat "$VIBE_EXAMPLE")
  assert_contains "$config" 'name = "zai-glm-5-3"'
  assert_contains "$config" 'name = "mistral-small-latest"'
}

test_examples_vibe_toml_has_no_credentials_or_private_paths() {
  setup_test_env
  config=$(cat "$VIBE_EXAMPLE")
  # No credential-looking assignments.
  if printf '%s\n' "$config" | grep -Eqi '^[[:space:]]*(api_key|password|secret|token)[[:space:]]*='; then
    assert_fail 'vibe.toml assigns a credential-looking key'
  fi
  # No obvious key material.
  if printf '%s\n' "$config" | grep -Eq '(sk-[A-Za-z0-9]|Bearer[[:space:]]|[0-9a-fA-F]{40,})'; then
    assert_fail 'vibe.toml contains obvious key material'
  fi
  # No user-specific paths or private endpoints.
  assert_not_contains "$config" '/home/'
  assert_not_contains "$config" '/Users/'
  assert_not_contains "$config" 'localhost'
  assert_not_contains "$config" '127.0.0.1'
}

test_examples_vibe_toml_parses_as_toml() {
  setup_test_env
  # Optional check: parse with Python's stdlib tomllib when available. Python
  # is not a Sandshell dependency; static assertions above are the contract.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
    run python3 -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
models = data.get("models", [])
names = [m.get("name") for m in models]
assert names == ["mistral-small-latest", "mistral-large-4", "zai-glm-5-3"], names
aliases = {m.get("alias", m.get("name")) for m in models}
assert "mistral-large-4" in aliases, aliases
assert "zai-glm-5-3" in aliases, aliases
for m in models:
    assert m.get("provider") == "mistral", m
print("toml ok")
' "$VIBE_EXAMPLE"
    assert_rc 0
    assert_contains "$OUT" 'toml ok'
  else
    printf '    python3 with tomllib not found; skipping the TOML parse check\n'
  fi
}

test_examples_readme_links_the_vibe_example() {
  setup_test_env
  assert_contains "$(cat "$SANDSHELL_ROOT/README.md")" 'examples/vibe.toml'
}

test_examples_readme_documents_vibe_managed_config() {
  setup_test_env
  # Mistral organizations/workspaces may centrally configure Vibe through
  # "Vibe Code Clients managed config"; the README must document that it
  # takes precedence over the bundled preset and the local vibe.toml, and
  # that Sandshell does not try to override or detect it.
  readme=$(cat "$SANDSHELL_ROOT/README.md")
  assert_contains "$readme" 'Vibe Code Clients managed config'
  assert_contains "$readme" 'does not try to override or detect'
}

test_examples_runtime_does_not_depend_on_the_example() {
  setup_test_env
  # The runtime never reads the example file at runtime: the preset is
  # embedded at build time (proven functionally by the standalone test
  # below). Mentions of the path in the artifact are build-provenance
  # comments only.
  if grep -n 'examples/vibe.toml' "$SANDSHELL_SH" | grep -v '^[0-9]*:[[:space:]]*#'; then
    assert_fail 'runtime reads examples/vibe.toml outside a comment'
  fi
  # The runtime also never reads the Homebrew-installed copy of the example.
  assert_not_contains "$(cat "$SANDSHELL_SH")" 'pkgshare'
  assert_not_contains "$(cat "$SANDSHELL_SH")" 'share/sandshell'
}

# embedded_preset — print the Vibe preset embedded in the generated runtime.
embedded_preset() {
  bash -c '. "$1" && _sbx_vibe_default_config' sh "$SANDSHELL_SH"
}

test_examples_embedded_preset_matches_example() {
  setup_test_env
  # The embedded preset and the canonical example cannot drift: the build
  # generates one from the other.
  assert_eq "$(cat "$VIBE_EXAMPLE")" "$(embedded_preset)"
}

test_examples_embedded_preset_defaults_to_mistral_large_4() {
  setup_test_env
  preset=$(embedded_preset)
  assert_contains "$preset" 'active_model = "mistral-large-4"'
  # The bundled model order/content matches the canonical preset.
  models=$(printf '%s\n' "$preset" | awk -F'"' '
    /^\[\[models\]\]/ { inmodels = 1; next }
    /^\[/ { inmodels = 0 }
    inmodels && /^name = / { printf "%s%s", sep, $2; sep = " " }
  ')
  assert_eq 'mistral-small-latest mistral-large-4 zai-glm-5-3' "$models"
}

test_examples_runtime_works_without_repository_examples() {
  setup_test_env
  mkdir -p "$TEST_TMP/ws/proj" "$TEST_TMP/standalone"
  cp "$SANDSHELL_SH" "$TEST_TMP/standalone/sandshell.sh"
  # The copied runtime works with no examples/ directory available: the
  # bundled preset is embedded in the artifact, not read from the repository.
  run bash -c 'cd "$1" && . ./sandshell.sh && sbxc -d "$2" -a vibe -n vibe-standalone' \
    sh "$TEST_TMP/standalone" "$TEST_TMP/ws/proj"
  assert_rc 0
  assert_file_eq "$VIBE_EXAMPLE" \
    "$SBX_MOCK_STATE/fs/vibe-standalone/home/agent/.vibe/config.toml"
  assert_file_exists "$SBX_MOCK_STATE/fs/vibe-standalone/home/agent/.vibe/.sandshell-config-managed"
}

run_tests \
  test_examples_vibe_toml_exists \
  test_examples_vibe_toml_defaults_to_mistral_large_4 \
  test_examples_vibe_toml_includes_glm_5_3_and_mistral_small \
  test_examples_vibe_toml_has_no_credentials_or_private_paths \
  test_examples_vibe_toml_parses_as_toml \
  test_examples_readme_links_the_vibe_example \
  test_examples_readme_documents_vibe_managed_config \
  test_examples_runtime_does_not_depend_on_the_example \
  test_examples_embedded_preset_matches_example \
  test_examples_embedded_preset_defaults_to_mistral_large_4 \
  test_examples_runtime_works_without_repository_examples
