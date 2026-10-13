#!/usr/bin/env bash
# sandshell test suite — single entry point.
#
# Runs every tests/test_*.sh under Bash and (when installed) Zsh. Exits
# non-zero if any test file fails. Use -v/--verbose for full failure output.
#
# The suite is noninteractive and self-contained: it runs with a throwaway
# HOME/ZDOTDIR/TMPDIR, and every test file runs with a restricted PATH (see
# tests/helpers.sh) whose only non-system entry is a per-test bin directory
# holding the mock sbx. No test can reach a real sbx, Docker, an editor, or
# user configuration.
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root" || exit 1

# Isolated temp state for the whole run; removed when the suite exits.
suite_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandshell-suite.XXXXXX")
trap 'rm -rf "$suite_tmp"' EXIT
export TMPDIR="$suite_tmp"
export HOME="$suite_tmp/home"
export ZDOTDIR="$suite_tmp/zdotdir"
mkdir -p "$HOME" "$ZDOTDIR"
# Pinned Git identity; no user Git configuration is read.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME='Sandshell Test'
export GIT_AUTHOR_EMAIL='sandshell-test@example.com'
export GIT_COMMITTER_NAME='Sandshell Test'
export GIT_COMMITTER_EMAIL='sandshell-test@example.com'
# Editors and credential prompts fail closed; no host browser or shell
# injection variables are inherited.
export EDITOR=/usr/bin/false
export VISUAL=/usr/bin/false
export GIT_EDITOR=/usr/bin/false
export GIT_TERMINAL_PROMPT=0
unset BASH_ENV ENV BROWSER

verbose=0
for arg in "$@"; do
  case $arg in
    -v|--verbose) verbose=1 ;;
    -h|--help)
      printf 'usage: scripts/test.sh [-v|--verbose]\n'
      exit 0
      ;;
    *)
      printf 'test.sh: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

shells=bash
if command -v zsh >/dev/null 2>&1; then
  shells="$shells zsh"
else
  printf 'test.sh: warning: zsh not found; running Bash tests only\n' >&2
fi

total=0
failed=0
for shell in $shells; do
  for test_file in tests/test_*.sh; do
    [ -f "$test_file" ] || continue
    total=$((total + 1))
    out=$("$shell" "$test_file" </dev/null 2>&1)
    rc=$?
    passed=$(printf '%s\n' "$out" | grep -c '^ok ')
    failures=$(printf '%s\n' "$out" | grep -c '^FAIL ')
    if [ "$rc" -eq 0 ] && [ "$failures" -eq 0 ]; then
      printf 'PASS  %-4s  %s (%s tests)\n' "$shell" "$test_file" "$passed"
    else
      failed=$((failed + 1))
      printf 'FAIL  %-4s  %s\n' "$shell" "$test_file"
      if [ "$verbose" -eq 1 ]; then
        printf '%s\n' "$out" | sed 's/^/    /'
      else
        printf '%s\n' "$out" | grep -E '^(FAIL|    )' | sed 's/^/    /'
      fi
    fi
  done
done

printf '\n'
if [ "$failed" -eq 0 ]; then
  printf 'All %s test files passed.\n' "$total"
  exit 0
fi
printf '%s of %s test files failed.\n' "$failed" "$total"
exit 1
