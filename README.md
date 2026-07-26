# elixir_exec

An idiomatic Elixir wrapper for [`erlexec`](https://hex.pm/packages/erlexec) — execute and control OS processes from Elixir.

`elixir_exec` lets you launch external programs from your application and work with what they produce. The heavy lifting is done by `:erlexec`; this library wraps it so callers get a more Elixir-friendly experience: a plain pid to hold, blocking reads instead of raw mailbox messages, and a lifetime guarantee.

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

## The API

| Function | Purpose |
|---|---|
| `ElixirExec.capture/2` | Run a command to completion and capture what it printed. |
| `ElixirExec.stream/2` | Run a command and consume its output lazily, line by line. |
| `ElixirExec.run/2` | Start a command and keep a handle to control it. |
| `ElixirExec.read/2` | Read the next thing a running command produced. |
| `ElixirExec.write/2` | Send data (or `:eof`) to a running command's standard input. |
| `ElixirExec.stop/1` | End a command gently — `SIGTERM`, escalating to `SIGKILL`. |
| `ElixirExec.kill/2` | Send one signal now, no escalation. |

`ElixirExec.Output` is the struct `capture/2` returns — `:stdout`, `:stderr` and `:exit_status`. `mix elixir_exec.setup_user` is a one-off deploy-host task, covered below.

`capture/2` and `stream/2` are both written in terms of `run/2` + `read/2`; reach for `run/2` when neither shape fits.

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

`timeout: ms` bounds the whole call, not the gap between chunks, so a program that prints continuously still times out. On expiry the program is stopped and `{:error, :timeout}` is returned:

```elixir
iex> ElixirExec.capture("sleep 30", timeout: 200)
{:error, :timeout}
```

`{:error, reason}` otherwise means the command could not be started at all — an empty command, say, or an option erlexec rejects.

### Stream a command's output

For long-running or large-output commands, consume the output lazily instead of buffering it all:

```elixir
"printf 'a\nb\n'"
|> ElixirExec.stream()
|> Enum.to_list()
#=> [{:stdout, "a\n"}, {:stdout, "b\n"}, {:exit_status, 0}]
```

Elements are `{:stdout, line}`, `{:stderr, line}`, and a final `{:exit_status, status}`. Lines keep their delimiter. stdout and stderr are each in order, but not ordered relative to each other.

Nothing runs until iteration begins, so a stream that is never consumed never starts a process.

Stopping early — `Enum.take/2`, a `reduce_while` halt, an exception — stops the program and emits no `{:exit_status, _}`. Its absence is meaningful: it distinguishes "I stopped reading" from "it finished".

```elixir
"tail -f /var/log/system.log"
|> ElixirExec.stream()
|> Stream.filter(&match?({:stdout, _}, &1))
|> Enum.take(5)
```

Unlike `capture/2` and `run/2`, `stream/2` **raises** when the command cannot be started — a lazy stream has no `{:error, _}` channel to put it in.

### Start a command and control it

`run/2` returns a pid you pass back to the other functions. Output is held for you until you ask for it, so nothing lands in your mailbox and nothing is lost between reads:

```elixir
{:ok, conn} = ElixirExec.run("cat")

ElixirExec.write(conn, "hello\n")
{:ok, {:stdout, "hello\n"}} = ElixirExec.read(conn)

ElixirExec.write(conn, :eof)
{:ok, {:exit, 0}} = ElixirExec.read(conn)
```

`read/2` blocks until there is something to read, or until its timeout (default `:infinity`) passes:

```elixir
{:error, :timeout} = ElixirExec.read(conn, 0)
```

`{:ok, {:exit, status}}` is the last thing a program produces. The connection ends with it, so reading past it is an error — there is nothing left to read from.

```elixir
{:ok, conn} = ElixirExec.run("tail -f /var/log/system.log")
{:ok, {:stdout, line}} = ElixirExec.read(conn)
ElixirExec.stop(conn)
```

`stop/1` sends `SIGTERM` and escalates to `SIGKILL` after about five seconds, so a program that ignores `SIGTERM` can take that long to die. `kill(conn, :sigkill)` — or `kill(conn, 9)` — is immediate.

### Command form

A command is either a string or a list of strings:

```elixir
ElixirExec.capture("ls -l | wc -l")   # parsed by a shell: PATH, pipes, redirection
ElixirExec.capture(["echo", "hi"])    # passed to execve directly, no shell
```

In list form a bare executable name (no `/`) is resolved against `PATH` first, so `["echo", "hi"]` works the same as `"echo hi"`. A name containing `/` is used exactly as given, and an unresolvable bare name is left alone so you see the real failure.

### Process lifetime

**A program never outlives the process that started it** — for `capture/2`, `stream/2` and `run/2` alike. If that process dies, including a brutal kill, the program is stopped.

The reverse does not hold: the owner is held by a monitor, never a link, so a program failing or exiting non-zero never disturbs the process that started it.

```elixir
spawn(fn -> {:ok, _} = ElixirExec.run("sleep 3600") end)
# that process exits immediately, and `sleep 3600` is killed with it.
```

The guarantee does not survive the VM going down.

Pass `owner: pid` to `run/2` to tie the program's lifetime to some process other than the caller.

## Options

Options are a keyword list. `:timeout` is read by `capture/2` and `:owner` by `run/2`; the rest are forwarded to `:exec.run/2` unchanged:

`:executable`, `:cd`, `:env`, `:kill`, `:kill_timeout`, `:group`, `:user`, `:nice`, `:success_exit_code`, `:winsz`, `:pty`, `:capabilities`, `:debug`.

See [erlexec's documentation](https://hexdocs.pm/erlexec/exec.html) for what each means — `elixir_exec` neither filters nor validates them.

Separately, `stdin: false`, `stdout: false` and `stderr: false` disconnect that stream from the program. All three default to `true`, so `write/2` has somewhere to go and output is queued for `read/2` without you asking. Disconnecting stdout and stderr means no output is delivered at all — `read/2` will only ever return the final `{:exit, status}`.

## Configuration

`elixir_exec` has no configuration of its own. `:erlexec` starts itself and reads its own start options, so configure it directly — every key is optional:

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

## Running child commands as a non-root user

erlexec refuses to spawn processes as root unless started with `root: true`. Rather than enabling that, create a dedicated unprivileged user and have child commands drop to it:

```sh
mix elixir_exec.setup_user                       # creates the "elixir_exec" system user
mix elixir_exec.setup_user --username myapp_exec # or a custom name/group
```

Then run commands as that user, per call:

```elixir
ElixirExec.capture("whoami", user: "elixir_exec")
```

or restrict at the exec level: `config :erlexec, limit_users: ["elixir_exec"]`.

## Architecture

Two public modules, two private ones, and a Mix task:

* `ElixirExec` — the API above. Stateless; every function delegates to a connection process.
* `ElixirExec.Output` — the struct `capture/2` returns. Data only, no behaviour.
* **ElixirExec.Connection** (private) — one GenServer per running program. It calls `:exec.run/2`, queues the program's output until `read/2` asks for it, monitors the owner, and links erlexec's controller so the OS process is reaped however this process dies — including a brutal kill, which leaves no code to run.
* **ElixirExec.ConnectionSupervisor** (private) — a `DynamicSupervisor` that owns those connections. Children are `:temporary`: a program that ends has ended, and restarting it would run the command a second time. The supervisor exists to own them and take them down with the VM, not to bring them back.
* **Mix.Tasks.ElixirExec.SetupUser** — `mix elixir_exec.setup_user`, a thin wrapper over `priv/scripts/setup-erlexec-user.sh`. Deploy-host tooling, not part of the runtime.

**ElixirExec.Application** (private) starts the connection supervisor and does nothing else.

`:erlexec` is an ordinary dependency. It starts, configures and supervises its own `exec` singleton; `elixir_exec` does not start or wrap it.

## Development

```sh
mix deps.get
mix test              # ExUnit
mix credo --strict    # linting
mix dialyzer          # type checking
mix coveralls         # coverage
mix docs              # HexDocs output
```

## Documentation

Function-level documentation lives in the `@doc` attributes and on [HexDocs](https://hexdocs.pm/elixir_exec).

## License

Apache-2.0 (declared in `mix.exs` package metadata).

> ⚠ A `LICENSE` file is referenced by `mix.exs` (`files: ~w(lib priv mix.exs README.md LICENSE .formatter.exs)`) but is not yet committed to the repository. Add one before publishing to Hex — `mix hex.build` will fail otherwise.
