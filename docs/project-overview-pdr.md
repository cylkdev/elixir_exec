# Project Overview & Product Definition

## Identity

- **Name:** `elixir_exec`
- **Version:** 0.1.0
- **License:** Apache-2.0
- **Source:** https://github.com/kurtome/elixir_exec
- **Elixir requirement:** `~> 1.18`

## What this is

`elixir_exec` is a thin, idiomatic Elixir wrapper around the Erlang `:erlexec` library. `:erlexec` is the de-facto solution on the BEAM for executing and supervising arbitrary OS processes — it ships a port driver that handles fork/exec, signal delivery, stdin/stdout/stderr plumbing, pty allocation, and exit reporting. It is feature-rich, battle-tested, and deeply Erlang-flavoured.

This library exists to give Elixir callers a more familiar interface to the same capabilities:

| Concern | `:erlexec` shape | `elixir_exec` shape |
|---|---|---|
| Options | Erlang proplists, charlist values | Keyword lists with NimbleOptions validation, binary values |
| Return values | Tagged tuples with raw types | Structs (`%OSProcess{}`, `%Output{}`) |
| Streaming output | None — caller wires up message handling | `Stream.unfold/2`-backed `Enumerable` |
| Sync runs | Proplist of `{:stdout, [chunk]}` | `%Output{stdout: [...], stderr: [...]}` |
| Errors | Mix of returns and exits | NimbleOptions errors + tagged `{:error, _}` |

## Why it exists

1. **Reduce friction for Elixir callers.** Erlang interop is fine, but converting binaries↔charlists, building proplists, and wiring up a custom GenServer for streaming output is repetitive boilerplate that should live in one place.
2. **Validate options before dispatch.** Misconfigurations should surface as a `{:error, %NimbleOptions.ValidationError{}}` *before* a process is forked, not as a confusing runtime failure halfway through.
3. **First-class streaming.** Reading a long-running command's output via `Enum`/`Stream` should be a one-liner, not a hand-rolled GenServer.
4. **Stay close to `:erlexec`.** The library deliberately mirrors `:erlexec`'s feature set rather than abstracting over it. If `:erlexec` supports a feature, this library should expose it.

## Scope

In scope:

- Wrap `:erlexec`'s command-launching surface (`run`, `run_link`, `manage`).
- Wrap `:erlexec`'s control surface (`stop`, `kill`, `write_stdin`, `set_gid`, `winsz`, `pty_opts`).
- Wrap `:erlexec`'s informational surface (`which_children`, `status`, `signal`, `os_pid`, `pid`).
- Provide a streaming abstraction on top of monitored runs (`stream/2`).
- Provide receive helpers (`receive_output/2`, `await_exit/2`) for the asynchronous message protocol.
- Validate every accepted option via NimbleOptions and reject illegal combinations explicitly.

Out of scope:

- **No `:exec` start-time configuration management.** `:erlexec` supports configuring the global `:exec` server (root, capabilities, alarm, etc.). The schema (`ElixirExec.Options.@exec_schema`) and translator are present, but `validate_exec/1` is currently a building block for callers who manage their own `:exec` start, not a turnkey API.
- **No supervision of OS processes themselves.** The dynamic supervisor in this library supervises `Stream` workers — Elixir-side buffers — not the OS processes. `:erlexec`'s own port driver owns those.
- **No new control primitives.** Anything `:erlexec` cannot do is not added here.
- **No retries, timeouts beyond what `:erlexec` exposes, or higher-level pool/queue abstractions.**

## Non-goals

- Replacing `System.cmd/3` for trivial blocking calls — for a one-shot synchronous run with no advanced needs, `System.cmd/3` is simpler.
- Cross-platform abstractions beyond what `:erlexec` provides.
- Becoming a generic process pool. Callers compose their own pooling on top.

## Project state

- 9 modules in `lib/`; 9 test files exercising the public API end-to-end with real OS processes (no mocks for the integration surface).
- Strict static analysis: Credo with `BlitzCredoChecks`, Dialyzer with `:unmatched_returns` and `:no_improper_lists`, ExCoveralls for coverage.
- Hex package metadata (description, license, package files) is set up and ready, with the caveat that the `LICENSE` file referenced in `mix.exs` is not yet committed.
- ExDoc configuration is in place; `mix docs` produces HTML output in `doc/`.
- No CI workflow files are committed yet (`.github/workflows/`, `.gitlab-ci.yml`, etc.).

## See also

- [`system-architecture.md`](system-architecture.md) — supervision tree and process lifecycles.
- [`api-reference.md`](api-reference.md) — full public API catalog.
- [`configuration-guide.md`](configuration-guide.md) — option-by-option reference.
