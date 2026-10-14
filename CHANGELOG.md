# Changelog

## [0.1.0] - 14.10.2026

### Added

- `sbxc` creates sandboxes with sensible defaults (agent, size, `--skills off`, generated `sbx-<project>-<agent>-<random>` names); `sbxr` lists or resumes them and never creates a missing sandbox.
- Per-project environment files: `sbxenv` edits `<config-root>/envs/<project>.env`; `sbxc`, `sbxr`, and `sbxwt` apply it automatically (`--env-file` overrides).
- Agents: `claude` (default), `codex`, `opencode`, `vibe`, `claude-ollama`, and `opencode-ollama` (Ollama provider, default model `qwen3.5:4b-mlx`, override with `--model`).
- Bundled Vibe preset (`examples/vibe.toml`, Mistral Large 4 by default), synchronized on create and before every resume; a user config at `<config-root>/agents/vibe.toml` takes priority.
- Per-sandbox MCP management (`sbxmcp`) and per-sandbox skill isolation (`sbxskill`) on top of Docker's host-wide registry and catalog.
- Git worktree workflow (`sbxwt`) for parallel tasks: `create`, `ls`, `commit`, `merge`, `done`.
- Native Bash and Zsh shell completions.
- Single standalone runtime artifact (`sandshell.sh`), macOS and Linux support, and Homebrew-ready packaging (release archive plus generated tap formula).

### Safety

- Interactive confirmation before host-changing operations (a second sandbox on the same workspace, staging all changes, merging, removing a sandbox/worktree, attaching local/stdio MCP servers that run host commands).
- Never deletes Git branches automatically; `sbxwt done` preserves the branch and cleans up the sandbox, worktree, and sandshell tracking state.
- Env files are passed to `sbx` as env files, never sourced; prefer `sbx secret` for secrets.

## [2026.10.0] - 2026-10-14

- OpenCode is now the default agent for `sbxc` and `sbxwt create`
- `sbxenv` now respects editor preference: explicit argument → `VISUAL` → `EDITOR` → micro → nano → vim → vi
- `sbxr` now matches canonical workspace paths, including aliases, trailing slashes, and macOS `/var`/`/private/var` paths
- Homebrew installation and formula support are now available and validated
- Future releases use `YYYY.M.PATCH` calendar versions
