#!/usr/bin/env bash
# Intentional public release action; run after pushing main and reviewing CI.
set -eu

_sandshell_publish_fail() {
  printf 'publish.sh: %s\n' "$1" >&2
  exit 1
}

version_re='^[0-9]{4}\.(1[0-2]|[1-9])\.(0|[1-9][0-9]*)$'
if [ $# -ne 1 ] || ! [[ $1 =~ $version_re ]]; then
  printf 'usage: scripts/publish.sh VERSION (calendar version YYYY.M.PATCH)\n' >&2
  exit 2
fi
version=$1
tag="v$version"
repo='dergrossedev/homebrew-sandshell'
archive="dist/sandshell-$version.tar.gz"
checksum="$archive.sha256"

for tool in git gh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'publish.sh: required executable not found: %s\n' "$tool" >&2
    exit 127
  fi
done

cd "$(dirname "$0")/.."
root=$(git rev-parse --show-toplevel) || _sandshell_publish_fail 'cannot locate repository root'
cd "$root"
tree=$(git status --porcelain) || _sandshell_publish_fail 'cannot check working tree'
[ -z "$tree" ] || _sandshell_publish_fail 'working tree is dirty; commit or stash changes first'

for file in "$archive" "$checksum" Formula/sandshell.rb CHANGELOG.md; do
  [ -f "$file" ] || _sandshell_publish_fail "missing required file: $file"
done

# Match the version literally; accept dotted project dates or ISO dates.
if ! awk -v version="$version" '
  $1 == "##" && $2 == "[" version "]" && $3 == "-" && NF == 4 &&
  ($4 ~ /^[0-9][0-9][0-9][0-9][.-][0-9][0-9][.-][0-9][0-9]$/ ||
   $4 ~ /^[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9][0-9][0-9]$/) { found = 1 }
  END { exit !found }
' CHANGELOG.md; then
  _sandshell_publish_fail "CHANGELOG.md must contain a dated entry for $version"
fi

# Require one checksum for this exact asset, then hash the asset directly.
package_sha=$(awk -v name="sandshell-$version.tar.gz" '
  NR == 1 && NF == 2 && $2 == name { sha = $1 }
  END { if (NR == 1 && length(sha) == 64 && sha !~ /[^0-9a-f]/) print sha; else exit 1 }
' "$checksum") || _sandshell_publish_fail 'invalid package checksum file'
if command -v sha256sum >/dev/null 2>&1; then
  actual_sha=$(sha256sum "$archive") || _sandshell_publish_fail 'cannot checksum package'
else
  actual_sha=$(shasum -a 256 "$archive") || _sandshell_publish_fail 'cannot checksum package'
fi
[ "${actual_sha%% *}" = "$package_sha" ] || _sandshell_publish_fail 'package checksum mismatch'

url="https://github.com/$repo/releases/download/$tag/sandshell-$version.tar.gz"
if ! awk -v url="\"$url\"" -v sha="\"$package_sha\"" '
  $1 == "url" && $2 == url && NF == 2 { url_ok = 1 }
  $1 == "sha256" && $2 == sha && NF == 2 { sha_ok = 1 }
  END { exit !(url_ok && sha_ok) }
' Formula/sandshell.rb; then
  _sandshell_publish_fail 'Formula/sandshell.rb must reference the release package URL and exact package SHA'
fi

gh auth status >/dev/null 2>&1 || _sandshell_publish_fail 'GitHub authentication failed; run gh auth login'
branch=$(git symbolic-ref --quiet --short HEAD) || _sandshell_publish_fail 'publishing requires branch main'
[ "$branch" = main ] || _sandshell_publish_fail 'publishing requires branch main; switch to main first'
git fetch origin main >/dev/null 2>&1 || _sandshell_publish_fail 'could not fetch origin main; check origin and retry'
head=$(git rev-parse HEAD)
remote_head=$(git rev-parse refs/remotes/origin/main)
[ "$head" = "$remote_head" ] || _sandshell_publish_fail 'HEAD differs from origin/main; reconcile main, git push, and wait for green CI before retrying'

local_tags=$(git tag --list "$tag") || _sandshell_publish_fail 'cannot check local tags'
[ -z "$local_tags" ] || _sandshell_publish_fail "tag $tag already exists locally"
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  _sandshell_publish_fail "tag $tag already exists on origin"
else
  rc=$?
  [ "$rc" -eq 2 ] || _sandshell_publish_fail 'cannot check remote tags; check origin and retry'
fi

# Paginate all releases: a failed lookup must never mean "does not exist".
releases=$(gh api "repos/$repo/releases" --paginate --jq '.[].tag_name') ||
  _sandshell_publish_fail 'cannot check GitHub Releases; check GitHub access and retry'
while IFS= read -r release_tag; do
  [ "$release_tag" != "$tag" ] || _sandshell_publish_fail "GitHub Release $tag already exists"
done <<< "$releases"

# All preconditions passed. Failures keep any created tag for manual recovery.
git tag -a "$tag" -m "$tag" || _sandshell_publish_fail "could not create annotated tag $tag"
if ! git push origin "$tag"; then
  printf 'publish.sh: tag push failed; local tag kept. Retry from the repository root:\n  git push origin %s\n' "$tag" >&2
  exit 1
fi
if ! gh release create "$tag" "$archive" "$checksum" \
  --repo "$repo" --verify-tag --title "$tag" --generate-notes >/dev/null; then
  printf 'publish.sh: GitHub Release creation failed; public tag kept. Retry from the repository root:\n  gh release create %s %s %s --repo %s --verify-tag --title "%s" --generate-notes\n' \
    "$tag" "$archive" "$checksum" "$repo" "$tag" >&2
  exit 1
fi

printf 'Published %s\n\nTag:     %s\nRelease: https://github.com/%s/releases/tag/%s\nPackage: sandshell-%s.tar.gz\n\n' \
  "$tag" "$tag" "$repo" "$tag" "$version"
printf 'Next:\n  brew update\n  brew audit --strict dergrossedev/sandshell/sandshell\n  brew upgrade sandshell\n'
