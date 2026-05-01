# Configuration Guide

Every option that `ElixirExec.run/2`, `ElixirExec.run_link/2`, `ElixirExec.stream/2`, and `ElixirExec.manage/2` accept. The schemas are defined in `lib/elixir_exec/options.ex` and validated via [`NimbleOptions`](https://hex.pm/packages/nimble_options) before any process is started.

Two schemas exist:

- **Command options** — applied to a launched/adopted command. Validated by `ElixirExec.Options.validate_command/1`.
- **Exec start options** — applied to the `:exec` GenServer itself. Validated by `ElixirExec.Options.validate_exec/1`. This library does not start `:exec` for you; the schema is exposed so callers who do can validate their own config consistently.

Validation is **strict**: unknown keys are rejected as `{:error, %NimbleOptions.ValidationError{}}` before the program runs. Then a second pass checks for illegal combinations — currently `sync: true` with `stdout: :stream` is rejected as `{:error, {:illegal_combination, :sync_with_stream}}`.

---

## Command options

Applied to `run/2`, `run_link/2`, `stream/2`, and `manage/2`.

### Run mode

| Option | Type | Default | Meaning |
|---|---|---|---|
| `:sync` | `boolean` | absent (async) | Block until the program exits and capture stdout/stderr into an `%Output{}` struct. Mutually exclusive with `stdout: :stream`. |
| `:monitor` | `boolean` | absent | Deliver `{:stdout, _, _}`, `{:stderr, _, _}`, and `:DOWN` messages to the **calling process's** mailbox. `stream/2` forces this on. |

### Process identity & environment

| Option | Type | Meaning |
|---|---|---|
| `:executable` | `string` | Override the program path (the `command` argument becomes argv[0] only). |
| `:cd` | `string` | Working directory for the child. |
| `:env` | `%{String.t() => String.t()}` | Environment variables, as a string→string map. Translated to a charlist proplist. |
| `:user` | `string` | Run the child as this user. Requires `:exec` to be running with sufficient privileges. |
| `:group` | `string` | Run the child as this group. |
| `:nice` | `integer` in `-20..20` | Nice value applied to the child. |

### Termination behaviour

| Option | Type | Meaning |
|---|---|---|
| `:kill_command` | `string` | Custom shell command to run instead of sending a signal when stopping. Translated to the `:kill` key in the erlexec proplist. |
| `:kill_timeout` | `non_neg_integer` | Milliseconds to wait between SIGTERM and SIGKILL escalation. |
| `:kill_group` | `boolean` | Kill the entire process group on stop, not just the child. |
| `:success_exit_code` | `non_neg_integer` | Treat this exit code as success (default `0`). |

### Stdin

```
type: {:or, [:boolean, {:in, [:null, :close]}, :string]}
```

| Value | Meaning |
|---|---|
| `true` | Open stdin so the caller can `write_stdin/2`. |
| `false` (or absent) | Stdin is not opened (default). |
| `:null` | Connect stdin to `/dev/null`. |
| `:close` | Close stdin immediately. |
| `path :: String.t()` | Connect stdin to a file at `path`. |

### Stdout / stderr

`stdout` and `stderr` share a custom validator (`ElixirExec.Options.validate_output_device/2`). Any of:

| Value | Meaning | Notes |
|---|---|---|
| `true` | Capture and forward. With `monitor: true` you receive `{:stdout, os_pid, data}` / `{:stderr, ...}` messages. With `sync: true`, chunks land in the `%Output{}` struct. |
| `false` (or absent) | Drop the stream. The program still writes; nothing is delivered. |
| `:null` | Connect to `/dev/null`. |
| `:close` | Close the fd immediately. |
| `:print` | Print to the BEAM console (debug aid). |
| `:stream` | **stdout only.** Buffer chunks for `Stream.unfold/2` consumption via `%OSProcess{}.stream`. Forces `monitor: true` upstream and is incompatible with `sync: true`. |
| `:stderr` | Cross-route: send stdout into stderr (only valid for `:stdout`). |
| `:stdout` | Cross-route: send stderr into stdout (only valid for `:stderr`). |
| `path :: String.t()` | Redirect to a file. |
| `{path, file_opts}` | Same, with file options: `[append: boolean, mode: non_neg_integer]`. |
| `pid :: pid()` | Forward chunks to the given pid as `{:stdout, os_pid, data}` (or `:stderr`) messages. |
| `fun :: (atom, os_pid, binary -> any)` | 3-arity callback invoked per chunk on the `:exec` side. |

Invalid shapes return a NimbleOptions error with the full list of accepted forms.

### Pty

| Option | Type | Meaning |
|---|---|---|
| `:pty` | `boolean` or `keyword` | `true` allocates a pty with defaults; a keyword list allocates a pty with those settings (forwarded as `{:pty, opts}` to `:erlexec`). |
| `:pty_echo` | `boolean` | Toggle pty echo. |
| `:winsz` | `{pos_integer, pos_integer}` | Initial `{rows, cols}` for the pty window. |

After the program is running, `ElixirExec.winsz/3` and `ElixirExec.pty_opts/2` update these dynamically.

### Privilege & debugging

| Option | Type | Meaning |
|---|---|---|
| `:capabilities` | `:all` or `[atom]` | POSIX capabilities to grant. Requires `:exec` running with appropriate privileges. |
| `:debug` | `boolean` or `non_neg_integer` | Enable `:erlexec` debug logging at the given level (`true` = level 1). |

### Illegal combinations

Currently a single rule:

| Combination | Result |
|---|---|
| `sync: true` **and** `stdout: :stream` | `{:error, {:illegal_combination, :sync_with_stream}}` |

Sync runs return a fully-collected `%Output{}`; streaming returns a lazy `Enumerable` over chunks. The two semantics cannot coexist in one call.

---

## Exec start options

These apply to **starting the `:exec` GenServer itself** (something `:erlexec` does at app boot, or something callers can do manually). They are not used by `run/2`/`stream/2`/`manage/2`. The schema is exposed via `ElixirExec.Options.validate_exec/1` so callers managing their own `:exec` lifecycle can validate uniformly.

| Option | Type | Meaning |
|---|---|---|
| `:debug` | `boolean` or `non_neg_integer` | Debug logging level. |
| `:root` | `boolean` | Allow `:exec` to run privileged operations. |
| `:verbose` | `boolean` | Enable verbose logging. |
| `:args` | `[string]` | Extra args for the `exec-port` C binary. |
| `:alarm` | `non_neg_integer` | Alarm timeout (seconds). |
| `:user` | `string` | Default user for spawned children. |
| `:limit_users` | `[string]` | Whitelist of users `:exec` is permitted to switch to. |
| `:port_path` | `string` | Custom path to the `exec-port` binary. Translated as `:portexe`. |
| `:env` | `%{String.t() => String.t()}` | Default environment for spawned children. |
| `:capabilities` | `:all` or `[atom]` | Default capability set. |

---

## Worked examples

### Capture stdout into a string

```elixir
{:ok, %ElixirExec.Output{stdout: chunks}} =
  ElixirExec.run("echo hi", sync: true, stdout: true)

IO.iodata_to_binary(chunks)  # => "hi\n"
```

### Stream a long-running command

```elixir
{:ok, %ElixirExec.OSProcess{stream: stream}} =
  ElixirExec.stream("tail -f /var/log/app.log")

stream
|> Stream.take(100)
|> Enum.each(&IO.write/1)
```

### Monitor mode with mailbox messages

```elixir
{:ok, %ElixirExec.OSProcess{os_pid: os_pid}} =
  ElixirExec.run("ls /etc", monitor: true, stdout: true)

receive do
  {:stdout, ^os_pid, chunk} -> IO.write(chunk)
end

# ...later...
{:ok, 0} = ElixirExec.await_exit(os_pid)
```

### Custom kill command and timeout

```elixir
ElixirExec.run("./long_running.sh",
  monitor: true,
  kill_command: "./graceful_shutdown.sh",
  kill_timeout: 30_000,
  kill_group: true)
```

### Pty + echo off (typical for spawning interactive tools)

```elixir
ElixirExec.run("vim /tmp/note",
  monitor: true,
  pty: true,
  pty_echo: false,
  winsz: {24, 80})
```

### Redirect both streams to files with append

```elixir
ElixirExec.run("./worker",
  monitor: true,
  stdout: {"/var/log/worker.out", [append: true, mode: 0o640]},
  stderr: {"/var/log/worker.err", [append: true]})
```

### Forwarding to another pid

```elixir
ElixirExec.run("./producer",
  monitor: true,
  stdout: collector_pid,
  stderr: collector_pid)
```

`collector_pid` will receive `{:stdout, os_pid, binary}` and `{:stderr, os_pid, binary}` messages.

### Cross-routing stderr into stdout

```elixir
ElixirExec.run("./noisy_command",
  sync: true,
  stdout: true,
  stderr: :stdout)  # stderr chunks land in the same stdout list
```

## See also

- [`api-reference.md`](api-reference.md) — the functions that consume these options.
- [`system-architecture.md`](system-architecture.md) — what happens after validation succeeds.
- `lib/elixir_exec/options.ex` — the source of truth for the schemas.
