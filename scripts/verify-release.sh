#!/usr/bin/env bash
# Verify a published release; intentionally updates the local Homebrew install.
set -eu

_sandshell_verify_fail() {
  printf 'verify-release.sh: %s\n' "$1" >&2
  exit 1
}

# Same calendar syntax as release.sh/publish.sh; independent of today's date.
version_re='^[0-9]{4}\.(1[0-2]|[1-9])\.(0|[1-9][0-9]*)$'
if [ $# -ne 1 ] || ! [[ $1 =~ $version_re ]]; then
  printf 'usage: scripts/verify-release.sh VERSION (calendar version YYYY.M.PATCH)\n' >&2
  exit 2
fi
version=$1
formula='dergrossedev/sandshell/sandshell'

for tool in brew zsh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    install_name=$tool
    [ "$tool" != brew ] || install_name=Homebrew
    printf 'verify-release.sh: required executable not found: %s; install %s and retry\n' \
      "$tool" "$install_name" >&2
    exit 127
  fi
done

# Keep successful Homebrew progress quiet, but preserve diagnostics on failure.
_sandshell_verify_brew() {
  local output
  if output=$(brew "$@" 2>&1); then
    return 0
  fi
  [ -z "$output" ] || printf '%s\n' "$output" >&2
  _sandshell_verify_fail "brew $* failed; resolve the Homebrew error and retry"
}

_sandshell_verify_brew update
_sandshell_verify_brew audit --strict "$formula"

# Listing all installed formulae succeeds even when sandshell is absent.
installed_formulae=$(brew list --formula) ||
  _sandshell_verify_fail 'cannot list installed formulae; check Homebrew and retry'
if printf '%s\n' "$installed_formulae" | grep -qx sandshell; then
  if upgrade_output=$(brew upgrade sandshell 2>&1); then
    :
  else
    case $upgrade_output in
      *"sandshell $version already installed"*) ;;
      *)
        [ -z "$upgrade_output" ] || printf '%s\n' "$upgrade_output" >&2
        _sandshell_verify_fail 'brew upgrade sandshell failed; resolve the Homebrew error and retry'
        ;;
    esac
  fi
else
  _sandshell_verify_brew install "$formula"
fi

# Homebrew's opt prefix selects the active keg even when older kegs remain.
formula_prefix=$(brew --prefix sandshell) ||
  _sandshell_verify_fail 'cannot find sandshell prefix; check Homebrew and retry'
active_prefix=$(cd "$formula_prefix" && pwd -P) ||
  _sandshell_verify_fail 'cannot resolve the active sandshell keg; check Homebrew and retry'
installed=${active_prefix##*/}
[ "$installed" = "$version" ] ||
  _sandshell_verify_fail "installed version is ${installed:-none}; expected $version; check the published formula and retry"

_sandshell_verify_brew test "$formula"

brew_prefix=$(brew --prefix) ||
  _sandshell_verify_fail 'cannot find Homebrew prefix; check Homebrew and retry'
for asset in \
  "$formula_prefix/libexec/sandshell.sh" \
  "$formula_prefix/share/sandshell/examples/vibe.toml" \
  "$brew_prefix/share/zsh/site-functions/_sandshell" \
  "$brew_prefix/etc/bash_completion.d/sandshell.bash"; do
  [ -f "$asset" ] || _sandshell_verify_fail "missing installed asset: $asset"
done

if runtime_output=$(zsh -f -c '
  source "$(brew --prefix sandshell)/libexec/sandshell.sh" &&
  command -v sbxc &&
  command -v sbxr &&
  command -v sbxenv &&
  command -v sbxmcp &&
  command -v sbxskill &&
  command -v sbxwt &&
  command -v sbxcmd &&
  sbxcmd
' 2>&1); then
  :
else
  [ -z "$runtime_output" ] || printf '%s\n' "$runtime_output" >&2
  _sandshell_verify_fail 'Zsh runtime smoke test failed; check the installed runtime and retry'
fi

printf 'Verified v%s\n\n' "$version"
printf 'Homebrew audit: pass\nInstalled:       %s\nFormula test:    pass\nRuntime:         pass\n' "$installed"
