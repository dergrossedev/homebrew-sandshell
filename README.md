# sandshell

Small Bash/Zsh helpers for Docker Sandboxes (`sbx`). Create and resume agent sandboxes, select MCP servers and skills per sandbox, and use Git worktrees for parallel tasks.

sandshell is an independent project, not an official Docker product.

## Install

Requires the Docker Sandboxes CLI (`sbx`), Git, and Bash or Zsh.

```sh
brew install dergrossedev/sandshell/sandshell
source "$(brew --prefix sandshell)/libexec/sandshell.sh"
```

Add the `source` line to `~/.zshrc` or `~/.bashrc`.

Homebrew installs the completion files in its standard directories. They load through your shell's normal completion setup (`compinit` for Zsh or `bash-completion` for Bash). Restart your shell after installation.


## Manual installation

```sh
git clone https://github.com/dergrossedev/homebrew-sandshell.git ~/.local/share/sandshell
source "$HOME/.local/share/sandshell/sandshell.sh"
```

Add the `source` line to `~/.zshrc` or `~/.bashrc`.

For manual installs only:

Zsh — Add the completions directory to `fpath` before Zsh initializes completion with your normal `compinit`:

```sh
fpath=("$HOME/.local/share/sandshell/completions" $fpath)
```

If `compinit` already ran, re-run `compinit` once after adding the directory. sandshell never runs `compinit` itself.

Bash — add this to `~/.bashrc`:

```sh
source "$HOME/.local/share/sandshell/completions/sandshell.bash"
```

## Quick start

From your project directory:

```sh
sbxc             # create an OpenCode sandbox; does not launch the agent
sbxr             # list this project's sandboxes
sbxr SANDBOX     # resume using a name from the listing
```

To choose another agent:

```sh
sbxc -a claude
sbxc -a opencode-ollama
```

## Commands

| Command | Purpose |
| --- | --- |
| `sbxc` | Create a sandbox without launching the agent |
| `sbxr` | List project/repository sandboxes or resume one |
| `sbxenv` | Edit the current project's environment file |
| `sbxmcp` | List, attach, or copy MCP servers per sandbox |
| `sbxskill` | Manage isolated skills per sandbox |
| `sbxwt` | Create and manage host Git worktree sandboxes |
| `sbxcmd` | List the sandshell helper commands |

Run `<command> --help` for details.

## Agents

Choose with `sbxc -a` or `sbxwt create -a`: `claude`, `codex`, `opencode` (default), `vibe`, `claude-ollama`, or `opencode-ollama`.

`opencode` is the provider-neutral, general-purpose choice. The Ollama presets require Ollama running locally with the model already installed. `opencode-ollama` defaults to `qwen3.5:4b-mlx`; sandshell never downloads models.

Vibe uses the [bundled preset](examples/vibe.toml) (Mistral Large 4) unless you provide `<config-root>/agents/vibe.toml`. Your configuration is synchronized on create and resume. Mistral's "Vibe Code Clients managed config" takes precedence over both; sandshell does not try to override or detect it. Use Vibe's `/reload` to refresh an active session.

## Configuration

The configuration root is `SANDSHELL_CONFIG_HOME` when set and nonempty, otherwise `$XDG_CONFIG_HOME/sandshell`, falling back to `~/.config/sandshell`.

Use `sbxenv` to edit the current project's environment file. It lives outside the project and is applied automatically on create and resume. Prefer `sbx secret` for secrets; environment files are plain `KEY=value` files.

## Worktrees

Give each parallel task its own branch, host Git worktree, and sandbox:

```sh
sbxwt create feat/api -a codex
```

Worktrees live next to the repository under `<repository>.worktrees/<branch-slug>`. `sbxwt done` removes the sandbox and clean worktree after confirmation, preserving the branch. See `sbxwt --help` for committing and merging.

## MCP and skills

Select sbx registered MCP servers and catalog skills per sandbox:

```sh
sbxmcp add SANDBOX playwright
sbxskill add SANDBOX testing
```

New sandboxes start without skills. After skill changes, start a new agent session; Vibe also supports `/reload`.

## Safety

- Direct workspace access lets agents modify host files. Worktrees isolate parallel changes, but their files are also writable from the sandbox.
- Local/stdio MCP servers may execute host commands and require explicit approval before loading.
- Destructive or high-impact helper operations require confirmation. sandshell never deletes Git branches automatically.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.

## License

MIT — see [LICENSE](LICENSE).
