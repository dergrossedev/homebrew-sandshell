# sandshell

Small Bash/Zsh helpers for Docker Sandboxes (`sbx`): sensible defaults, sandbox resume, per-project environment files, per-sandbox MCP/skill selection, and parallel Git-worktree workflows.

sandshell is an independent, pre-1.0 project — not an official Docker product — and its interface may still evolve.

## Install

Prerequisites: the Docker Sandboxes CLI (`sbx`), Git, and Bash or Zsh.

Install from Git:

```sh
git clone https://github.com/dergrossedev/homebrew-sandshell.git ~/.local/share/sandshell
```

Then source the runtime from your shell configuration (`~/.zshrc` or `~/.bashrc`):

```sh
source "$HOME/.local/share/sandshell/sandshell.sh"
```

Or install from the release archive (no Git required):

```sh
mkdir -p ~/.local/share
tar -xzf sandshell-0.1.0.tar.gz -C ~/.local/share
```

The archive unpacks to `sandshell-0.1.0/`; use that directory in place of `sandshell` in the lines below. Update an existing Git installation with `git -C ~/.local/share/sandshell pull --ff-only`.

Homebrew packaging is prepared but not published yet; install from Git or the release archive for now.

### Shell completions

Zsh — Add the completions directory to `fpath` before Zsh initializes completion, so `compinit` discovers `_sandshell`:

```sh
fpath=("$HOME/.local/share/sandshell/completions" $fpath)
```

If your shell framework or `~/.zshrc` already ran `compinit`, re-run `compinit` once in the current shell. sandshell never runs `compinit` itself.

Bash:

```sh
source "$HOME/.local/share/sandshell/completions/sandshell.bash"
```

Completions are read-only: they never create or modify sandboxes and produce no candidates when `sbx` is unavailable.

## Quick start

```sh
sbxc -a codex     # create a sandbox for the current directory
sbxr              # list sandboxes for this project
sbxr SANDBOX      # resume one (use the name from the listing)
```

`SANDBOX` is a generated name such as `sbx-myproject-codex-1a2b3c4d`.

Add optional capabilities per sandbox:

```sh
sbxskill add SANDBOX testing     # give the sandbox a skill
sbxmcp add SANDBOX playwright    # attach an MCP server
```

Run parallel tasks in Git worktrees:

```sh
sbxwt create feat/parser -a claude
sbxr                             # from the repo root: lists all task sandboxes
sbxwt commit SANDBOX -m "Implement parser"
sbxwt merge SANDBOX
sbxwt done SANDBOX
```

## Commands

| Command | Purpose |
| --- | --- |
| `sbxc` | Create a sandbox (does not launch the agent) |
| `sbxr` | List sandboxes for the current project/repository, or resume one |
| `sbxenv` | Edit the current project's environment file |
| `sbxmcp` | Attach or copy MCP servers per sandbox |
| `sbxskill` | Manage isolated skills per sandbox |
| `sbxwt` | Create and manage host Git-worktree sandboxes |
| `sbxcmd` | List the sandshell commands |

Run `<command> --help` for details. Usage errors exit with code 2; a missing `sbx` or `git` exits with 127.

## Agents

`sbxc -a` and `sbxwt create -a` accept:

| Agent | Notes |
| --- | --- |
| `claude` | Default; built-in `sbx` agent |
| `codex` | Built-in `sbx` agent |
| `opencode` | Built-in `sbx` agent; provider-neutral, useful when switching providers or models |
| `vibe` | Docker workload/kit; uses the bundled preset unless overridden (see [Vibe](#vibe)) |
| `claude-ollama` | Claude Code against a local Ollama instance; set the model with `CLAUDE_OLLAMA_MODEL` in the project env file |
| `opencode-ollama` | OpenCode resumed with the Ollama provider; default model `qwen3.5:4b-mlx`, override with `--model` |

Sizes (`-s`): `micro` (default; 2 CPUs, 2 GiB), `small` (2 CPUs, 4 GiB), `medium` (4 CPUs, 8 GiB). The Ollama presets need Ollama installed and running locally with the model already available; sandshell never pulls or installs models.

### Vibe

Vibe configuration precedence, highest first:

1. Mistral managed config — organizations and workspaces can centrally configure Vibe through "Vibe Code Clients managed config". Vibe handles that itself; sandshell does not try to override or detect it.
2. `<config-root>/agents/vibe.toml` — your config, synchronized into the sandbox on create and before every resume.
3. The bundled sandshell preset — [examples/vibe.toml](examples/vibe.toml), Mistral Large 4 by default.

`sbxr` re-synchronizes the active config before launching Vibe, so editing the file and resuming picks up the latest settings; use Vibe's `/reload` to refresh an already-running session. `sbxskill` and `sbxmcp` remain the way to add custom skills and per-sandbox MCP servers.

## Configuration

sandshell keeps all of its state under one configuration root, resolved in this order:

```text
SANDSHELL_CONFIG_HOME
  ↓ (unset or empty)
XDG_CONFIG_HOME/sandshell
  ↓ (XDG_CONFIG_HOME unset)
~/.config/sandshell
```

```text
~/.config/sandshell/
├── agents/
│   └── vibe.toml     # optional Vibe configuration (overrides the bundled preset)
├── envs/             # per-project environment files
├── mcp/              # per-sandbox MCP tracking
├── sandboxes/        # per-sandbox preset metadata (e.g. opencode-ollama)
├── skills/           # per-sandbox skill tracking
└── worktrees/        # managed worktree metadata
```

Each project gets one environment file at `<config-root>/envs/<project>.env`; `sbxenv` is the preferred way to edit it. Env files live outside the project directory, and `sbxc`, `sbxr`, and `sbxwt` apply the project env file automatically; `--env-file FILE` overrides. Env files are plain `KEY=value` files passed to `sbx` — not secure secret storage; prefer `sbx secret` for secrets.

## MCP and skills

Docker's MCP registry and skill catalog are host-wide; sandshell adds a per-sandbox layer on top:

```sh
sbxmcp add SANDBOX playwright
sbxskill add SANDBOX testing frontend-design
```

New sandboxes start with `--skills off`: skills and MCP servers are selected explicitly per sandbox and are never shared accidentally. There is intentionally no per-sandbox MCP `remove` (Docker has no safe unload primitive). Local/stdio MCP servers may execute host commands; sandshell requires explicit approval before attaching one. See `sbxmcp --help` and `sbxskill --help`.

## Worktrees

For parallel agents on one repository, `sbxwt` pairs each task with a branch, a host Git worktree, and a sandbox:

```sh
sbxwt create feat/api -a codex
sbxr                              # from the repo root: lists the repository's sandboxes
sbxwt commit SANDBOX -m "Add API" # stage and commit on the task branch
sbxwt merge SANDBOX               # merge into the recorded base branch
sbxwt done SANDBOX                # remove sandbox and worktree, keep the branch
```

Worktrees are created under `<repository>.worktrees/<branch-slug>` next to the repository. `done` preserves the Git branch, so finished work survives cleanup. In this mode the sandbox edits files in the host worktree directly, and sandshell runs Git operations on the host (the sandbox does not see the parent repository's Git metadata). See `sbxwt --help`.

## Safety

sandshell supports three workspace modes, announced when a sandbox is created:

| Mode | What the agent can do |
| --- | --- |
| Direct | Operates on the mounted host workspace; changes are immediately reflected on the host. |
| Clone (`sbxc --clone`) | Works against a private in-sandbox Git clone. |
| Host worktree (`sbxwt`) | Each agent gets a separate host worktree for a parallel task. |

- Direct and worktree modes expose writable host files to the agent; check what a sandbox can reach before resuming it.
- Destructive or high-impact helper actions — a second sandbox on the same workspace, staging all changes, merging, removing a sandbox or worktree, attaching host-command MCP servers — require confirmation.
- sandshell never deletes Git branches automatically and never runs destructive Git operations (`reset --hard`, `clean`, forced deletion, force-push).

## Development

```sh
./scripts/build.sh              # regenerate sandshell.sh from src/
./scripts/build.sh --check      # verify the committed artifact is current
./scripts/test.sh               # run the test suite (mocked sbx; no Docker needed)
./scripts/check.sh              # full quality gate: syntax, build freshness, ShellCheck, tests
./scripts/package.sh 2026.10.0  # build the release archive under dist/
```

The maintainable source lives in `src/`; the committed `sandshell.sh` is generated and must not be edited by hand. Tests run under both Bash and Zsh and mock `sbx`, so no Docker daemon is required. See [CONTRIBUTING.md](CONTRIBUTING.md) for the contributor workflow.

## License

MIT — see [LICENSE](LICENSE).
