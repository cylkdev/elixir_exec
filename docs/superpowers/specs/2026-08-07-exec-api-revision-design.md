# Exec API Revision — Design

**Date:** 2026-08-07
**Status:** Approved, ready for implementation planning

## Problem

The library works, but four things are wrong with its surface:

1. Public function names use terms Elixir's stdlib does not (`capture`), and `run/2`
   — the most obvious name — is spent on the least common operation.
2. Private function names state a role rather than a behaviour (`collect`, `record`,
   `flush`).
3. The abstraction leaks erlexec details: raw pipe chunks, raw error reasons, an
   undocumented option passthrough, and two different tags for the same exit event.
4. Documentation is written in conversational second person and spends its space on
   why the library is built the way it is, rather than on how to use it.

Breaking changes are in scope. The library is pre-release.

## Reference material

`lib/elixir/lib/system.ex` and `lib/elixir/lib/stream.ex` from elixir-lang/elixir, for
naming and documentation voice.

## Part 1 — Public surface

### Module layout

The top-level module becomes `Exec` (`lib/exec.ex`, `lib/exec/*.ex`). Elixir libraries
do not prefix themselves with `Elixir`. There is no collision: Elixir modules are
namespaced `Elixir.Exec`, distinct from Erlang's `:exec`.

The OTP application name and Hex package name stay `:elixir_exec`. The Mix task stays
`mix elixir_exec.setup_user` — it is package-scoped deploy tooling, and a bare
`mix exec` task claims too generic a name.

### Functions

| Function | Returns |
|---|---|
| `Exec.run(command, opts \\ [])` | `{:ok, %Exec.Result{}}` \| `{:error, reason}` |
| `Exec.stream!(command, opts \\ [])` | `Enumerable.t()`; raises on start failure |
| `Exec.open(command, opts \\ [])` | `{:ok, t()}` \| `{:error, reason}` |
| `Exec.read(exec, timeout \\ :infinity)` | `{:ok, event()}` \| `{:error, :timeout}` |
| `Exec.write(exec, iodata() \| :eof)` | `:ok` \| `{:error, reason}` |
| `Exec.stop(exec)` | `:ok` \| `{:error, reason}` |
| `Exec.signal(exec, signal)` | `:ok` \| `{:error, reason}` |

Mapping from the current API:

| Current | New | Why |
|---|---|---|
| `capture/2` | `run/2` | `capture` is not a stdlib term; `run` is the obvious name for the common case |
| `run/2` | `open/2` | Returns a handle; `File.open` → `read`/`write`/`close` is the vocabulary the rest of the API already borrows |
| `stream/2` | `stream!/2` | It raises; Elixir marks that with `!` |
| `kill/2` | `signal/2` | It also sends `SIGHUP` and `SIGUSR1`; `kill` names one outcome, not the behaviour |
| `read/2`, `write/2`, `stop/1` | unchanged | Already idiomatic |

`stop/1` keeps its meaning: `SIGTERM`, escalating to `SIGKILL` after roughly five
seconds. `signal/2` sends one signal with no escalation.

### Types

```elixir
@opaque t :: pid()
@type event :: {:stdout, binary()} | {:stderr, binary()} | {:exit, exit_status()}
@type exit_status :: non_neg_integer() | {:signal, atom() | pos_integer()}
```

`t` replaces `conn`. A module's own handle type is conventionally `t` in Elixir, and
`conn` reads as Plug's.

`exit_status` keeps its two shapes. That is domain information, not an erlexec detail:
collapsing it would lose the distinction between a program that exited `137` and one
that was killed by `SIGKILL`.

### Result struct

`Exec.Output` becomes `Exec.Result`. `Output` was a poor name for a struct whose third
field is an exit code.

```elixir
%Exec.Result{stdout: binary(), stderr: binary(), exit_status: exit_status()}
```

`stdout` and `stderr` become binaries — see Part 2.

### Deliberately out of scope

- **No `run!/2`.** Nothing needs it. `stream!/2` exists only because a lazy stream has
  no `{:error, _}` channel.
- **No `cmd`/`shell` split.** One function dispatching on string-versus-list is the
  library's existing contract and it works.

## Part 2 — Internals and leak fixes

### Private module renames

| Current | New |
|---|---|
| `ElixirExec.Connection` | `Exec.Program` |
| `ElixirExec.ConnectionSupervisor` | `Exec.Supervisor` |
| `ElixirExec.Application` | `Exec.Application` |
| `ElixirExec.ConnectionSupervisor.start_supervised_connection/3` | `Exec.Supervisor.start_program/3` |

"Connection" names a connection to nothing in particular; the documentation already
calls the thing a program. `start_supervised_connection` says where it starts rather
than what it starts.

### Private function renames

In `Exec`:

| Current | New |
|---|---|
| `collect/4` | `read_until_exit/4` |
| `deadline/1` | `deadline_after/1` |
| `time_left/1` | `remaining_timeout/1` |
| `stream_next/1` | `emit_lines/1` |
| `stream_teardown/1` | `stop_unless_exited/1` |
| `split_lines/1` | `split_complete_lines/1` |
| `flush/2` | `trailing_line/2` |
| `normalize_command/1` | `command_to_binaries/1` |
| `resolve_command/1` | `resolve_executable_path/1` |

In `Exec.Program`:

| Current | New |
|---|---|
| `record/2` | `deliver_or_queue/2` |
| `read_timer/1` | `start_read_timer/1` |
| `exec_run_options/1` | `build_exec_options/1` |
| `exit_status/1` | `decode_exit_reason/1` |

`cancel_read_timer/1` is already accurate and stays.

### Leak: chunked output

`Exec.Program` keeps delivering chunks — that is what the OS pipe gives it. `run/2`
accumulates them as iodata and converts once, at exit, so `Result.stdout` and
`Result.stderr` are binaries. This matches what `System.cmd/3` returns. Chunk
boundaries are an artifact the caller never asked about.

Line-splitting remains `stream!/2`'s job and is unaffected.

### Leak: two tags for one event

`stream!/2`'s final element becomes `{:exit, status}`, matching what `read/2` emits.
Its meaning is unchanged: the element is emitted only when the program ends on its
own, and its absence still distinguishes "the consumer halted" from "the program
finished".

### Leak: raw error reasons

`{:error, reason}` currently passes erlexec's internal reasons through untouched,
often as charlists.

Normalize to POSIX atoms (`:enoent`, `:eacces`, and so on) where erlexec hands back a
charlist that maps to one. Anything unrecognised surfaces as `{:exec, term}` — still
matchable, never silently swallowed.

The exact set of reasons erlexec produces must be verified against the library during
implementation. Document only the reasons confirmed by a test. Four documented
reasons that are true beat twelve that are guessed.

### Leak: undocumented option passthrough

Options split into two groups.

**The library's own:**

| Option | Applies to | Default | Meaning |
|---|---|---|---|
| `:timeout` | `run/2` | `:infinity` | Bounds the whole call, not the gap between chunks. On expiry the program is stopped and `{:error, :timeout}` returned. |
| `:owner` | all three | calling process | The process whose death stops the program. |
| `:stdin` | all three | `true` | Connect the program's standard input. |
| `:stdout` | all three | `true` | Connect the program's standard output. |
| `:stderr` | all three | `true` | Connect the program's standard error. |

`:timeout` is `run/2`-only: a lazy stream has no total duration to bound. This
corrects a current asymmetry where `:timeout` was silently ignored elsewhere.

**Forwarded to erlexec:** `:executable`, `:cd`, `:env`, `:kill`, `:kill_timeout`,
`:group`, `:user`, `:nice`, `:success_exit_code`, `:winsz`, `:pty`, `:capabilities`,
`:debug`. Each documented in the library's own words with its type and default,
rather than a link to erlexec's documentation.

An unknown key raises `ArgumentError` rather than being silently dropped. The
precedent is `System.cmd/3`, which raises on bad options.

## Part 3 — Documentation

### Voice

- Third-person indicative throughout. No second person. "Returns `{:ok,
  %Exec.Result{}}`", not "you get one of these back".
- Every `@doc` opens with a one-sentence summary of what the function does.
- Sections in `System`'s order: summary → warning callout → `## Examples` →
  `## Options` → `## Errors`. Sections appear only where they apply.
- Doctests wherever output is deterministic (`echo hi`, `exit 3`), so examples are
  verified rather than asserted.

### Content

Each `@doc` answers usage questions: what the function returns, what it raises, what
the options are, which errors are matchable.

Design rationale — monitor-versus-link, erlexec line references, why supervised
children are `:temporary` — moves out of `@doc` and `@moduledoc` into code comments
(where most of it already lives) and one README "Design notes" section.

The lifetime guarantee stays in the documentation, stated as a fact rather than
argued for: a program never outlives its owner; the reverse does not hold.

### Shell-injection warning

Nothing currently warns that the string command form is parsed by a shell.
`System.cmd/3` and `System.shell/1` both carry a `> #### Watch out {: .warning}` block
about never passing untrusted input. `run/2`, `stream!/2` and `open/2` get the same.

This is the clearest instance of the documentation answering the wrong question: it
explains the implementation at length and never mentions the injection risk.

### README

Restructured to: Installation → Quick start (the three entry points) → Command forms
and shell safety → Options → Lifetime → Running as a non-root user → Design notes →
Development.

The "Architecture" module inventory is removed. It duplicates the code and has already
rotted once (commit `3cef06e` fixed it). The design notes section replaces it with
rationale, which does not rot in the same way.

Add the actual `LICENSE` file (Apache-2.0, as declared in `mix.exs`) rather than leave
the README warning about its absence.

### Tests

- Existing suite migrated to the new names and return shapes.
- New coverage: unknown options raise `ArgumentError`; `Result.stdout`/`stderr` are
  binaries; `stream!/2` emits `{:exit, status}`; normalized error reasons for at least
  a nonexistent executable and a permission failure.
- Doctests wired into the test run.

## Success criteria

- `mix test`, `mix credo --strict`, and `mix dialyzer` pass.
- No `@doc` or `@moduledoc` contains second-person address.
- No public function returns an erlexec-shaped value that is not documented in the
  library's own terms.
- Every documented error reason is covered by a test.
