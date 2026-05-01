# API Reference

Every public function on `ElixirExec` with its signature, return shape, and the behaviour-relevant detail you need to call it correctly. The authoritative source for each function is its `@doc` and `@spec` in `lib/elixir_exec.ex`; this page is a flat index.

## Index

- **Starting a command** — [`run/2`](#run2), [`run_link/2`](#run_link2), [`stream/2`](#stream2), [`manage/2`](#manage2)
- **Controlling a running command** — [`stop/1`](#stop1), [`stop_and_wait/2`](#stop_and_wait2), [`kill/2`](#kill2), [`write_stdin/2`](#write_stdin2), [`set_gid/2`](#set_gid2)
- **Pty handling** — [`winsz/3`](#winsz3), [`pty_opts/2`](#pty_opts2)
- **Identity round-trips** — [`os_pid/1`](#os_pid1), [`pid/1`](#pid1), [`which_children/0`](#which_children0)
- **Decoding exit codes and signals** — [`status/1`](#status1), [`signal/1`](#signal1), [`signal_to_int/1`](#signal_to_int1)
- **Receive helpers (mailbox protocol)** — [`receive_output/2`](#receive_output2), [`await_exit/2`](#await_exit2)
- **Result structs** — [`%ElixirExec.OSProcess{}`](#elixirexecosprocess), [`%ElixirExec.Output{}`](#elixirexecoutput)

For every option accepted by `run/2`, `run_link/2`, `stream/2`, and `manage/2`, see [`configuration-guide.md`](configuration-guide.md).

---

## Starting a command

### `run/2`

```elixir
@spec run(command(), command_options()) ::
        {:ok, ElixirExec.OSProcess.t()} | {:ok, ElixirExec.Output.t()} | {:error, term()}
def run(command, options \\ [])
```

Starts an external command. `sync: true` blocks until exit and returns `%Output{}` with captured stdout/stderr. Without `sync: true`, returns immediately with `%OSProcess{}` carrying the `:controller` pid and `:os_pid`.

Returns:

- `{:ok, %ElixirExec.OSProcess{}}` — async start.
- `{:ok, %ElixirExec.Output{}}` — when `sync: true`.
- `{:error, %NimbleOptions.ValidationError{}}` — option validation failed; no process started.
- `{:error, {:illegal_combination, :sync_with_stream}}` — `sync: true` and `stdout: :stream` together are rejected.
- `{:error, term()}` — `:erlexec` rejected the command.

### `run_link/2`

```elixir
@spec run_link(command(), command_options()) ::
        {:ok, ElixirExec.OSProcess.t()} | {:ok, ElixirExec.Output.t()} | {:error, term()}
```

Identical to `run/2` but **links** the calling process to the controller pid. When the controller exits, the caller gets an `:EXIT` message (or crashes if it isn't trapping exits). Pair with `Process.flag(:trap_exit, true)` if abnormal exits should not bring down the caller.

### `stream/2`

```elixir
@spec stream(command(), command_options()) ::
        {:ok, ElixirExec.OSProcess.t()} | {:error, term()}
```

Convenience wrapper that forces `monitor: true` and `stdout: :stream`, then calls `run/2`. The returned `%OSProcess{}.stream` is an `Enumerable` over each line written to stdout (newline kept). Works with `Enum`, `Stream`, `Enum.take/2`, and other early-termination patterns.

`sync: true` is rejected with `{:error, {:illegal_combination, :sync_with_stream}}`.

### `manage/2`

```elixir
@spec manage(os_pid() | port(), command_options()) ::
        {:ok, ElixirExec.OSProcess.t()} | {:error, term()}
```

Adopts a process or port that was started outside this library so it can be controlled with the same API. Bypasses `Runner` and goes straight to `:exec.manage`. Streaming is not supported for adopted processes.

---

## Controlling a running command

### `stop/1`

```elixir
@spec stop(pid() | os_pid() | port()) :: :ok | {:error, term()}
defdelegate stop(target), to: :exec
```

Asks the program to stop. Honours `:kill_command` and `:kill_timeout` from the original start options; defaults to SIGTERM with escalation to SIGKILL.

### `stop_and_wait/2`

```elixir
@spec stop_and_wait(pid() | os_pid() | port(), pos_integer()) :: term() | {:error, term()}
def stop_and_wait(target, timeout \\ 5_000)
```

Calls `:exec.stop_and_wait/2`. Returns the **raw exit reason** from `:erlexec` on success — not a `{:ok, _}` wrapper — and `{:error, term()}` on timeout or unknown target.

### `kill/2`

```elixir
@spec kill(pid() | os_pid() | port(), signal() | atom()) :: :ok | {:error, term()}
```

Sends a POSIX signal. Accepts an integer (`9`, `15`) or an atom (`:sigkill`, `:sigterm`, `:sighup`). Atoms are normalised through `signal_to_int/1`.

### `write_stdin/2`

```elixir
@spec write_stdin(pid() | os_pid(), binary() | :eof) :: :ok
defdelegate write_stdin(target, data), to: :exec, as: :send
```

Writes `data` to the command's stdin, or closes stdin with `:eof`. Always returns `:ok` — there is no error path. The command must have been started with `stdin: true` (or a string path).

### `set_gid/2`

```elixir
@spec set_gid(os_pid(), non_neg_integer()) :: :ok | {:error, term()}
defdelegate set_gid(os_pid, gid), to: :exec, as: :setpgid
```

Changes the process-group id. Note that an invalid `gid` may surface as a process **exit** rather than an `{:error, _}` tuple — wrap in `try/catch :exit, _ ->` if you handle untrusted values.

---

## Pty handling

### `winsz/3`

```elixir
@spec winsz(pid() | os_pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
```

Tells a pty-attached command its terminal has been resized to `rows × cols`. Useful for `htop`, `vim`, `less`, and similar full-screen TUIs.

### `pty_opts/2`

```elixir
@spec pty_opts(pid() | os_pid(), keyword()) :: :ok | {:error, term()}
```

Updates pty settings on a running pty-attached command. The `opts` keyword is forwarded to `:exec.pty_opts/2` without further validation by this library.

---

## Identity round-trips

### `os_pid/1`

```elixir
@spec os_pid(pid()) :: {:ok, os_pid()} | {:error, term()}
```

Looks up the OS pid for an Elixir controller pid. Returns `{:error, _}` if the pid is no longer managing a process (e.g., the program exited).

### `pid/1`

```elixir
@spec pid(os_pid()) :: {:ok, pid()} | {:error, :undefined | term()}
```

Reverse of `os_pid/1`. Returns `{:error, :undefined}` for an unknown OS pid.

### `which_children/0`

```elixir
@spec which_children() :: [os_pid()]
defdelegate which_children(), to: :exec
```

Lists every OS pid currently managed by `:erlexec` across the whole node. Order is not guaranteed.

---

## Decoding exit codes and signals

### `status/1`

```elixir
@spec status(exit_code()) :: {:status, exit_code()} | {:signal, atom() | integer(), boolean()}
defdelegate status(exit_code), to: :exec
```

Decodes a raw `wait(2)`-style exit code:

- `{:status, code}` — normal exit; `code` is `0` for success.
- `{:signal, name_or_int, core_dumped?}` — killed by signal.

Examples (doctested):

```elixir
iex> ElixirExec.status(0)
{:status, 0}

iex> ElixirExec.status(256)
{:status, 1}

iex> ElixirExec.status(1)
{:signal, :sighup, false}
```

### `signal/1`

```elixir
@spec signal(integer()) :: atom() | integer()
defdelegate signal(signal), to: :exec
```

Looks up the atom name (`:sigterm`, `:sigkill`, ...) for a signal integer. Unknown integers pass through unchanged.

### `signal_to_int/1`

```elixir
@spec signal_to_int(atom() | integer()) :: integer()
```

Reverse of `signal/1`. Integers pass through, atoms are resolved via `:exec.signal_to_int/1`. Useful as a normaliser when accepting either form from a caller.

---

## Receive helpers (mailbox protocol)

When a command is started with `monitor: true`, `:erlexec` delivers messages to the **calling process's** mailbox:

| Message | Meaning |
|---|---|
| `{:stdout, os_pid, binary}` | A chunk of stdout. |
| `{:stderr, os_pid, binary}` | A chunk of stderr. |
| `{:DOWN, os_pid, :process, ctl_pid, reason}` | The OS process has exited. |

The two helpers below pull these from your mailbox.

### `receive_output/2`

```elixir
@spec receive_output(os_pid(), timeout()) ::
        {:stdout, binary()}
        | {:stderr, binary()}
        | {:exit, integer() | atom() | tuple()}
        | :timeout
def receive_output(os_pid, timeout \\ 5_000)
```

Pulls **the next** matching message for `os_pid`. Decodes `:DOWN` reasons via `OSProcess.decode_reason/1` (so a normal exit becomes `{:exit, 0}`, an exit-status tuple becomes `{:exit, n}`, and anything else passes through). Non-matching mailbox messages are not consumed.

### `await_exit/2`

```elixir
@spec await_exit(pid() | os_pid(), timeout()) ::
        {:ok, integer() | atom() | tuple()} | {:error, :timeout}
def await_exit(target, timeout \\ :infinity)
```

Waits for the program to exit, **discarding** any stdout/stderr messages that arrive in the meantime. Default timeout is `:infinity` — be explicit if you want a deadline. Pid inputs are first resolved to OS pids via `os_pid/1`.

---

## Result structs

### `%ElixirExec.OSProcess{}`

Returned from async runs. Defined in `lib/elixir_exec/os_process.ex`.

| Field | Type | Meaning |
|---|---|---|
| `:controller` | `pid()` | The Elixir pid `:erlexec` uses to manage the program. |
| `:os_pid` | `non_neg_integer()` | The operating-system pid (the same number you'd see in `ps`). |
| `:stream` | `nil \| Enumerable.t()` | Set when `stdout: :stream` was passed (which `stream/2` does implicitly); otherwise `nil`. |

`ElixirExec.OSProcess.decode_reason/1` is exposed as a helper:

```elixir
decode_reason(:normal)              # => 0
decode_reason({:exit_status, 137})  # => 137
decode_reason(other)                # => other (passthrough)
```

### `%ElixirExec.Output{}`

Returned from sync runs. Defined in `lib/elixir_exec/output.ex`.

| Field | Type | Meaning |
|---|---|---|
| `:stdout` | `[binary()]` | Stdout chunks in arrival order. Empty when `stdout: false`/`:null`/`:close` or the program produced no stdout. |
| `:stderr` | `[binary()]` | Same, for stderr. |

`ElixirExec.Output.from_proplist/1` builds an `%Output{}` from `:erlexec`'s sync-run proplist. It is internal but exported.

## See also

- [`configuration-guide.md`](configuration-guide.md) — every option `run/2`, `stream/2`, and `manage/2` accept.
- [`system-architecture.md`](system-architecture.md) — supervision tree and the streaming model.
- [`testing-guide.md`](testing-guide.md) — canonical patterns for testing code that calls these functions.
