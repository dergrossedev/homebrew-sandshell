# Releasing sandshell

Future releases use YYYY.M.PATCH calendar versions, for example
2026.10.0 or 2026.10.1.

1. Update `CHANGELOG.md` and commit it.
2. Run `./scripts/release.sh VERSION`.
3. Review and commit the generated release changes.
4. Push and wait for CI to pass.
5. Run `./scripts/publish.sh VERSION`.
6. Run `./scripts/verify-release.sh VERSION`.

Verification requires Homebrew and Zsh and intentionally updates the local
Homebrew installation. It does not require Docker Sandboxes.

`dist/` is git-ignored; never commit release archives. If publishing fails, follow the printed recovery command. Do not move existing tags or overwrite releases, including `v0.1.0`.

## Real Docker Sandbox smoke tests

Before a release, run these checks manually in temporary repositories and sandboxes, then clean up with the existing safe commands.

- **Base sandbox**: `sbxc`, `sbxr` — OpenCode creation succeeds, the generated name is sensible, the env file is applied, resume works, no unexpected second sandbox.
- **Codex**: `sbxc -a codex`, `sbxr NAME` — the agent launches; completions and listing show the sandbox.
- **Vibe**: `sbxc -a vibe` with and without `<config-root>/agents/vibe.toml` (copy `examples/vibe.toml`) — Vibe starts with the configured model (Mistral Large 4 by default); after editing the config, `sbxr SANDBOX` resumes with the changed config; after removing it, the bundled preset is synchronized again. If the tester's account is covered by a Mistral "Vibe Code Clients managed config", note that it takes precedence over both; sandshell does not try to override or detect it — use Vibe's `/reload` to refresh an active session.
- **Claude-Ollama**: with Ollama running and a known model, set `CLAUDE_OLLAMA_MODEL` via `sbxenv`, `sbxc -a claude-ollama`, `sbxr NAME` — verify the expected model is used. Do not download a large model as part of the release test.
- **OpenCode-Ollama**: with Ollama running and `qwen3.5:4b-mlx` installed, `sbxc -a opencode-ollama`, `sbxr NAME` — verify the Ollama provider and default model; then repeat with `--model MODEL` (an installed model) and verify the override. sandshell never pulls models.
- **MCP**: with a harmless registered MCP such as Playwright, `sbxmcp add SANDBOX playwright` — verify for Codex, Vibe, and Claude-Ollama that the agent can actually see/use the gateway, not merely that `sbx mcp load` succeeds.
- **Skills**: `sbxskill add SANDBOX SKILL`, `sbxskill ls SANDBOX`, `sbxskill remove SANDBOX SKILL` — verify the skill is visible to the intended agent and isolated from another sandbox.
- **Confirmation prompts**: exercise each interactive yes/no path and its declined path — `sbxc` on a workspace that already has a sandbox (confirm creates a second sandbox; decline cancels), `sbxmcp add SANDBOX` with a host-command (local) MCP server (approve loads it; decline cancels), and `sbxwt commit`/`merge`/`done` (confirm performs the operation; decline cancels and changes nothing).
- **Editors**: `sbxenv` opens the editor (explicit argument, then `VISUAL`, `EDITOR`, `micro`, `nano`, `vim`, or `vi`) on the project env file without clobbering existing contents; `sbxwt commit SANDBOX` without `-m` opens the editor for the commit message.
- **Shell completions**: extract the release archive into a temporary directory and test against the extracted artifact. Zsh: in a fresh interactive `zsh`, source the extracted `sandshell.sh`, add the extracted `completions` directory to `fpath` BEFORE `compinit`, run `compinit`, and press TAB for `sbxc -a ` and `sbxr `; also verify the already-initialized case (run `compinit` first, add to `fpath`, re-run `compinit` once). Bash: source the extracted `sandshell.sh` and `completions/sandshell.bash`, and press TAB for `sbxc -a ` and `sbxr `. The automated suite covers loading, discovery, and candidate generation only (`tests/test_completion_bash.sh`, `tests/test_completion_zsh.sh`, `tests/test_release_completion.sh`); pressing TAB in a real shell is manual.
- **Worktrees**: in a disposable Git repo, `sbxwt create feat/test -a codex`, make a small agent edit, then `sbxwt commit SANDBOX -m "Test worktree workflow"`, `sbxwt merge SANDBOX`, `sbxwt done SANDBOX` — verify the branch survives, the worktree and sandbox are removed, sandshell tracking state is removed, and the merged change exists on the target branch. Also confirm the unmerged warning on `sbxwt done` and the dirty-worktree refusal.
