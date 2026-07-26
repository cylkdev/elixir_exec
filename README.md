# elixir_exec

An idiomatic Elixir wrapper for [`erlexec`](https://hex.pm/packages/erlexec) — execute and control OS processes from Elixir.

`elixir_exec` lets you launch external programs from your application and work with what they produce.

The heavy lifting is done by `:erlexec`. This library wraps it so callers get a more Elixir-friendly experience.

> **Rebuild in progress.** `elixir_exec` is being rebuilt from scratch, one
> slice at a time. Three public entry points exist: `ElixirExec.capture/2` (run
> a command to completion and get back what it printed), `ElixirExec.stream/3`
> (consume its output lazily), and `ElixirExec.run/2` (start it and keep a
> handle, controlled with `stop/1`, `kill/2`, `write_stdin/2` and
> `await_exit/2`). A program never outlives the process that started it, for
> all three. Adopting an externally-started process is not available in this
> version — it will return in a later slice.

## Installation

Add `:elixir_exec` to your `mix.exs`:

```elixir
def deps do
  [
    {:elixir_exec, "~> 0.1.0"}
  ]
end
```

`:erlexec` starts itself and supervises its own `exec` port. For a normal Mix project no further setup is required.

**Requirements:** Elixir `~> 1.18`. `:erlexec` builds a small port-driver binary on `mix deps.compile`, so a working C toolchain (`cc`, `make`) must be present.

## Configuration

`elixir_exec` has no configuration of its own. `:erlexec` starts itself and reads
its own start options, so configure it directly — every key is optional:

```elixir
config :erlexec,
  # Allow spawning child processes as root. Default: false. Prefer the
  # non-root user tooling below over enabling this.
  root: false,
  user: "elixir_exec",
  limit_users: ["elixir_exec"],
  verbose: false,
  alarm: 12,
  # Absolute path to erlexec's exec-port binary. When unset, erlexec locates
  # it in its own priv/ dir, which is correct for plain Mix projects.
  portexe: "/opt/myapp/bin/exec-port"
```

See [erlexec's documentation](https://hexdocs.pm/erlexec/exec.html) for the full
list — `elixir_exec` neither filters nor validates these.

## Running child commands as a non-root user

erlexec refuses to spawn processes as root unless started with `root: true`.
Rather than enabling that, create a dedicated unprivileged user and have child
commands drop to it:

```sh
mix elixir_exec.setup_user                       # creates the "elixir_exec" system user
mix elixir_exec.setup_user --username myapp_exec # or a custom name/group
```

Then run commands as that user, per call:

```elixir
ElixirExec.capture("whoami", user: "elixir_exec")
```

or restrict at the exec level in config: `config :erlexec, limit_users: ["elixir_exec"]`.

## Quick start

### Run a command and capture its output

```elixir
iex> ElixirExec.capture("echo hi")
{:ok, %ElixirExec.Output{stdout: ["hi\n"], stderr: [], exit_status: 0}}
```

A non-zero exit is a normal outcome, not an error — the command still ran, so you get `{:ok, %ElixirExec.Output{}}` back with the exit code inside:

```elixir
iex> {:ok, output} = ElixirExec.capture("exit 3")
iex> output.exit_status
3
```

`command` can also be given as a list, in which case it is passed directly to `execve` with no shell involved. A bare executable name is still resolved against `PATH`:

```elixir
iex> ElixirExec.capture(["echo", "hi"])
{:ok, %ElixirExec.Output{stdout: ["hi\n"], stderr: [], exit_status: 0}}
```

`{:error, reason}` is returned only when the command could not be run at all — for example an empty command, or an option erlexec rejects. `options` are passed through to erlexec untouched.

### Stream a command's output

For long-running or large-output commands, consume the output lazily instead of
buffering it all. Every event is also handed to a handler — a pid is sent the
event, a function is called with it:

```elixir
"printf 'a\nb\n'"
|> ElixirExec.stream(self())
|> Enum.to_list()
#=> [{:stdout, "a\n"}, {:stdout, "b\n"}, {:exit_status, 0}]
```

Elements are `{:stdout, line}`, `{:stderr, line}`, and a final
`{:exit_status, status}`. Lines keep their delimiter. stdout and stderr are each
in order, but not ordered relative to each other.

Stopping early kills the program and emits no `{:exit_status, _}` — so its
absence tells you the stream was cut short rather than finished:

```elixir
"tail -f /var/log/system.log"
|> ElixirExec.stream(&Logger.info/1)
|> Stream.filter(&match?({:stdout, _}, &1))
|> Enum.take(5)
```

The stream receives into whichever process iterates it, so iterate it in one
process only. There is no backpressure: output arrives as fast as the program
writes it, so a slow consumer's mailbox grows.

### Start a command and control it

When you want to keep hold of a program rather than wait for it:

```elixir
{:ok, %ElixirExec.Handle{os_pid: os_pid} = handle} =
  ElixirExec.run("tail -f /var/log/system.log", [:stdout])

receive do
  {:stdout, ^os_pid, data} -> IO.write(data)
end

ElixirExec.stop(handle)
```

Output is erlexec's own message, keyed on `os_pid`. For line-split, tagged
events use `stream/3` instead.

To learn how the program ended, use `await_exit/2` — it returns the exit code
as an integer, or `{:signal, name}` when a signal killed it. Completion is also
a standard `Process.monitor/1` DOWN on the handle's `ref` if you would rather
receive it yourself, but then the reason is erlexec's raw term, where `exit 3`
reads as `{:exit_status, 768}` rather than `3`.

The handle also works with `kill/2`, `write_stdin/2` and `await_exit/2`:

```elixir
{:ok, handle} = ElixirExec.run("cat", [:stdin, :stdout])
ElixirExec.write_stdin(handle, "hello\n")
ElixirExec.write_stdin(handle, :eof)
{:ok, 0} = ElixirExec.await_exit(handle, 5_000)
```

`stop/1` sends `SIGTERM`, escalating to `SIGKILL` only after erlexec's kill
timeout (about 5 seconds by default). `kill/2` is immediate — no escalation.
`write_stdin/2` requires the program to have been started with `:stdin`;
without it, erlexec returns `:ok` and the data goes nowhere.

### Process lifetime

**A program never outlives the process that started it** — for `capture/2`,
`stream/3` and `run/2` alike. If that process dies, including a brutal kill,
the program is stopped.

The reverse does not hold: a program exiting non-zero never disturbs you.
`capture/2` reports it in `exit_status`, `stream/3` as a final
`{:exit_status, status}` element, and `run/2` through `await_exit/2`.

This guarantee survives a crash of the library's internal Guardian process:
the record of which owner holds which program lives in an ETS table owned by
a separate, minimal process, so a Guardian restart rebuilds its monitors from
that table instead of silently dropping every live contract. It does not
survive a crash of that table-owning process itself: the table (and every
row in it) dies with it, and the Guardian restarts onto a fresh, empty table
with no way to recover what was lost. Nor does it survive the VM going down.

## What you can do

| Function | Purpose |
|---|---|
| `ElixirExec.capture/2` | Run a command to completion and capture what it printed. |
| `ElixirExec.stream/3` | Run a command and consume its output lazily, line by line. |
| `ElixirExec.run/2` | Start a command and keep a handle to control it. |
| `ElixirExec.stop/1`, `kill/2` | End a running command. |
| `ElixirExec.write_stdin/2` | Send data to a running command's standard input. |
| `ElixirExec.await_exit/2` | Wait for a running command and get its exit status. |

Adopting an externally-started process is planned for a later slice and is not part of this version's API.

## Documentation

The design spec and implementation plan for the current rebuild slice live in
`docs/superpowers/`. Function-level documentation is in the `@doc` attributes and on
[HexDocs](https://hexdocs.pm/elixir_exec).

## License

Apache-2.0 (declared in `mix.exs` package metadata).

> ⚠ A `LICENSE` file is referenced by `mix.exs` (`files: ~w(lib mix.exs README.md LICENSE .formatter.exs)`) but is not yet committed to the repository. Add one before publishing to Hex — `mix hex.build` will fail otherwise.
