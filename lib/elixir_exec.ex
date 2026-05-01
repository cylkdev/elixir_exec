defmodule ElixirExec do
  @moduledoc """
  Run and control external programs from Elixir.

  Use this module when you want to launch a shell command (or any other
  program) from your application and work with what it produces. You can:

    * Wait for the command to finish and get back what it printed.
    * Start it in the background and get a handle for talking to it later.
    * Read its output one line at a time as it runs.
    * Send it input on its stdin, signal it, or stop it.

  Behind the scenes, the heavy lifting is done by an Erlang library called
  `:erlexec`. This module wraps it so you get a more Elixir-friendly
  experience: keyword options, structs like `%ElixirExec.Output{}` and
  `%ElixirExec.OSProcess{}`, and helpful return values.

  ## Examples

  Wait for a command and read what it printed:

      iex> {:ok, %ElixirExec.Output{stdout: ["hi\\n"], stderr: []}} =
      ...>   ElixirExec.run("echo hi", sync: true, stdout: true)

  Start a command in the background, then read its output as it arrives:

      iex> {:ok, %ElixirExec.OSProcess{os_pid: os_pid}} =
      ...>   ElixirExec.run("echo hi", monitor: true, stdout: true)
      iex> {:stdout, "hi\\n"} = ElixirExec.receive_output(os_pid)
      iex> {:exit, 0} = ElixirExec.receive_output(os_pid)

  Read a long-running command line by line:

      iex> {:ok, %ElixirExec.OSProcess{stream: stream}} =
      ...>   ElixirExec.stream("for i in 1 2 3; do echo Iter\\$i; done")
      iex> Enum.to_list(stream)
      ["Iter1\\n", "Iter2\\n", "Iter3\\n"]

  ## Things you can do

    * `run/2` and `run_link/2` — start a command. Pass `sync: true` to
      wait for it; otherwise it runs in the background.
    * `stream/2` — start a command and read its output line by line.
    * `manage/2` — take over a program you started some other way.
    * `stop/1`, `stop_and_wait/2`, `kill/2` — end a running command.
    * `write_stdin/2` — send data to the command's stdin (or `:eof` to
      close it).
    * `receive_output/2` and `await_exit/2` — pick up output and exit
      messages from your mailbox after a background start.
    * `os_pid/1` and `pid/1` — convert between an Elixir process and the
      operating-system process id (the same number you'd see in `ps`).
  """

  alias ElixirExec.{Options, Output, Runner}
  alias ElixirExec.OSProcess, as: ExProcess

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @typedoc "An external command -- a single string or a `[exe | args]` list."
  @type command :: String.t() | [String.t()]

  @typedoc "An OS-level process id (a non-negative integer)."
  @type os_pid :: non_neg_integer()

  @typedoc "A POSIX signal number."
  @type signal :: pos_integer()

  @typedoc "An exit status as returned by the OS."
  @type exit_code :: non_neg_integer()

  @typedoc "Options accepted by `run/2`, `run_link/2`, `manage/2`, and `stream/2`."
  @type command_options :: keyword()

  @typedoc "Options accepted by the `:exec` start function."
  @type exec_options :: keyword()

  # ---------------------------------------------------------------------------
  # run / run_link / stream / manage
  # ---------------------------------------------------------------------------

  @doc """
  Starts an external command and returns either a handle for talking to
  it later or its captured output.

  ## Parameters

    - `command` - `String.t() | [String.t()]`. The command to run. A
      single string is parsed by the OS shell; a `[exe | args]` list is
      executed directly without shell parsing.
    - `options` - `keyword()`. Run options. Notable keys:
        * `:sync` (boolean) — block until the command exits and capture
          output.
        * `:monitor` (boolean) — deliver `{:stdout, _, _}`,
          `{:stderr, _, _}`, and `:DOWN` messages to the calling
          process.
        * `:stdout` / `:stderr` — output handling. Accepts `true`,
          `false`, `:null`, `:close`, `:print`, `:stream` (stdout only),
          the opposite atom for cross-routing, a path string, a
          `{path, file_opts}` tuple, a pid, or a 3-arity function.
        * `:stdin` — `true`, `false`, `:null`, `:close`, or a string
          path.
        * `:executable`, `:cd`, `:env`, `:kill_command`,
          `:kill_timeout`, `:kill_group`, `:group`, `:user`,
          `:success_exit_code`, `:nice`, `:pty`, `:pty_echo`, `:winsz`,
          `:capabilities`, `:debug`.
      Unknown keys are rejected before any program is started. Defaults
      to `[]`.

  ## Returns

  `{:ok, %ElixirExec.OSProcess{}}` for an asynchronous run. The struct's
  `:controller` is the Elixir pid managing the program; `:os_pid` is
  the operating-system pid; `:stream` is `nil` unless `stdout: :stream`
  was passed, in which case `:stream` is an `Enumerable` over the
  program's line-by-line stdout.

  `{:ok, %ElixirExec.Output{}}` when `sync: true` was passed. The
  struct's `:stdout` and `:stderr` lists hold the captured chunks in
  arrival order.

  `{:error, %NimbleOptions.ValidationError{}}` when option validation
  fails — the program is never started.

  `{:error, {:illegal_combination, :sync_with_stream}}` when both
  `sync: true` and `stdout: :stream` are passed; these two are mutually
  exclusive.

  `{:error, term()}` when `:erlexec` itself rejects the command.

  ## Examples

      # Synchronous run, capturing stdout:
      iex> {:ok, %ElixirExec.Output{stdout: ["hi\\n"], stderr: []}} =
      ...>   ElixirExec.run("echo hi", sync: true, stdout: true)

      # Asynchronous run with messages flowing to the caller:
      iex> {:ok, %ElixirExec.OSProcess{os_pid: os_pid}} =
      ...>   ElixirExec.run("echo hi", monitor: true, stdout: true)
      iex> {:stdout, "hi\\n"} = ElixirExec.receive_output(os_pid)
      iex> {:exit, 0} = ElixirExec.receive_output(os_pid)

      # Validation rejects unknown keys before anything runs:
      iex> {:error, %NimbleOptions.ValidationError{}} =
      ...>   ElixirExec.run("ls", bogus_key: 1)
  """
  @spec run(command(), command_options()) ::
          {:ok, ExProcess.t()} | {:ok, Output.t()} | {:error, term()}
  def run(command, options \\ []), do: Runner.run(:run, command, options)

  @doc """
  Starts an external command exactly like `run/2`, but links the calling
  process to the program's controller pid so the two share fate.

  ## Parameters

    - `command` - `String.t() | [String.t()]`. Same shape as `run/2`.
    - `options` - `keyword()`. Same options as `run/2`. Defaults to `[]`.

  ## Returns

  Same return shapes as `run/2`. The behavioural difference is the
  link: when the controller exits, the calling process receives an
  `:EXIT` signal carrying the exit reason, and vice versa. Pair with
  `Process.flag(:trap_exit, true)` if you want to handle abnormal
  exits without crashing the caller.

  ## Examples

      # Plain block: the example sets `:trap_exit` and waits on
      # messages, which doesn't fit a doctest.
      Process.flag(:trap_exit, true)

      {:ok, %ElixirExec.OSProcess{controller: pid, os_pid: os_pid}} =
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
          {:ok, ExProcess.t()} | {:ok, Output.t()} | {:error, term()}
  def run_link(command, options \\ []), do: Runner.run(:run_link, command, options)

  @doc """
  Starts an external command and returns a handle whose `:stream` field
  is an `Enumerable` over the command's line-by-line stdout.

  ## Parameters

    - `command` - `String.t() | [String.t()]`. Same shape as `run/2`.
    - `options` - `keyword()`. Same options as `run/2`, except
      `:monitor` is forced to `true` and `:stdout` is forced to
      `:stream`. Defaults to `[]`. Note that `sync: true` is rejected —
      see Returns.

  ## Returns

  `{:ok, %ElixirExec.OSProcess{stream: stream}}` on success. The
  `:stream` is a regular Elixir enumerable (built from
  `Stream.unfold/2`) over each line the command writes to stdout, with
  the trailing `"\\n"` kept. Iteration ends cleanly when the program
  exits and the buffer has drained, supporting `Enum.take/2` and other
  early-termination operations.

  `{:error, {:illegal_combination, :sync_with_stream}}` when
  `sync: true` was passed alongside the implicit `:stream` mode.

  `{:error, term()}` for any other validation or dispatch failure.

  ## Examples

      iex> {:ok, %ElixirExec.OSProcess{stream: stream}} =
      ...>   ElixirExec.stream("for i in 1 2 3; do echo Iter\\$i; done")
      iex> Enum.to_list(stream)
      ["Iter1\\n", "Iter2\\n", "Iter3\\n"]

      # `sync: true` is mutually exclusive with streaming:
      iex> {:error, {:illegal_combination, :sync_with_stream}} =
      ...>   ElixirExec.stream("echo hi", sync: true)
  """
  @spec stream(command(), command_options()) ::
          {:ok, ExProcess.t()} | {:error, term()}
  def stream(command, options \\ []) do
    options = Keyword.merge(options, monitor: true, stdout: :stream)
    run(command, options)
  end

  @doc """
  Takes ownership of an OS process or port that was started outside
  this library so it can be controlled like any other managed command.

  ## Parameters

    - `target` - `non_neg_integer() | port()`. An OS pid (the integer
      you'd see in `ps`) or an Erlang port pointing at the process.
    - `options` - `keyword()`. Same option set as `run/2`, applied to
      the adopted process going forward. Defaults to `[]`.

  ## Returns

  `{:ok, %ElixirExec.OSProcess{}}` on success. From this point on the
  returned struct's `:controller` and `:os_pid` are valid for every
  `ElixirExec` control function (`stop/1`, `kill/2`, `write_stdin/2`,
  `os_pid/1`, etc.).

  `{:error, %NimbleOptions.ValidationError{}}` when option validation
  fails before `:erlexec` is called.

  `{:error, term()}` when `:erlexec` itself refuses to take ownership
  (for example, the OS pid no longer exists).

  ## Examples

      # Spawn an unmanaged child via bash, then take it over:
      bash = System.find_executable("bash")

      {:ok, %ElixirExec.OSProcess{os_pid: spawner_os_pid}} =
        ElixirExec.run([bash, "-c", "sleep 100 & echo $!"], stdout: true)

      sleep_os_pid =
        receive do
          {:stdout, ^spawner_os_pid, pid_string} ->
            {pid_int, _} = Integer.parse(pid_string)
            pid_int
        end

      {:ok, %ElixirExec.OSProcess{controller: ctl}} =
        ElixirExec.manage(sleep_os_pid)

      is_pid(ctl)
  """
  @spec manage(os_pid() | port(), command_options()) ::
          {:ok, ExProcess.t()} | {:error, term()}
  def manage(target, options \\ []) do
    with {:ok, validated} <- Options.validate_command(options),
         {:ok, pid, os_pid} <-
           :exec.manage(target, Options.to_erl_command_options(validated)) do
      {:ok, %ExProcess{controller: pid, os_pid: os_pid}}
    end
  end

  # ---------------------------------------------------------------------------
  # Control: stop / kill / write_stdin / set_gid
  # ---------------------------------------------------------------------------

  @doc """
  Asks a running command to stop, gracefully.

  ## Parameters

    - `target` - `pid() | non_neg_integer() | port()`. The controller
      pid, the OS pid, or the underlying port — whichever you have on
      hand.

  ## Returns

  `:ok` once the stop request has been accepted. The actual exit may
  arrive later — wait for it via `await_exit/2` or by listening for
  the `:DOWN` message if the command was started with `monitor: true`.

  `{:error, term()}` if the target is unknown to `:erlexec`.

  The stop honours the `:kill_command` and `:kill_timeout` options the
  command was started with. If neither was set, `:erlexec`'s default
  is to send `SIGTERM` first and escalate to `SIGKILL` if the program
  hasn't exited within its kill timeout.

  ## Examples

      {:ok, %ElixirExec.OSProcess{controller: pid}} =
        ElixirExec.run("sleep 10", monitor: true)

      :ok = ElixirExec.stop(pid)
  """
  @spec stop(pid() | os_pid() | port()) :: :ok | {:error, term()}
  defdelegate stop(target), to: :exec

  @doc """
  Stops a running command and waits up to `timeout` milliseconds for it
  to exit.

  ## Parameters

    - `target` - `pid() | non_neg_integer() | port()`. Same shapes as
      `stop/1`.
    - `timeout` - `pos_integer()`. Maximum milliseconds to wait.
      Defaults to `5_000`.

  ## Returns

  The decoded exit reason from `:erlexec` — typically an integer
  status code or a tuple like `{:exit_status, n}` — once the program
  has actually exited. Note that the success return is the raw exit
  reason, not a `{:ok, status}` wrapper.

  `{:error, term()}` if the program does not exit within `timeout`,
  or if the target is unknown to `:erlexec`.

  ## Examples

      {:ok, %ElixirExec.OSProcess{controller: pid}} =
        ElixirExec.run("sleep 0.05", monitor: true)

      ElixirExec.stop_and_wait(pid, 1_000)
  """
  @spec stop_and_wait(pid() | os_pid() | port(), pos_integer()) :: term() | {:error, term()}
  def stop_and_wait(target, timeout \\ 5_000), do: :exec.stop_and_wait(target, timeout)

  @doc """
  Sends a Unix signal to a running command.

  ## Parameters

    - `target` - `pid() | non_neg_integer() | port()`. The controller
      pid, the OS pid, or the underlying port.
    - `signal` - `pos_integer() | atom()`. The signal to send. Either
      an integer signal number (`9` for SIGKILL, `15` for SIGTERM) or
      the atom name (`:sigkill`, `:sigterm`, `:sighup`, etc.). Atoms
      are converted via `signal_to_int/1` before dispatch.

  ## Returns

  `:ok` once the signal has been delivered to `:erlexec`. The
  program's actual death (if any) arrives asynchronously — wait for
  it with `await_exit/2` or by handling the `:DOWN` message from a
  monitored run.

  `{:error, term()}` if the target is unknown to `:erlexec`.

  ## Examples

      {:ok, %ElixirExec.OSProcess{controller: pid, os_pid: os_pid}} =
        ElixirExec.run("sleep 10", monitor: true)

      :ok = ElixirExec.kill(os_pid, 9)
      # Equivalent by atom:
      # :ok = ElixirExec.kill(os_pid, :sigkill)

      receive do
        {:DOWN, ^os_pid, :process, ^pid, {:exit_status, 9}} -> :ok
      end
  """
  @spec kill(pid() | os_pid() | port(), signal() | atom()) :: :ok | {:error, term()}
  def kill(target, signal) when is_atom(signal),
    do: :exec.kill(target, :exec.signal_to_int(signal))

  def kill(target, signal) when is_integer(signal),
    do: :exec.kill(target, signal)

  @doc """
  Sends data to a running command's standard input, or closes its stdin.

  ## Parameters

    - `target` - `pid() | non_neg_integer()`. The controller pid or the
      OS pid of a command started with `stdin: true`.
    - `data` - `binary() | :eof`. The bytes to write, or `:eof` to
      close the command's stdin stream.

  ## Returns

  `:ok`. Always — there is no error return. Programs that read from
  stdin until EOF (`cat`, `wc`, `sort`, etc.) will keep reading until
  you pass `:eof`.

  ## Examples

      {:ok, %ElixirExec.OSProcess{controller: cat_pid, os_pid: cat_os_pid}} =
        ElixirExec.run_link("cat", stdin: true, stdout: true)

      :ok = ElixirExec.write_stdin(cat_pid, "hi\\n")

      receive do
        {:stdout, ^cat_os_pid, "hi\\n"} -> :ok
      end

      :ok = ElixirExec.write_stdin(cat_pid, :eof)
  """
  @spec write_stdin(pid() | os_pid(), binary() | :eof) :: :ok
  defdelegate write_stdin(target, data), to: :exec, as: :send

  @doc """
  Changes the process-group id of a running OS process.

  ## Parameters

    - `os_pid` - `non_neg_integer()`. The OS pid of the program whose
      process group is being changed.
    - `gid` - `non_neg_integer()`. The new process-group id.

  ## Returns

  `:ok` on success.

  `{:error, term()}` if `:erlexec` rejects the call.

  This delegates to `:exec.setpgid/2`. An invalid `gid` may cause the
  underlying `:exec` GenServer to crash with an exit, rather than
  returning a clean `{:error, _}` — wrap calls in a `try/catch :exit`
  when handling unknown values.

  ## Examples

      # Changing to an invalid gid raises an exit, not an error tuple:
      Process.flag(:trap_exit, true)

      {:ok, %ElixirExec.OSProcess{os_pid: os_pid}} =
        ElixirExec.run_link("sleep 100")

      try do
        ElixirExec.set_gid(os_pid, 123_123)
      catch
        :exit, _reason -> :handled
      end
  """
  @spec set_gid(os_pid(), non_neg_integer()) :: :ok | {:error, term()}
  defdelegate set_gid(os_pid, gid), to: :exec, as: :setpgid

  # ---------------------------------------------------------------------------
  # Identity round-trips
  # ---------------------------------------------------------------------------

  @doc """
  Looks up the OS pid for an Elixir controller pid.

  ## Parameters

    - `pid` - `pid()`. The Elixir pid that owns the managed program.

  ## Returns

  `{:ok, os_pid}` where `os_pid` is the operating-system pid that the
  controller is currently managing.

  `{:error, term()}` when the pid is not currently managing an OS
  process — for example, if the program has exited or the pid was
  never an `:erlexec` controller.

  ## Examples

      {:ok, %ElixirExec.OSProcess{controller: ctl, os_pid: os_pid}} =
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

  ## Parameters

    - `os_pid` - `non_neg_integer()`. The operating-system pid to look
      up.

  ## Returns

  `{:ok, pid}` where `pid` is the Elixir pid managing that OS process.

  `{:error, :undefined}` when no controller is managing that OS pid —
  for example, if the program has exited, or the pid was never managed
  by this library.

  `{:error, term()}` for any other lookup failure surfaced by
  `:erlexec`.

  ## Examples

      {:ok, %ElixirExec.OSProcess{controller: ctl, os_pid: os_pid}} =
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
  Lists the OS pids of every program currently being managed by
  `:erlexec` across the whole node.

  ## Returns

  A list of OS pids (non-negative integers). The list reflects only
  programs known to `:erlexec`'s registry — programs spawned outside
  the library and not adopted via `manage/2` are not included. Order
  is not guaranteed and should not be relied on. Returns `[]` when
  nothing is being managed.

  ## Examples

      {:ok, %ElixirExec.OSProcess{os_pid: sleep_os_pid}} =
        ElixirExec.run_link("sleep 10")

      sleep_os_pid in ElixirExec.which_children()
      #=> true

      ElixirExec.kill(sleep_os_pid, 9)
  """
  @spec which_children() :: [os_pid()]
  defdelegate which_children(), to: :exec

  @doc """
  Decodes a raw `wait`-style exit code into a structured tuple.

  ## Parameters

    - `exit_code` - `non_neg_integer()`. A raw `wait(2)`-style status,
      usually obtained from a child process's exit reason.

  ## Returns

  `{:status, code}` when the program exited normally; `code` is the
  program's integer exit status (`0` for success, non-zero for the
  caller-defined failure code).

  `{:signal, signal_name_or_int, core_dumped?}` when the program was
  killed by a signal. `signal_name_or_int` is the atom name of the
  signal (e.g. `:sighup`) when `:erlexec` recognises it, or the raw
  integer otherwise. `core_dumped?` is `true` when the kernel
  produced a core dump for the program.

  ## Examples

      iex> ElixirExec.status(0)
      {:status, 0}

      iex> ElixirExec.status(256)
      {:status, 1}

      iex> ElixirExec.status(1)
      {:signal, :sighup, false}
  """
  @spec status(exit_code()) :: {:status, exit_code()} | {:signal, atom() | integer(), boolean()}
  defdelegate status(exit_code), to: :exec

  @doc """
  Looks up the atom name for an integer signal number.

  ## Parameters

    - `signal` - `integer()`. A POSIX signal number (e.g. `15` for
      SIGTERM).

  ## Returns

  The atom name corresponding to `signal` (e.g. `:sigterm`) when
  `:erlexec` recognises the integer.

  The original integer, unchanged, when `:erlexec` does not have a
  mapping for it.

  ## Examples

      iex> ElixirExec.signal(15)
      :sigterm

      iex> ElixirExec.signal(9)
      :sigkill
  """
  @spec signal(integer()) :: atom() | integer()
  defdelegate signal(signal), to: :exec

  @doc """
  Looks up the integer signal number for an atom name, or passes an
  integer through unchanged.

  ## Parameters

    - `signal` - `atom() | integer()`. Either a POSIX signal atom
      (e.g. `:sigterm`) or an integer signal number.

  ## Returns

  The integer signal number corresponding to `signal`. Atom inputs
  are resolved via `:exec.signal_to_int/1`; integer inputs pass
  through unchanged so the function can be used as a normaliser
  regardless of which form the caller has.

  ## Examples

      iex> ElixirExec.signal_to_int(:sigterm)
      15

      iex> ElixirExec.signal_to_int(15)
      15
  """
  @spec signal_to_int(atom() | integer()) :: integer()
  def signal_to_int(signal) when is_integer(signal), do: signal
  def signal_to_int(signal) when is_atom(signal), do: :exec.signal_to_int(signal)

  @doc """
  Tells a pty-attached command that its terminal window has been
  resized.

  ## Parameters

    - `target` - `pid() | non_neg_integer()`. The controller pid or OS
      pid of a command started with `pty: true` (or `pty: [_]`).
    - `rows` - `pos_integer()`. New row count.
    - `cols` - `pos_integer()`. New column count.

  ## Returns

  `:ok` when the resize was delivered.

  `{:error, term()}` if the target is unknown to `:erlexec`, or was
  not started with a pty attached.

  The command sees this exactly as if a real terminal had been
  resized — useful for full-screen programs (`htop`, `vim`, `less`)
  that draw based on the current window geometry.

  ## Examples

      {:ok, %ElixirExec.OSProcess{controller: pid}} =
        ElixirExec.run("less /etc/hosts", pty: true, monitor: true)

      :ok = ElixirExec.winsz(pid, 24, 80)
  """
  @spec winsz(pid() | os_pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  defdelegate winsz(target, rows, cols), to: :exec

  @doc """
  Updates the pty (pseudo-terminal) settings of a running pty-attached
  command.

  ## Parameters

    - `target` - `pid() | non_neg_integer()`. The controller pid or OS
      pid of a command started with a pty attached.
    - `opts` - `keyword()`. Pty options to apply. The shape is whatever
      `:exec.pty_opts/2` accepts; this library does not validate them.

  ## Returns

  `:ok` when the update was accepted.

  `{:error, term()}` when `:erlexec` rejects the call — typically
  because the target was not started with a pty, or because an option
  is unknown to `:erlexec`.

  ## Examples

      {:ok, %ElixirExec.OSProcess{controller: pid}} =
        ElixirExec.run("cat", pty: true, stdin: true, monitor: true)

      :ok = ElixirExec.pty_opts(pid, echo: false)
  """
  @spec pty_opts(pid() | os_pid(), keyword()) :: :ok | {:error, term()}
  defdelegate pty_opts(target, opts), to: :exec

  # ---------------------------------------------------------------------------
  # Receive helpers
  # ---------------------------------------------------------------------------

  @doc """
  Pulls the next message for `os_pid` out of the calling process's
  mailbox.

  ## Parameters

    - `os_pid` - `non_neg_integer()`. The OS pid the messages are
      tagged with. Messages flow only when the command was started
      with `monitor: true` and the appropriate `:stdout` / `:stderr`
      options.
    - `timeout` - `timeout()`. Maximum milliseconds to wait. Defaults
      to `5_000`.

  ## Returns

  `{:stdout, data}` when a stdout chunk is available; `data` is the
  binary the program wrote.

  `{:stderr, data}` when a stderr chunk is available.

  `{:exit, status}` when the program has exited; `status` is the
  decoded exit reason — `0` for `:normal`, the integer code for
  `{:exit_status, n}`, or the raw reason for anything else (see
  `ElixirExec.OSProcess.decode_reason/1`).

  `:timeout` when nothing arrives within `timeout` milliseconds. The
  call does not consume any non-matching messages from the mailbox.

  ## Examples

      iex> {:ok, %ElixirExec.OSProcess{os_pid: os_pid}} =
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
      {:DOWN, ^os_pid, :process, _pid, reason} -> {:exit, ExProcess.decode_reason(reason)}
    after
      timeout -> :timeout
    end
  end

  @doc """
  Waits for a command to exit, discarding any stdout or stderr messages
  that arrive in the meantime.

  ## Parameters

    - `target` - `pid() | non_neg_integer()`. The controller pid or
      OS pid. Pid inputs are resolved to the OS pid via `os_pid/1`.
    - `timeout` - `timeout()`. Maximum milliseconds to wait. Defaults
      to `:infinity` — there is no implicit deadline, so be sure that
      is what you want.

  ## Returns

  `{:ok, status}` once the program has exited; `status` is the
  decoded exit reason (see `ElixirExec.OSProcess.decode_reason/1`).

  `{:error, :timeout}` if the program is still alive when `timeout`
  milliseconds pass.

  `{:error, term()}` if a `pid` argument cannot be resolved to an OS
  pid.

  The command must have been started with `monitor: true` for the
  `:DOWN` message this function waits on to be delivered.

  ## Examples

      iex> {:ok, %ElixirExec.OSProcess{os_pid: os_pid}} =
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
      {:DOWN, ^os_pid, :process, _pid, reason} -> {:ok, ExProcess.decode_reason(reason)}
    after
      timeout -> {:error, :timeout}
    end
  end
end
