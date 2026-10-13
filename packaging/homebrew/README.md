# Homebrew packaging for sandshell

sandshell is distributed through Homebrew from a separate public tap repository named `homebrew-sandshell`; the main repository only carries the formula template (`Formula/sandshell.rb.in`). Nothing is published yet — see [RELEASING.md](../../RELEASING.md) for the full release checklist.

## Release flow

1. Build the release archive: `./scripts/package.sh 0.1.0` (produces `dist/sandshell-0.1.0.tar.gz` and its `.sha256`).
2. Publish the GitHub release with the archive attached (human approval required).
3. Generate the formula with the real owner, version, and archive checksum:

       ./scripts/homebrew-formula.sh \
         --owner dergrossedev \
         --version 0.1.0 \
         --sha256 SHA256 \
         > Formula/sandshell.rb

4. Commit the generated `Formula/sandshell.rb` to the tap repository.

When the version or release-archive SHA256 changes, regenerate `Formula/sandshell.rb` using the same command above.

5. Validate it: `ruby -c Formula/sandshell.rb`, and `brew audit` when Homebrew is available.

## User installation (once the tap is public)

A GitHub repository named `dergrossedev/homebrew-sandshell` maps to the formula `dergrossedev/sandshell`, so users install with:

    brew install dergrossedev/sandshell

The formula installs the generated `sandshell.sh` under `libexec/`, the Bash and Zsh completions into the standard completion directories, and `examples/vibe.toml` under `share/sandshell/examples/`; its caveats show the single `source` line to add to the shell configuration. It declares no dependencies.

Do not run `brew install`, `brew tap`, `brew uninstall`, or `brew upgrade` against a real Homebrew installation without explicit approval.
