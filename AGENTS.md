# sandshell agent instructions

## Purpose

sandshell is a small Bash/Zsh helper library for developer and agent sandbox workflows. The backend is Docker Sandboxes (`sbx`); do not add backend abstractions without a concrete implementation task. The existing CLI behavior in `sandshell.sh` is the baseline — preserve it unless the active task explicitly changes it.

## Engineering principles

- Prefer KISS, DRY, and YAGNI. Make narrow changes; do not rewrite working code to satisfy style preferences.
- Use SOLID only where it improves cohesion or testability; do not add abstraction layers for their own sake.
- Favor small cohesive functions and feature-focused source files.
- Prefer native `sbx`, Git, and agent capabilities over custom implementations.
- Do not add runtime dependencies (no `jq`, `fzf`, Python, Node.js, or GNU-only utilities) or compatibility aliases for versions that were never publicly released.
- Keep public commands as shell functions that source cleanly under both Bash and Zsh; quote paths and arguments.
- Preserve useful exit codes and error messages: usage errors return 2; missing required executables return 127.
- Public output is concise, consistent, and script-friendly: no colors, spinners, banners, or interactive menus unless explicitly requested.
- Internal helpers use the `_sandshell_` prefix for new code.

## Test-driven development

Use TDD whenever the behavior is testable at reasonable cost: write a focused test that expresses the intended behavior, confirm it fails, then make the smallest change that passes. For bug fixes, add a regression test first. TDD is not mandatory for documentation-only edits or mechanical refactors with no practical isolated behavior to test. Do not write meaningless tests solely to claim TDD compliance.

## Source and generated artifact

- The public runtime artifact is a single generated `sandshell.sh`; the maintainable source is split under `src/` by responsibility.
- Edit `src/`; never hand-edit generated `sandshell.sh`. `scripts/build.sh` produces it deterministically; keep it readable (no minification) and free of timestamps or machine-specific paths.
- Keep `sandshell.sh` committed; CI/tests verify that rebuilding does not change it.
- Public-behavior tests exercise the generated `sandshell.sh`, because that is what users source.
- Do not create more modules than are justified by current responsibilities.

## Safety invariants

- Never delete, overwrite, force-reset, clean, prune, push, publish, or otherwise destructively modify host state without explicit user intent and appropriate confirmation.
- Never delete a Git branch automatically; never run `git reset --hard`, `git clean`, forced branch deletion, forced push, or equivalent destructive operations.
- Never publish a GitHub repository, Git tag/release, Homebrew tap/formula, package, or remote commit without explicit human approval.
- Do not amend, squash, rebase, force-push, or otherwise modify existing commits or remotes unless explicitly instructed; work only inside this repository.
- Tests must not use the real user's Docker state, `$HOME` configuration, Git repositories, MCP registry, or skills store. Mock `sbx` and use temporary Git repositories.
- Local/stdio MCP servers can execute commands on the host; preserve explicit approval before loading them.
- Prefer `sbx secret` for secrets; never copy secret values into source control, fixtures, logs, or example files.

## Shell compatibility

- The library must source and run under both Bash and Zsh; test Zsh as well as Bash before assuming array indexing, `read` semantics, parameter expansion, or option state.
- Avoid changing global shell options, `IFS`, traps, aliases, or environment state; use local variables and scoped subshells.
- Do not use `eval`.
- Shell completion must fail silently when dynamic data is unavailable and must never create/start/modify sandboxes.

## Dependencies

Runtime dependencies stay minimal: `sbx` for Docker Sandbox operations, `git` for Git/worktree features, and standard shell/core utilities. Optional developer tools such as ShellCheck may be used in CI/tests but must not become runtime requirements.

## Quality checks

For every behavior change: run syntax checks for Bash and Zsh, targeted tests for the changed behavior, then the full suite (`./scripts/test.sh`); rebuild `sandshell.sh` and verify the generated artifact is current (`./scripts/build.sh --check`). `./scripts/check.sh` is the single quality gate; CI runs the same script. Do not weaken tests to make an implementation pass.
