defmodule ElixirExec do
  @moduledoc """
  Runs and controls external programs from Elixir.

  Start a command, wait for it to finish and capture what it printed, or
  start it in the background and read its output as it arrives. Send
  input on stdin, deliver signals, and stop or kill the program when you
  are done.

  ## Examples

  Wait for a command and read what it printed:

      iex> {:ok, %ElixirExec.Output{stdout: ["hi\\n"], stderr: []}} =
      ...>   ElixirExec.run("echo hi", sync: true, stdout: true)

  Start a command in the background, then read its output as it arrives:

      iex> {:ok, %ElixirExec.Handle{os_pid: os_pid}} =
      ...>   ElixirExec.run("echo hi", monitor: true, stdout: true)
      iex> {:stdout, "hi\\n"} = ElixirExec.receive_output(os_pid)
      iex> {:exit, 0} = ElixirExec.receive_output(os_pid)

  Read a long-running command line by line:

      iex> {:ok, %ElixirExec.Handle{stream: stream}} =
      ...>   ElixirExec.stream("for i in 1 2 3; do echo Iter\\$i; done")
      iex> Enum.to_list(stream)
      ["Iter1\\n", "Iter2\\n", "Iter3\\n"]

  ## Functions

    * `run/2`, `run_link/2` — start a command, in the background or
      synchronously.

    * `stream/2` — start a command and read its output one line at a time.

    * `manage/2` — take over a program that was started elsewhere.

    * `stop/1`, `stop_and_wait/2`, `kill/2` — end a running command.

    * `write_stdin/2` — send data to a command's stdin, or close it.

    * `receive_output/2`, `await_exit/2` — pick up output and exit
      messages from the mailbox.

    * `os_pid/1`, `pid/1` — translate between an Elixir pid and the
      operating-system pid.
  """

  alias ElixirExec.{Core, Handle, Options, Output}

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @typedoc """
  A command to run — either a single string or a `[exe | args]` list.

  A string is parsed by the OS shell, which also handles `PATH` lookup.
  A list runs directly, with no shell parsing. When the first list
  element is a bare name (no `/`, `./`, or `../` prefix), it is resolved
  against `PATH` first so the list form gets the same lookup as the
  string form.
  """
  @type command :: String.t() | [String.t()]

  @typedoc "An OS-level process id (a non-negative integer)."
  @type os_pid :: non_neg_integer()

  @typedoc "A POSIX signal number."
  @type signal :: pos_integer()

  @typedoc "An exit status as returned by the OS."
  @type exit_code :: non_neg_integer()

  @typedoc "Options accepted by `run/2`, `run_link/2`, `manage/2`, and `stream/2`."
  @type command_options :: keyword()

  @typedoc "Options accepted by the underlying runner's start function."
  @type exec_options :: keyword()

  # ---------------------------------------------------------------------------
  # run / run_link / stream / manage
  # ---------------------------------------------------------------------------

  @doc """
  Starts an external command.

  `command` is either a single string (parsed by the OS shell, which
  handles `PATH` lookup) or a `[exe | args]` list (executed directly,
  with no shell parsing). When the first list element is a bare name —
  no `/`, `./`, or `../` prefix — it is resolved against `PATH` so the
  list form gets the same lookup as the string form.

  By default the command runs in the background and the call returns
  right away with a handle. Pass `sync: true` to wait for the command
  to finish and get back what it printed instead. Unknown options are
  rejected up front — no program is started until validation passes.

  ## Options

    * `:sync` — wait for the command to exit and return its captured
      output. Boolean. Default `false`.

    * `:monitor` — deliver `{:stdout, _, _}`, `{:stderr, _, _}`, and
      `:DOWN` messages to the calling process. Boolean. Default `false`.

    * `:stdout`, `:stderr` — how each output stream is handled. One of
      `true`, `false`, `:null`, `:close`, `:print`, `:stream` (stdout
      only), the other stream's atom (to cross-route), a path string, a
      `{path, file_opts}` tuple, a pid, or a 3-arity function.

    * `:stdin` — `true`, `false`, `:null`, `:close`, or a path string.

    * `:executable`, `:cd`, `:env`, `:kill_command`, `:kill_timeout`,
      `:kill_group`, `:group`, `:user`, `:success_exit_code`, `:nice`,
      `:pty`, `:pty_echo`, `:winsz`, `:capabilities`, `:debug` — passed
      through to the underlying runner.

  ## Return values

  Returns `{:ok, %ElixirExec.Handle{}}` for a background run. The
  handle's `:controller` is the Elixir pid running the program;
  `:os_pid` is the OS pid; `:stream` is `nil` unless `stdout: :stream`
  was passed, in which case `:stream` is an `Enumerable` over the
  program's line-by-line stdout.

  Returns `{:ok, %ElixirExec.Output{}}` when `sync: true` was passed.
  The struct's `:stdout` and `:stderr` lists hold the captured chunks
  in the order they arrived.

  Returns `{:error, %NimbleOptions.ValidationError{}}` when option
  validation fails. The program is never started.

  Returns `{:error, {:illegal_combination, :sync_with_stream}}` when
  `sync: true` and `stdout: :stream` are both passed. The two cannot
  be combined.

  Returns `{:error, term()}` when the underlying runner refuses the
  command.

  ## Examples

      # Synchronous run, capturing stdout:
      iex> {:ok, %ElixirExec.Output{stdout: ["hi\\n"], stderr: []}} =
      ...>   ElixirExec.run("echo hi", sync: true, stdout: true)

      # Asynchronous run with messages flowing to the caller:
      iex> {:ok, %ElixirExec.Handle{os_pid: os_pid}} =
      ...>   ElixirExec.run("echo hi", monitor: true, stdout: true)
      iex> {:stdout, "hi\\n"} = ElixirExec.receive_output(os_pid)
      iex> {:exit, 0} = ElixirExec.receive_output(os_pid)

      # Validation rejects unknown keys before anything runs:
      iex> {:error, %NimbleOptions.ValidationError{}} =
      ...>   ElixirExec.run("ls", bogus_key: 1)
  """
  @spec run(command(), command_options()) ::
          {:ok, Handle.t()} | {:ok, Output.t()} | {:error, term()}
  def run(command, options \\ []), do: Core.run(:run, command, options)

  @doc """
  Starts an external command, linked to the caller.

  Identical to `run/2` in every way except one: the calling process is
  linked to the program's controller pid. If either side exits, the
  other receives an `:EXIT` signal carrying the reason. Call
  `Process.flag(:trap_exit, true)` first if you want to handle the
  signal without crashing.

  Arguments, options, and return values match `run/2` exactly.

  ## Examples

      # Plain block: the example sets `:trap_exit` and waits on
      # messages, which doesn't fit a doctest.
      Process.flag(:trap_exit, true)

      {:ok, %ElixirExec.Handle{controller: pid, os_pid: os_pid}} =
        ElixirExec.run_link("echo $FOO; false",
                            stdout: true,
                            env: %{"FOO" => "BAR"})

      receive do
        {:stdout, ^os_pid, "BAR\\n"} -> :ok
      end

      receive do
        {:EXIT, ^pid, {:exit_status, 256}} -> :ok
      end
  """
  @spec run_link(command(), command_options()) ::
          {:ok, Handle.t()} | {:ok, Output.t()} | {:error, term()}
  def run_link(command, options \\ []), do: Core.run(:run_link, command, options)

  @doc """
  Starts an external command and reads its stdout one line at a time.

  The returned handle's `:stream` field is an `Enumerable` over each
  line the program writes. Lines keep their trailing delimiter. When
  the program exits and the buffer drains, iteration ends cleanly —
  `Enum.take/2` and other early-termination operations work as usual.

  Takes the same arguments as `run/2`, with two forced settings:
  `monitor: true` and `stdout: :stream`. Passing `sync: true` is
  rejected, since waiting for the command to finish would defeat
  streaming.

  ## Options

  All `run/2` options, plus:

    * `:delim` — a non-empty binary used to split stdout into lines.
      Defaults to `"\\n"`. Each emitted line keeps its trailing
      delimiter. Any incomplete tail at the end of the stream is
      emitted as the last element, without a trailing delimiter.
    * `:drain` — boolean, default `true`. When iteration ends, the
      stream pulls the one leftover `:DOWN` message that `monitor: true`
      leaves in the caller's mailbox. Set to `false` to receive that
      `:DOWN` yourself.

  ## Return values

  Returns `{:ok, %ElixirExec.Handle{stream: stream}}` on success.

  Returns `{:error, {:illegal_combination, :sync_with_stream}}` when
  `sync: true` was passed.

  Returns `{:error, term()}` for any other validation or dispatch
  failure.

  ## Examples

      iex> {:ok, %ElixirExec.Handle{stream: stream}} =
      ...>   ElixirExec.stream("for i in 1 2 3; do echo Iter\\$i; done")
      iex> Enum.to_list(stream)
      ["Iter1\\n", "Iter2\\n", "Iter3\\n"]

      # `sync: true` is mutually exclusive with streaming:
      iex> {:error, {:illegal_combination, :sync_with_stream}} =
      ...>   ElixirExec.stream("echo hi", sync: true)
  """
  @spec stream(command(), command_options()) :: {:ok, Handle.t()} | {:error, term()}
  def stream(command, options \\ []) do
    run(command, Keyword.merge(options, monitor: true, stdout: :stream))
  end

  @doc """
  Takes ownership of an OS process or port that was started elsewhere.

  Pass either an OS pid (the integer you'd see in `ps`) or an Erlang
  port pointing at the process. `options` accepts the same keys as
  `run/2`, applied to the adopted process from now on.

  Once the call returns `{:ok, handle}`, the handle's `:controller`
  and `:os_pid` work with every `ElixirExec` control function —
  `stop/1`, `kill/2`, `write_stdin/2`, `os_pid/1`, and so on.

  ## Return values

  Returns `{:ok, %ElixirExec.Handle{}}` on success.

  Returns `{:error, %NimbleOptions.ValidationError{}}` when option
  validation fails. The process is not adopted.

  Returns `{:error, term()}` when the underlying runner refuses to
  take ownership — for example, if the OS pid no longer exists.

  ## Examples

      # Spawn an unmanaged child via bash, then take it over:
      bash = System.find_executable("bash")

      {:ok, %ElixirExec.Handle{os_pid: spawner_os_pid}} =
        ElixirExec.run([bash, "-c", "sleep 100 & echo $!"], stdout: true)

      sleep_os_pid =
        receive do
          {:stdout, ^spawner_os_pid, pid_string} ->
            {pid_int, _} = Integer.parse(pid_string)
            pid_int
        end

      {:ok, %ElixirExec.Handle{controller: ctl}} =
        ElixirExec.manage(sleep_os_pid)

      is_pid(ctl)
  """
  @spec manage(os_pid() | port(), command_options()) ::
          {:ok, Handle.t()} | {:error, term()}
  def manage(target, options \\ []) do
    with {:ok, validated} <- Options.validate_command(options),
         {:ok, pid, os_pid} <-
           :exec.manage(target, Options.to_erl_command_options(validated)) do
      {:ok, %Handle{controller: pid, os_pid: os_pid}}
    end
  end

  # ---------------------------------------------------------------------------
  # Control: stop / kill / write_stdin / set_gid
  # ---------------------------------------------------------------------------

  @doc """
  Asks a running command to stop, gracefully.

  Pass the controller pid, the OS pid, or the underlying port —
  whichever you have on hand.

  The stop request is accepted right away, but the actual exit may
  arrive later. Wait for it with `await_exit/2`, or by listening for
  the `:DOWN` message if the command was started with `monitor: true`.

  The `:kill_command` and `:kill_timeout` options the command was
  started with are honoured. With neither set, the default is to send
  `SIGTERM` first, escalating to `SIGKILL` if the program has not
  exited within its kill timeout.

  Returns `:ok` once the stop request has been accepted, or
  `{:error, term()}` when the target is unknown.

  ## Examples

      {:ok, %ElixirExec.Handle{controller: pid}} =
        ElixirExec.run("sleep 10", monitor: true)

      :ok = ElixirExec.stop(pid)
  """
  @spec stop(pid() | os_pid() | port()) :: :ok | {:error, term()}
  def stop(target), do: :exec.stop(target)

  @doc """
  Stops a running command and waits for it to exit.

  Pass the same kind of `target` as `stop/1` (controller pid, OS pid,
  or port). `timeout` is the most milliseconds to wait — defaults to
  `5_000`.

  Returns the decoded exit reason once the program has exited —
  usually an integer status code or a tuple like `{:exit_status, n}`.
  Note that the success return is the raw reason itself, not a
  `{:ok, reason}` wrapper.

  Returns `{:error, term()}` when the program is still alive after
  `timeout`, or when the target is unknown.

  ## Examples

      {:ok, %ElixirExec.Handle{controller: pid}} =
        ElixirExec.run("sleep 0.05", monitor: true)

      ElixirExec.stop_and_wait(pid, 1_000)
  """
  @spec stop_and_wait(pid() | os_pid() | port(), pos_integer()) :: term() | {:error, term()}
  def stop_and_wait(target, timeout \\ 5_000) do
    :exec.stop_and_wait(target, timeout)
  end

  @doc """
  Sends a Unix signal to a running command.

  Pass the controller pid, OS pid, or port as `target`. The signal can
  be an integer number (`9` for SIGKILL, `15` for SIGTERM) or an atom
  name (`:sigkill`, `:sigterm`, `:sighup`, and so on) — either form
  works.

  Returns `:ok` once the signal is delivered. The program's actual
  death (if any) arrives later — wait for it with `await_exit/2`, or
  handle the `:DOWN` message from a monitored run.

  Returns `{:error, term()}` when the target is unknown.

  ## Examples

      {:ok, %ElixirExec.Handle{controller: pid, os_pid: os_pid}} =
        ElixirExec.run("sleep 10", monitor: true)

      :ok = ElixirExec.kill(os_pid, 9)
      # Equivalent by atom:
      # :ok = ElixirExec.kill(os_pid, :sigkill)

      receive do
        {:DOWN, ^os_pid, :process, ^pid, {:exit_status, 9}} -> :ok
      end
  """
  @spec kill(pid() | os_pid() | port(), signal() | atom()) :: :ok | {:error, term()}
  def kill(target, signal) when is_atom(signal) do
    :exec.kill(target, :exec.signal_to_int(signal))
  end

  def kill(target, signal) when is_integer(signal) do
    :exec.kill(target, signal)
  end

  @doc """
  Sends data to a running command's standard input, or closes it.

  Pass the controller pid or OS pid of a command that was started with
  `stdin: true`. `data` is either the bytes to write or the atom
  `:eof`, which closes the stream.

  Programs that keep reading until end-of-file — `cat`, `wc`, `sort` —
  will continue until you send `:eof`.

  Always returns `:ok`.

  ## Examples

      {:ok, %ElixirExec.Handle{controller: cat_pid, os_pid: cat_os_pid}} =
        ElixirExec.run_link("cat", stdin: true, stdout: true)

      :ok = ElixirExec.write_stdin(cat_pid, "hi\\n")

      receive do
        {:stdout, ^cat_os_pid, "hi\\n"} -> :ok
      end

      :ok = ElixirExec.write_stdin(cat_pid, :eof)
  """
  @spec write_stdin(pid() | os_pid(), binary() | :eof) :: :ok
  def write_stdin(target, data) do
    :exec.send(target, data)
  end

  @doc """
  Changes the process-group id of a running OS process.

  An invalid `gid` can cause the underlying runner to crash with an
  exit instead of returning a clean `{:error, _}`. Wrap the call in a
  `try/catch :exit` when the `gid` is not under your control.

  Pass the OS pid of the program and the new process-group id.
  Returns `:ok` on success, or `{:error, term()}` when the call is
  rejected.

  ## Examples

      # Changing to an invalid gid raises an exit, not an error tuple:
      Process.flag(:trap_exit, true)

      {:ok, %ElixirExec.Handle{os_pid: os_pid}} =
        ElixirExec.run_link("sleep 100")

      try do
        ElixirExec.set_gid(os_pid, 123_123)
      catch
        :exit, _reason -> :handled
      end
  """
  @spec set_gid(os_pid(), non_neg_integer()) :: :ok | {:error, term()}
  def set_gid(os_pid, gid) do
    :exec.setpgid(os_pid, gid)
  end

  # ---------------------------------------------------------------------------
  # Identity round-trips
  # ---------------------------------------------------------------------------

  @doc """
  Looks up the OS pid for an Elixir controller pid.

  Returns `{:ok, os_pid}` with the operating-system pid the controller
  is currently managing.

  Returns `{:error, term()}` when the pid is not managing an OS
  process — for example, when the program has exited, or when the pid
  was never a controller.

  ## Examples

      {:ok, %ElixirExec.Handle{controller: ctl, os_pid: os_pid}} =
        ElixirExec.run_link("sleep 100", monitor: true)

      {:ok, ^os_pid} = ElixirExec.os_pid(ctl)

      ElixirExec.kill(os_pid, 9)
      {:ok, _status} = ElixirExec.await_exit(os_pid, 1_000)
  """
  @spec os_pid(pid()) :: {:ok, os_pid()} | {:error, term()}
  def os_pid(pid) when is_pid(pid) do
    case :exec.ospid(pid) do
      {:error, _} = err -> err
      os_pid when is_integer(os_pid) -> {:ok, os_pid}
    end
  end

  @doc """
  Looks up the Elixir controller pid for an OS pid.

  Returns `{:ok, pid}` with the Elixir pid managing that OS process.

  Returns `{:error, :undefined}` when no controller is managing the OS
  pid — for example, when the program has exited or the pid was never
  managed by this library.

  Returns `{:error, term()}` for any other lookup failure.

  ## Examples

      {:ok, %ElixirExec.Handle{controller: ctl, os_pid: os_pid}} =
        ElixirExec.run_link("sleep 100", monitor: true)

      {:ok, ^ctl} = ElixirExec.pid(os_pid)
      {:error, :undefined} = ElixirExec.pid(123_411_231_231)

      ElixirExec.kill(os_pid, 9)
  """
  @spec pid(os_pid()) :: {:ok, pid()} | {:error, :undefined | term()}
  def pid(os_pid) when is_integer(os_pid) do
    case :exec.pid(os_pid) do
      {:error, _} = err -> err
      :undefined -> {:error, :undefined}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  # ---------------------------------------------------------------------------
  # Trivial passthroughs
  # ---------------------------------------------------------------------------

  @doc """
  Lists the OS pids of every program currently managed by this library
  on the local node.

  Programs that were spawned elsewhere and never adopted via `manage/2`
  do not appear. Order is not guaranteed. Returns `[]` when nothing is
  being managed.

  ## Examples

      {:ok, %ElixirExec.Handle{os_pid: sleep_os_pid}} =
        ElixirExec.run_link("sleep 10")

      sleep_os_pid in ElixirExec.which_children()
      #=> true

      ElixirExec.kill(sleep_os_pid, 9)
  """
  @spec which_children() :: [os_pid()]
  def which_children do
    :exec.which_children()
  end

  @doc """
  Decodes a raw `wait(2)`-style exit code into a structured tuple.

  Returns `{:status, code}` when the program exited on its own.
  `code` is the integer exit status — `0` for success, non-zero for a
  caller-defined failure.

  Returns `{:signal, name_or_number, core_dumped?}` when the program
  was killed by a signal. `name_or_number` is the atom name of the
  signal (for example `:sighup`) when it is recognised, otherwise the
  raw integer. `core_dumped?` is `true` when the kernel produced a
  core dump.

  ## Examples

      iex> ElixirExec.status(0)
      {:status, 0}

      iex> ElixirExec.status(256)
      {:status, 1}

      iex> ElixirExec.status(1)
      {:signal, :sighup, false}
  """
  @spec status(exit_code()) :: {:status, exit_code()} | {:signal, atom() | integer(), boolean()}
  def status(exit_code) do
    :exec.status(exit_code)
  end

  @doc """
  Looks up the atom name for an integer signal number.

  Returns the matching atom — for example `:sigterm` for `15` — when
  the number is recognised, or the original integer otherwise.

  ## Examples

      iex> ElixirExec.signal(15)
      :sigterm

      iex> ElixirExec.signal(9)
      :sigkill
  """
  @spec signal(integer()) :: atom() | integer()
  def signal(signal) do
    :exec.signal(signal)
  end

  @doc """
  Returns the integer signal number for an atom name, or passes an
  integer through unchanged.

  Use this when you have a signal in either form and want the
  integer. Atom names like `:sigterm` are resolved to their POSIX
  number; integer inputs are returned as-is.

  ## Examples

      iex> ElixirExec.signal_to_int(:sigterm)
      15

      iex> ElixirExec.signal_to_int(15)
      15
  """
  @spec signal_to_int(atom() | integer()) :: integer()
  def signal_to_int(signal) when is_integer(signal) do
    signal
  end

  def signal_to_int(signal) when is_atom(signal) do
    :exec.signal_to_int(signal)
  end

  @doc """
  Tells a pty-attached command that its terminal window has been
  resized.

  Pass the controller pid or OS pid of a command started with `pty:
  true` (or `pty: [_]`), along with the new `rows` and `cols`. The
  command sees this exactly as if a real terminal had been resized —
  useful for full-screen programs like `htop`, `vim`, and `less` that
  draw based on window size.

  Returns `:ok` once the resize is delivered, or `{:error, term()}`
  when the target is unknown or was not started with a pty.

  ## Examples

      {:ok, %ElixirExec.Handle{controller: pid}} =
        ElixirExec.run("less /etc/hosts", pty: true, monitor: true)

      :ok = ElixirExec.winsz(pid, 24, 80)
  """
  @spec winsz(pid() | os_pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def winsz(target, rows, cols) do
    :exec.winsz(target, rows, cols)
  end

  @doc """
  Updates the pty (pseudo-terminal) settings of a running pty-attached
  command.

  Pass the controller pid or OS pid of a command started with a pty,
  along with the options to apply. The options are forwarded to the
  underlying runner without further validation.

  Returns `:ok` when the update is accepted, or `{:error, term()}`
  when the call is rejected — typically because the target was not
  started with a pty, or an option is not recognised.

  ## Examples

      {:ok, %ElixirExec.Handle{controller: pid}} =
        ElixirExec.run("cat", pty: true, stdin: true, monitor: true)

      :ok = ElixirExec.pty_opts(pid, echo: false)
  """
  @spec pty_opts(pid() | os_pid(), keyword()) :: :ok | {:error, term()}
  def pty_opts(target, opts) do
    :exec.pty_opts(target, opts)
  end

  # ---------------------------------------------------------------------------
  # Receive helpers
  # ---------------------------------------------------------------------------

  @doc """
  Pulls the next message for `os_pid` out of the calling process's
  mailbox.

  Messages flow to the mailbox only when the command was started with
  `monitor: true` and the appropriate `:stdout` / `:stderr` options.
  `timeout` is the most milliseconds to wait — defaults to `5_000`.

  Returns one of:

    * `{:stdout, data}` — a stdout chunk the program wrote.

    * `{:stderr, data}` — a stderr chunk the program wrote.

    * `{:exit, status}` — the program has exited. `status` is the
      decoded exit reason: `0` for a clean exit, the integer code from
      `{:exit_status, n}`, or the raw reason otherwise (see
      `ElixirExec.Handle.decode_reason/1`).

    * `:timeout` — nothing arrived in time. No other messages in the
      mailbox are consumed.

  ## Examples

      iex> {:ok, %ElixirExec.Handle{os_pid: os_pid}} =
      ...>   ElixirExec.run("echo hi", monitor: true, stdout: true)
      iex> {:stdout, "hi\\n"} = ElixirExec.receive_output(os_pid, 1_000)
      iex> {:exit, 0} = ElixirExec.receive_output(os_pid, 1_000)

      iex> ElixirExec.receive_output(999_999_999, 50)
      :timeout
  """
  @spec receive_output(os_pid(), timeout()) ::
          {:stdout, binary()}
          | {:stderr, binary()}
          | {:exit, integer() | atom() | tuple()}
          | :timeout
  def receive_output(os_pid, timeout \\ 5_000) when is_integer(os_pid) do
    receive do
      {:stdout, ^os_pid, data} -> {:stdout, data}
      {:stderr, ^os_pid, data} -> {:stderr, data}
      {:DOWN, ^os_pid, :process, _pid, reason} -> {:exit, Handle.decode_reason(reason)}
    after
      timeout -> :timeout
    end
  end

  @doc """
  Waits for a command to exit, discarding any stdout or stderr messages
  that arrive in the meantime.

  The command must have been started with `monitor: true` for the
  `:DOWN` message this call waits on to be delivered.

  Pass the controller pid or the OS pid as `target`. A pid input is
  resolved to an OS pid first. `timeout` is the most milliseconds to
  wait and defaults to `:infinity` — there is no implicit deadline, so
  be sure that is what you want.

  Returns `{:ok, status}` once the program has exited. `status` is the
  decoded exit reason (see `ElixirExec.Handle.decode_reason/1`).

  Returns `{:error, :timeout}` when the program is still alive after
  `timeout` milliseconds.

  Returns `{:error, term()}` when a pid argument cannot be resolved to
  an OS pid.

  ## Examples

      iex> {:ok, %ElixirExec.Handle{os_pid: os_pid}} =
      ...>   ElixirExec.run("sleep 0.05", monitor: true)
      iex> ElixirExec.await_exit(os_pid, 1_000)
      {:ok, 0}
  """
  @spec await_exit(pid() | os_pid(), timeout()) ::
          {:ok, integer() | atom() | tuple()} | {:error, :timeout}
  def await_exit(target, timeout \\ :infinity)

  def await_exit(target, timeout) when is_pid(target) do
    case os_pid(target) do
      {:ok, os_pid} -> await_exit(os_pid, timeout)
      {:error, _} = err -> err
    end
  end

  def await_exit(os_pid, timeout) when is_integer(os_pid) do
    receive do
      {:stdout, ^os_pid, _data} -> await_exit(os_pid, timeout)
      {:stderr, ^os_pid, _data} -> await_exit(os_pid, timeout)
      {:DOWN, ^os_pid, :process, _pid, reason} -> {:ok, Handle.decode_reason(reason)}
    after
      timeout -> {:error, :timeout}
    end
  end
end
