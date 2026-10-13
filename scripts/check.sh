#!/usr/bin/env bash
# sandshell quality gate — the single local entry point for the checks CI runs.
#
# Stages, in order:
#   1. syntax      bash -n / zsh -n over the shell files (on macOS, /bin/bash
#                  is Apple's Bash 3.2 and is used for the Bash syntax check)
#   2. build       ./scripts/build.sh --check (generated artifact freshness)
#   3. shellcheck  static analysis (skipped with a notice when not installed)
#   4. tests       ./scripts/test.sh (deterministic suite, mocked sbx)
#
# Exits non-zero on the first failing stage. ShellCheck is optional locally
# but always installed in CI. Info-level ShellCheck notes are not gated:
# SC2016 (single-quoted scripts that run inside the sandbox) and SC1091
# (tests source helpers.sh through a computed path) are intentional.

set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root" || exit 1

fail() {
  printf 'check.sh: FAILED: %s\n' "$1" >&2
  exit 1
}

stage() {
  printf '==> %s\n' "$1"
}

# --- 1. syntax ---------------------------------------------------------------

# On macOS, /bin/bash is Apple's Bash 3.2; use it so the system parser is
# exercised. Elsewhere, use the normal bash.
if [ "$(uname -s)" = 'Darwin' ]; then
  bash_bin=/bin/bash
else
  bash_bin=bash
fi

stage "syntax ($bash_bin -n)"
for file in sandshell.sh src/*.sh scripts/*.sh tests/*.sh tests/mocks/sbx completions/sandshell.bash; do
  "$bash_bin" -n "$file" || fail "$bash_bin -n failed: $file"
done

if command -v zsh >/dev/null 2>&1; then
  stage 'syntax (zsh -n)'
  # completions/_sandshell is native Zsh completion syntax, checked with
  # zsh -n only; completions/sandshell.bash is Bash-only.
  for file in sandshell.sh src/*.sh scripts/*.sh tests/*.sh completions/_sandshell; do
    zsh -n "$file" || fail "zsh -n failed: $file"
  done
else
  printf 'check.sh: zsh not found; skipping Zsh syntax checks\n'
fi

# --- 2. generated artifact ---------------------------------------------------

stage 'build (./scripts/build.sh --check)'
./scripts/build.sh --check || fail 'generated sandshell.sh is stale; run ./scripts/build.sh'

# --- 3. ShellCheck -----------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1; then
  stage 'shellcheck'
  # _sandshell is native Zsh completion syntax; ShellCheck has no Zsh
  # dialect, so it is intentionally not linted.
  shellcheck --severity=warning \
    sandshell.sh src/*.sh scripts/*.sh completions/sandshell.bash \
    tests/*.sh tests/mocks/sbx \
    || fail 'shellcheck found issues'
else
  printf 'check.sh: shellcheck not found; skipping (CI always runs it)\n'
fi

# --- 4. tests ----------------------------------------------------------------

stage 'tests (./scripts/test.sh)'
./scripts/test.sh "$@" || fail 'test suite failed'

printf 'check.sh: all checks passed\n'
