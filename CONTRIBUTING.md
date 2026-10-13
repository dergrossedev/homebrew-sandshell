# Contributing to sandshell

- Make small, focused changes.
- Use TDD where practical: add a focused test that expresses the intended behavior, confirm it fails, then make the smallest change that passes. For bug fixes, add a regression test first.
- Edit the source under `src/`; `sandshell.sh` is generated — regenerate it with `./scripts/build.sh`, never edit it by hand.
- Run the quality gate before opening a pull request:

  ```sh
  ./scripts/check.sh
  ```

Ground rules:

- Preserve host safety: no automatic deletion of host files, Git branches, or sandbox state without explicit user confirmation.
- Keep runtime dependencies minimal (`sbx` and `git` only) and keep Bash and Zsh compatibility; the test suite runs under both.
- Tests must mock `sbx` and use temporary directories and Git repositories — never touch real Docker state, the real `$HOME` configuration, or real repositories.
