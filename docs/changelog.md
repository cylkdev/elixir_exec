# Changelog

All notable changes to `elixir_exec` are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No changes yet.

## [0.1.0] — initial public release

First release of `elixir_exec`. The Hex package metadata in `mix.exs` declares this version; no commits have been made on the repository yet, so the changelog starts here.

### Added

- Public API surface in `ElixirExec` (`lib/elixir_exec.ex`):
  - Command launchers: `run/2`, `run_link/2`, `stream/2`, `manage/2`.
  - Lifecycle control: `stop/1`, `stop_and_wait/2`, `kill/2`, `write_stdin/2`, `set_gid/2`.
  - Pty handling: `winsz/3`, `pty_opts/2`.
  - Identity round-trips: `os_pid/1`, `pid/1`, `which_children/0`.
  - Decoders: `status/1`, `signal/1`, `signal_to_int/1`.
  - Mailbox helpers: `receive_output/2`, `await_exit/2`.
- Result structs: `%ElixirExec.OSProcess{}` (async) and `%ElixirExec.Output{}` (sync).
- Two-stage option validation (`ElixirExec.Options`): NimbleOptions schema + cross-key illegal-combination checks. Currently rejects `sync: true` with `stdout: :stream` as `{:illegal_combination, :sync_with_stream}`.
- Streaming subsystem:
  - `ElixirExec.StreamSupervisor` — `DynamicSupervisor` (`:one_for_one`, `:temporary` children).
  - `ElixirExec.Stream` — GenServer worker with race-free `attach/2`, parking semantics, and clean `:DOWN`-driven shutdown.
  - `ElixirExec.Stream.Buffer` — pure data type with `:lines`, `:chunks`, `:stderr`, and `:merged` modes.
- Test suite covering the public API end-to-end with real OS processes, plus pure-module unit tests for `Options`, `Output`, `OSProcess`, and `Buffer`. Doctests on `ElixirExec`, `Output`, and `Buffer`.
- Tooling configuration: ExCoveralls (HTML/LCOV/JSON), Codecov gates, Dialyzer with `:unmatched_returns` + `:no_improper_lists`, Credo `strict: true` with `BlitzCredoChecks` pack, ExDoc with `ElixirExec` as the main module.
- Project documentation under `docs/`:
  - `project-overview-pdr.md`, `system-architecture.md`, `api-reference.md`, `configuration-guide.md`, `code-standards.md`, `testing-guide.md`, `codebase-summary.md`, `changelog.md`.

### Known issues at release time

- `LICENSE` is referenced in `mix.exs` package files (`files: ~w(lib mix.exs README.md LICENSE .formatter.exs)`) but is not yet committed. `mix hex.publish` will fail until a `LICENSE` file is added.
- No CI workflow files committed (`.github/workflows/`, `.gitlab-ci.yml`, etc.). The `coveralls.json` and `codecov.yml` configurations are ready to plug in.
