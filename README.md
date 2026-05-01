# elixir_exec

An idiomatic Elixir wrapper for [`erlexec`](https://hex.pm/packages/erlexec) — execute and control OS processes from Elixir.

`elixir_exec` lets you launch external programs from your application and work with what they produce. You can wait for a command to finish and read what it printed, start it in the background and get a handle for talking to it later, read its output one line at a time as it runs, or send it input on stdin, signal it, and stop it.

The heavy lifting is done by `:erlexec`. This library wraps it so callers get a more Elixir-friendly experience: keyword options validated up-front, structs like `%ElixirExec.Output{}` and `%ElixirExec.OSProcess{}`, and `Stream`-based output iteration.

## Installation

Add `:elixir_exec` to your `mix.exs`:

```elixir
def deps do
  [
    {:elixir_exec, "~> 0.1.0"}
  ]
end
```

The library starts an OTP application (`ElixirExec.Application`) that supervises stream workers — no further setup required.

**Requirements:** Elixir `~> 1.18`. `:erlexec` builds a small port-driver binary on `mix deps.compile`, so a working C toolchain (`cc`, `make`) must be present.

## Quick start

### Run a command and capture its output

```elixir
iex> {:ok, %ElixirExec.Output{stdout: ["hi\n"], stderr: []}} =
...>   ElixirExec.run("echo hi", sync: true, stdout: true)
```

### Run a command in the background and read messages from your mailbox

```elixir
iex> {:ok, %ElixirExec.OSProcess{os_pid: os_pid}} =
...>   ElixirExec.run("echo hi", monitor: true, stdout: true)
iex> {:stdout, "hi\n"} = ElixirExec.receive_output(os_pid)
iex> {:exit, 0} = ElixirExec.receive_output(os_pid)
```

### Stream a command's stdout line by line

```elixir
iex> {:ok, %ElixirExec.OSProcess{stream: stream}} =
...>   ElixirExec.stream("for i in 1 2 3; do echo Iter$i; done")
iex> Enum.to_list(stream)
["Iter1\n", "Iter2\n", "Iter3\n"]
```

### Send input on stdin

```elixir
{:ok, %ElixirExec.OSProcess{controller: cat_pid, os_pid: cat_os_pid}} =
  ElixirExec.run_link("cat", stdin: true, stdout: true)

:ok = ElixirExec.write_stdin(cat_pid, "hi\n")
{:stdout, "hi\n"} = ElixirExec.receive_output(cat_os_pid)

:ok = ElixirExec.write_stdin(cat_pid, :eof)
```

### Stop a running command

```elixir
{:ok, %ElixirExec.OSProcess{controller: pid}} =
  ElixirExec.run("sleep 10", monitor: true)

:ok = ElixirExec.stop(pid)
# Or send a specific signal:
# :ok = ElixirExec.kill(os_pid, :sigkill)
```

## What you can do

| Function | Purpose |
|---|---|
| `ElixirExec.run/2` | Start a command. `sync: true` waits and captures output; otherwise it runs in the background. |
| `ElixirExec.run_link/2` | Same as `run/2` but links the caller to the controller pid. |
| `ElixirExec.stream/2` | Start a command and consume its output as a line-by-line `Enumerable`. |
| `ElixirExec.manage/2` | Adopt an externally-started OS process so it can be controlled via the same API. |
| `ElixirExec.stop/1`, `stop_and_wait/2`, `kill/2` | End a running command. |
| `ElixirExec.write_stdin/2` | Send data to the command's stdin (or `:eof` to close it). |
| `ElixirExec.receive_output/2`, `await_exit/2` | Pull stdout/stderr/exit messages from your mailbox after a background start. |
| `ElixirExec.os_pid/1`, `pid/1` | Round-trip between an Elixir controller pid and the OS pid. |
| `ElixirExec.which_children/0` | List every OS pid currently managed by `:erlexec`. |
| `ElixirExec.status/1`, `signal/1`, `signal_to_int/1` | Decode wait-style exit codes and signal names. |
| `ElixirExec.winsz/3`, `pty_opts/2` | Resize the pty or update pty settings of a pty-attached command. |

The full surface is documented in [`docs/api-reference.md`](docs/api-reference.md) and inline `@doc` for each function.

## Documentation

| Doc | Purpose |
|---|---|
| [`docs/project-overview-pdr.md`](docs/project-overview-pdr.md) | Why this library exists, scope, and non-goals. |
| [`docs/system-architecture.md`](docs/system-architecture.md) | Supervision tree, process lifecycles, streaming model, Mermaid diagrams. |
| [`docs/api-reference.md`](docs/api-reference.md) | Catalog of every public function with signature, returns, and examples. |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | Every option accepted by `run/2`, `stream/2`, and `manage/2`. |
| [`docs/codebase-summary.md`](docs/codebase-summary.md) | Module inventory and dependency table. |
| [`docs/code-standards.md`](docs/code-standards.md) | Conventions distilled from `RULES.md` and the Credo configuration. |
| [`docs/testing-guide.md`](docs/testing-guide.md) | How to run tests, the canonical test shapes, and coverage. |
| [`docs/changelog.md`](docs/changelog.md) | Release notes. |

`CLAUDE.md` and `RULES.md` define how Claude Code agents collaborate on this repository — read them before starting a task here.

## License

Apache-2.0 (declared in `mix.exs` package metadata).

> ⚠ A `LICENSE` file is referenced by `mix.exs` (`files: ~w(lib mix.exs README.md LICENSE .formatter.exs)`) but is not yet committed to the repository. Add one before publishing to Hex — `mix hex.build` will fail otherwise.
