# Releasing sandshell

Operational checklist for cutting a release. Nothing here is automated; every publishing step requires explicit human approval.

Repositories (placeholders until the public owner is known):

- `dergrossedev/homebrew-sandshell` — Homebrew formula

## Release checklist

1. Clean working tree (`git status --porcelain` prints nothing) on `main`.
2. Run the quality gate: `./scripts/check.sh`
3. Verify the generated artifact is current: `./scripts/build.sh --check`
4. Perform the real Docker Sandbox smoke tests (below).
5. Package: `./scripts/package.sh 0.1.0`
6. Verify the archive and checksum: `tar -tzf dist/sandshell-0.1.0.tar.gz`, then `sha256sum -c dist/sandshell-0.1.0.tar.gz.sha256` (`shasum -a 256 -c` on macOS).
7. Change `CHANGELOG.md` `0.1.0` from `Unreleased` to the actual date, and commit.
8. Create the annotated tag (human approval required): `git tag -a v0.1.0 -m "sandshell 0.1.0"`
9. Publish the GitHub release (human approval required) and attach `dist/sandshell-0.1.0.tar.gz` and `dist/sandshell-0.1.0.tar.gz.sha256`.
10. Generate the Homebrew formula with the published archive checksum:

        ./scripts/homebrew-formula.sh --owner dergrossedev --version 0.1.0 --sha256 SHA256 \
          > Formula/sandshell.rb

11. Commit the generated `Formula/sandshell.rb` to the repository. Update `homebrew-sandshell/Formula/sandshell.rb` in the tap repository, validate it (`ruby -c Formula/sandshell.rb`, `brew audit` when Homebrew is available), and run an approved install/test/uninstall.

When the version or release-archive SHA256 changes, regenerate `Formula/sandshell.rb` using the command in step 10.
12. Publish the tap (human approval required).
13. Verify installation from the public tap:

        brew install dergrossedev/sandshell

`dist/` is git-ignored; never commit release archives. Do not automate these publication steps.

## Real Docker Sandbox smoke tests

Not CI tests: a human performs them against a real Docker Sandboxes installation before every release, using temporary repositories and sandboxes, cleaned up with the existing safe commands. The automated suite (`./scripts/check.sh`) is fully noninteractive and never invokes real `sbx`, Docker, an editor, or a terminal; everything below belongs here.

- **Base sandbox**: `sbxc -a claude`, `sbxr` — creation succeeds, the generated name is sensible, the env file is applied, resume works, no unexpected second sandbox.
- **Codex**: `sbxc -a codex`, `sbxr NAME` — the agent launches; completions and listing show the sandbox.
- **Vibe**: `sbxc -a vibe` with and without `<config-root>/agents/vibe.toml` (copy `examples/vibe.toml`) — Vibe starts with the configured model (Mistral Large 4 by default); after editing the config, `sbxr SANDBOX` resumes with the changed config; after removing it, the bundled preset is synchronized again. If the tester's account is covered by a Mistral "Vibe Code Clients managed config", note that it takes precedence over both; sandshell does not try to override or detect it — use Vibe's `/reload` to refresh an active session.
- **Claude-Ollama**: with Ollama running and a known model, set `CLAUDE_OLLAMA_MODEL` via `sbxenv`, `sbxc -a claude-ollama`, `sbxr NAME` — verify the expected model is used. Do not download a large model as part of the release test.
- **OpenCode-Ollama**: with Ollama running and `qwen3.5:4b-mlx` installed, `sbxc -a opencode-ollama`, `sbxr NAME` — verify the Ollama provider and default model; then repeat with `--model MODEL` (an installed model) and verify the override. sandshell never pulls models.
- **MCP**: with a harmless registered MCP such as Playwright, `sbxmcp add SANDBOX playwright` — verify for Codex, Vibe, and Claude-Ollama that the agent can actually see/use the gateway, not merely that `sbx mcp load` succeeds.
- **Skills**: `sbxskill add SANDBOX SKILL`, `sbxskill ls SANDBOX`, `sbxskill remove SANDBOX SKILL` — verify the skill is visible to the intended agent and isolated from another sandbox.
- **Confirmation prompts**: exercise each interactive yes/no path and its declined path — `sbxc` on a workspace that already has a sandbox (confirm creates a second sandbox; decline cancels), `sbxmcp add SANDBOX` with a host-command (local) MCP server (approve loads it; decline cancels), and `sbxwt commit`/`merge`/`done` (confirm performs the operation; decline cancels and changes nothing).
- **Editors**: `sbxenv` opens the configured editor (explicit argument, `VISUAL`, `EDITOR`, then `vi` fallback) on the project env file without clobbering existing contents; `sbxwt commit SANDBOX` without `-m` opens the editor for the commit message.
- **Shell completions**: extract the release archive into a temporary directory and test against the extracted artifact. Zsh: in a fresh interactive `zsh`, source the extracted `sandshell.sh`, add the extracted `completions` directory to `fpath` BEFORE `compinit`, run `compinit`, and press TAB for `sbxc -a ` and `sbxr `; also verify the already-initialized case (run `compinit` first, add to `fpath`, re-run `compinit` once). Bash: source the extracted `sandshell.sh` and `completions/sandshell.bash`, and press TAB for `sbxc -a ` and `sbxr `. The automated suite covers loading, discovery, and candidate generation only (`tests/test_completion_bash.sh`, `tests/test_completion_zsh.sh`, `tests/test_release_completion.sh`); pressing TAB in a real shell is manual.
- **Worktrees**: in a disposable Git repo, `sbxwt create feat/test -a codex`, make a small agent edit, then `sbxwt commit SANDBOX -m "Test worktree workflow"`, `sbxwt merge SANDBOX`, `sbxwt done SANDBOX` — verify the branch survives, the worktree and sandbox are removed, sandshell tracking state is removed, and the merged change exists on the target branch. Also confirm the unmerged warning on `sbxwt done` and the dirty-worktree refusal.
