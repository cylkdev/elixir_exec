defmodule Exec do
  @moduledoc """
  Runs and controls operating system processes.

  Three entry points, in increasing order of control:

    * `run/2` runs a command to completion and returns its output.
    * `stream/2` runs a command and yields its output lazily, line by line.
    * `open/2` starts a command and returns a handle for `read/2`, `write/2`,
      `stop/1` and `signal/2`.

  There is one reading loop underneath, shared by all three. `open/2` and
  `read/2` are the primitives; `stream/2` is the loop that reads until the
  program ends, bounded by `:timeout` and framed as `t:frame/0`; and `run/2` is
  `stream/2` consumed eagerly into a `t:Exec.Result.t/0`. Anything true of one
  is true of the next, because all three share that one loop.

      iex> {:ok, result} = Exec.run("echo hello")
      iex> result.stdout
      "hello\\n"

  ---

  ## Command forms

  A command is either a binary, run as `/bin/sh -c command`, or a list of
  binaries, passed to `execve` directly, bypassing the shell:

      Exec.run("ls -l | wc -l")   # /bin/sh handles PATH, pipes and redirection
      Exec.run(["echo", "hi"])    # passed to execve as written

  In list form a bare executable name is resolved against `PATH` first, so
  `["echo", "hi"]` behaves as `"echo hi"` does. A name containing `/` is used
  exactly as given.

  `/bin/sh` is named explicitly rather than taken from `$SHELL`, so a binary
  command behaves the same way on every machine.

  > #### Watch out {: .warning}
  >
  > A binary command is interpreted by a shell, so pass it only trusted input.
  > `Exec.run("cat \#{user_input}")` runs whatever the input says. Use the list
  > form, which bypasses the shell, whenever any part of the command comes from
  > outside the application.

  ---

  ## Lifetime

  A program lives at most as long as the process that started it. If that
  process dies, including under `Process.exit(pid, :kill)`, the program is
  stopped. This holds for `run/2`, `stream/2` and `open/2` alike, and holds
  only while the VM itself is running.

  Each program runs in a process group of its own, and `stop/1` and `signal/2`
  act on that group. A binary command therefore takes the shell and everything
  the shell started with it, so the real work ends together with the shell.

  The link runs one way only: a program that fails or exits non-zero leaves the
  process that started it undisturbed.

  Pass `owner: pid` to tie a program's lifetime, and its output, to a process
  other than the caller.

  ---

  ## Exit status

  `signal/2` signals the program's whole process group, so a binary command and
  a list command report a signal the same way:

      %{exit_reason: 15, exit_code: nil, signal: 15, exit_status: :sigterm, core_dump: false}

  `stop/1` sends `SIGTERM` and escalates to `SIGKILL`, and erlexec reports a
  program it stopped as a graceful termination:

      %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}

  A signal that arrives from outside that group is different. It reaches only
  the program, leaving `/bin/sh` to reap it and exit `128 + signal` with a
  diagnostic of its own on standard error. An operator running
  `kill -TERM <pid>` against the inner program of `Exec.open("sleep 30")`
  produces:

      %{stderr: "Terminated\\n"}
      %{exit_reason: 36608, exit_code: 143, signal: nil, exit_status: nil, core_dump: false}

  That `"Terminated\\n"` is written by the shell, so it appears only for a
  binary command; a list command runs the program directly.

  ---

  ## Signals sent immediately after starting

  `SIGHUP`, `SIGINT`, `SIGPIPE` and `SIGTERM` can be lost if they are sent in
  the moment between a program being created and its beginning to run. The
  runner's own port program installs handlers for those four, and a newly
  created program inherits them until it replaces itself with the command being
  run, so a signal arriving in that gap is absorbed by an inherited handler
  instead of reaching the program.

  This module sends such a signal again, every 50 milliseconds, for as long as
  the program is still running and at most 250 milliseconds have passed since
  it started: at most six further sends, the last of them at the latest 300
  milliseconds after the program started. A program that installs its own
  handler for one of those four signals inside that window may therefore
  observe the signal more than once. That is preferred deliberately: a signal
  delivered twice is a nuisance, and a signal lost outright is the caller's
  instruction dropped entirely.

  `stop/1` always ends the program, because it escalates to `SIGKILL`, which
  reaches the program whatever handlers it installs. Its opening `SIGTERM` can
  still be swallowed in that same moment, though, and then the program ends at
  the escalation rather than promptly -- around five seconds later by default,
  or after `:kill_timeout`. Signals outside those four reach the program as
  sent: the only other handler the runner's port program installs is for
  `SIGCHLD`, which a program ignores by default in any case, so those four are
  the only signals a caller can send through `signal/2` that get swallowed.

  ---

  ## Failure to launch

  A missing executable given as a path, a permission failure and an
  unreachable `:cd` are reported as a non-zero exit code with a diagnostic on
  standard error, inside `{:ok, result}`:

      iex> {:ok, result} = Exec.run(["/nonexistent/nope"])
      iex> result.exit.exit_code
      1

  `{:error, reason}` means handing the command to the operating system failed
  outright.
  """

  alias Exec.{Program, ProgramSupervisor, Result}

  # Signal numbers differ from system to system. SIGUSR1 is 10 on Linux and 30
  # on Darwin, SIGCHLD 17 and 20, SIGSTOP 19 and 17.
  #
  # erlexec's own table (exec.erl:816) hardcodes the Linux numbers, so asking it
  # to translate :sigchld on a Mac sends signal 17 -- SIGSTOP there. Its table
  # also omits :sigusr1 and :sigusr2 entirely, the two signals conventionally
  # reserved for application use, and it raises function_clause on any name
  # missing from it. That raise happens inside Exec.Program, whose link to
  # erlexec's controller then kills the running program: a typo destroys the
  # thing it was meant to signal.
  #
  # Resolving names here, and passing :exec.kill/2 an integer, bypasses
  # erlexec's table entirely and removes that crash. The same tables are
  # read backwards by lookup_signal/1 below, so a signal number arriving from a
  # dying program is named from the running system's table rather than from
  # erlexec's.
  #
  # The entries below carry the number each name has on both Linux and Darwin.
  # The grouping rests only on the numbers having been checked and found to
  # agree; any of them could differ, as SIGUSR1, under 16, does.
  # Checked with `kill -l <number>` on Debian and `python3 -c "import signal"`
  # on macOS 15.
  @signals_shared %{
    sighup: 1,
    sigint: 2,
    sigquit: 3,
    sigill: 4,
    sigtrap: 5,
    sigabrt: 6,
    sigfpe: 8,
    sigkill: 9,
    sigsegv: 11,
    sigpipe: 13,
    sigalrm: 14,
    sigterm: 15,
    sigttin: 21,
    sigttou: 22,
    sigxcpu: 24,
    sigxfsz: 25,
    sigvtalrm: 26,
    sigprof: 27,
    sigwinch: 28
  }

  # The names whose number the two systems disagree about.
  @signals_linux %{
    sigusr1: 10,
    sigusr2: 12,
    sigchld: 17,
    sigcont: 18,
    sigstop: 19,
    sigtstp: 20
  }

  @signals_darwin %{
    sigusr1: 30,
    sigusr2: 31,
    sigchld: 20,
    sigcont: 19,
    sigstop: 17,
    sigtstp: 18
  }

  @typedoc """
  Options for a command, as a keyword list.

  Read by this module:

    * `:timeout` - milliseconds bounding a whole `run/2` call or a whole
      `stream/2` enumeration, measured from when it begins. Defaults to
      `5_000`; pass `:infinity` to lift the bound. Ignored by `open/2`, which
      hands back a handle and leaves the reading to `read/2`; `read/2` takes
      its own timeout per call.
    * `:owner` - the process that receives the program's output and whose
      death stops the program. Defaults to the calling process.
    * `:stdin`, `:stdout`, `:stderr` - whether to connect that stream to the
      program. Each defaults to `true`. A program started with `stdout: false`
      produces zero `%{stdout: _}` events.
    * `:stream` - a one-argument function `run/2` calls with each
      `{:stdout, chunk}` and `{:stderr, chunk}` as it arrives. Ignored by
      `stream/2` and `open/2`, which hand the caller their output already.

  Forwarded to the underlying runner unchanged: `:executable`, `:cd`, `:env`,
  `:kill`, `:kill_timeout`, `:user`, `:nice`, `:success_exit_code`,
  `:winsz`, `:pty`, `:capabilities` and `:debug`. See
  [erlexec](https://hexdocs.pm/erlexec/exec.html) for their meanings.

  `:group` is rejected. This module sets it, so that `stop/1` and `signal/2`
  reach the program's whole process group.

  Any option the runner rejects raises `ArgumentError`, which includes a key
  outside the set it recognises.
  """
  @type options :: keyword()

  @typedoc "A running program, as returned by `open/2`."
  @opaque t :: pid()

  @typedoc """
  How a program ended, decoded from the status erlexec reports for it.

    * `:exit_reason` - the status as erlexec reported it. `0` is a normal exit.
    * `:exit_code` - the code the program exited with, or `nil` if a signal
      ended it.
    * `:signal` - the number of the signal that ended it, or `nil`.
    * `:exit_status` - that signal's name, or `nil` if the program exited with
      a code or this system lacks a name for the signal.
    * `:core_dump` - whether a core file was written.
  """
  @type exit :: %{
          exit_reason: non_neg_integer(),
          exit_code: non_neg_integer() | nil,
          signal: pos_integer() | nil,
          exit_status: atom() | nil,
          core_dump: boolean()
        }

  @typedoc "One thing a program produced, as returned by `read/2`."
  @type event ::
          %{stdout: binary()}
          | %{stderr: binary()}
          | exit()

  @typedoc """
  One element of `stream/2`.

  `:"$start_of_stream"` opens every enumeration and `:"$end_of_stream"` closes
  it, so a consumer can tell a stream that ran out from one that was cut short.
  Between them, `{:ok, {:stdout, line}}`, `{:ok, {:stderr, line}}` and
  `{:ok, {:exit, exit}}` are what the program produced and
  `{:error, reason}` is why its run was cut short.
  """
  @type frame ::
          :"$start_of_stream"
          | {:ok, {:stdout, binary()} | {:stderr, binary()} | {:exit, exit()}}
          | {:error, term()}
          | :"$end_of_stream"

  @doc """
  Starts `command` and returns a handle to it.

  The handle is passed to `read/2`, `write/2`, `stop/1` and `signal/2`. Output
  arrives in the owner's mailbox as `{program, event}` messages, in order, and
  `read/2` receives them there.

  Standard input, output and error are connected by default; `stdin: false`,
  `stdout: false` or `stderr: false` disconnects the matching one.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Pass it only trusted input, and use
  > the list form for anything else. See the module documentation.

  ## Examples

      {:ok, program} = Exec.open("cat")

      Exec.write(program, "hello\\n")
      {:ok, %{stdout: "hello\\n"}} = Exec.read(program)

      Exec.write(program, :eof)
      {:ok, %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}} = Exec.read(program)

  ## Options

  Accepts every option in `t:options/0`. `:timeout` is accepted and ignored —
  it applies to `run/2`. `read/2` takes its own timeout per call.

  ## Errors

    * `{:error, :empty_command}` - `command` was empty.
    * `{:error, {:executable_not_found, name}}` - a list command's `name` is
      missing from PATH.
    * `{:error, {:exec, message}}` - the runner refused to start the command.

  Raises `ArgumentError` for any option the runner rejects, which includes a
  key outside the set it recognises.
  """
  @spec open(binary() | [binary()]) :: {:ok, t()} | {:error, term()}
  @spec open(binary() | [binary()], options()) :: {:ok, t()} | {:error, term()}
  def open(command, options \\ []) do
    {owner, options} = Keyword.pop(options, :owner, self())
    options = Keyword.drop(options, [:timeout, :stream])

    with {:ok, argv} <- to_argv(command) do
      case ProgramSupervisor.start_program(argv, owner, options) do
        {:ok, program} ->
          {:ok, program}

        {:error, {:invalid_option, {key, value}}} ->
          raise ArgumentError, invalid_value(key, value)

        {:error, reason} ->
          {:error, normalize_start_error(reason)}
      end
    end
  end

  # The runner reports start failures as charlist messages. Only the empty
  # command is reachable through this module's own argument checks; anything
  # else is tagged rather than guessed at, so it stays matchable.
  defp normalize_start_error(~c"empty command provided"), do: :empty_command
  defp normalize_start_error(reason) when is_list(reason), do: {:exec, to_string(reason)}
  defp normalize_start_error(reason), do: {:exec, reason}

  defp invalid_value(key, value) do
    "invalid value for #{inspect(key)}: #{inspect(value)}"
  end

  @doc """
  Receives the next event from `program` in the calling process's mailbox.

  Output is sent to the program's owner, so `read/2` is called by the owner.
  It waits until an event arrives or `timeout` milliseconds pass. `timeout`
  defaults to `5_000`. Events arrive in order, and each one stays in the mailbox
  until it is received.

  `{:ok, exit}`, described in `t:exit/0`, is the last event a program produces;
  the sequence ends there.

  ## Examples

      {:ok, %{stdout: "line one\\n"}} = Exec.read(program)
      {:error, :timeout} = Exec.read(program, 0)

  ## Errors

    * `{:error, :timeout}` - `timeout` passed before an event arrived. The
      program is left running.
  """
  @spec read(t()) :: {:ok, event()} | {:error, :timeout}
  @spec read(t(), timeout()) :: {:ok, event()} | {:error, :timeout}
  def read(program, timeout \\ 5_000) do
    receive do
      {^program, %{exit_reason: exit_reason}} -> {:ok, decode_exit_reason(exit_reason)}
      {^program, event} -> {:ok, event}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Writes `data` to the standard input of `program`, or closes it with `:eof`.

  A program started with `stdin: false` accepts the write and discards it.

  ## Examples

      :ok = Exec.write(program, "hello\\n")
      :ok = Exec.write(program, :eof)

  ## Errors

    * `{:error, :not_running}` - the program has ended. Any output it produced
      before ending is still readable with `read/2`.
  """
  @spec write(t(), iodata() | :eof) :: :ok | {:error, :not_running}
  def write(program, data), do: Program.write(program, data)

  @doc """
  Ends `program` gracefully.

  Sends `SIGTERM` and escalates to `SIGKILL` after roughly five seconds, so a
  program that ignores `SIGTERM` can take that long to end. The `:kill_timeout`
  option changes that delay. `signal/2` with `:sigkill` ends it immediately.

  erlexec reports a program it stopped as a graceful termination, so the exit
  is `exit_code: 0`.

  ## Errors

    * `{:error, :not_running}` - the program had already ended.
  """
  @spec stop(t()) :: :ok | {:error, :not_running}
  def stop(program), do: Program.stop(program)

  @doc """
  Sends `signal` to `program`.

  `signal` is a name such as `:sigterm`, `:sigkill` or `:sigusr1`, or the
  integer number. Names are resolved for the current operating system, because
  the two systems disagree about some of the numbers: `:sigusr1` is 10 on Linux
  and 30 on Darwin. The same table names the signal that `read/2` reports in
  the exit's `:exit_status`, so a signal sent by name comes back under that
  name.

  Where `stop/1` escalates, `signal/2` sends exactly the signal asked for, and
  only that one, to the program's whole process group.

  One of `:sighup`, `:sigint`, `:sigpipe` or `:sigterm` is sent again, though,
  as long as the program is still running and the call landed in the first 250
  milliseconds of the program's life. A single send can be swallowed there, so a
  program that handles one of those four that early may see it more than once.
  See the module documentation.

  A program that traps a signal is still exposed to `signal/2` when its command
  was given as a binary. The `/bin/sh -c` wrapper shares the program's process
  group and keeps every signal's default action, so the wrapper dies and its
  exit is what `read/2` reports. Use the list form to signal a program that
  handles signals itself.

  ## Examples

      :ok = Exec.signal(program, :sigkill)
      :ok = Exec.signal(program, 9)

  ## Errors

    * `{:error, :not_running}` - the program had already ended.

  Raises `ArgumentError` for a name missing from the signal table: only a known
  name has a number to send, and guessing one would signal something. An
  integer is sent as it stands, and one the operating system lacks a signal for
  comes back as `{:error, :einval}`. Signal `0` is accepted and is purely a
  check: it asks whether the program exists.
  """
  @spec signal(t(), atom() | non_neg_integer()) :: :ok | {:error, :not_running}
  def signal(program, signal), do: Program.kill(program, signal_to_int!(signal))

  @doc """
  Returns the processes behind `program`.

    * `:handle_pid` - the Erlang process `open/2` returned as the handle. It
      sends the program's output to the owner, and is what `stop/1` and
      `signal/2` talk to.
    * `:controller_pid` - the Erlang process erlexec starts for the program and
      links to it. erlexec: "Every started OS process is linked to a spawned
      light-weight Erlang process returned by the run/2, run_link/2 command."
    * `:os_pid` - the process id the operating system gives the running
      program, the number `ps` and `kill` use.

  Answered while the program runs. The handle's process ends with the program.

  ## Examples

      {:ok, program} = Exec.open("sleep 30")
      {:ok, %{handle_pid: ^program, controller_pid: controller_pid, os_pid: os_pid}} = Exec.info(program)

  ## Errors

    * `{:error, :not_running}` - the program has exited.
  """
  @spec info(t()) ::
          {:ok, %{handle_pid: pid(), controller_pid: pid(), os_pid: non_neg_integer()}}
          | {:error, :not_running}
  def info(program), do: Program.info(program)

  @doc """
  Returns whether an operating-system process with pid `os_pid` exists.

  Runs `kill -0 <os_pid>`, which is purely a check: the operating system only
  checks that the process exists and that this VM's user may signal it. A
  process owned by another user therefore answers `false`. A pid belonging to a
  process that has ended may since have been reused by another process.

  ## Examples

      {:ok, program} = Exec.open("sleep 30")
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      true = Exec.os_process_alive?(os_pid)
  """
  @spec os_process_alive?(non_neg_integer()) :: boolean()
  def os_process_alive?(os_pid) when is_integer(os_pid) do
    case run(["kill", "-0", Integer.to_string(os_pid)]) do
      {:ok, %Result{exit: %{exit_code: 0}}} -> true
      {:ok, %Result{}} -> false
    end
  end

  @doc """
  Sends `SIGTERM` to the operating-system process with pid `os_pid`, asking it
  to end.

  Runs `kill -TERM <os_pid>`. Returns `true` when the signal was sent, and
  `false` when the process is absent or this VM's user lacks permission to
  signal it.
  The process may handle or ignore `SIGTERM`; `os_process_alive?/1` tells
  whether it has ended.

  Where `signal/2` takes a handle from `open/2` and signals the program's
  whole process group, this signals the one process `os_pid` names,
  including one started outside this library.

  ## Examples

      {:ok, program} = Exec.open("sleep 30")
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      true = Exec.send_sigterm(os_pid)
  """
  @spec send_sigterm(non_neg_integer()) :: boolean()
  def send_sigterm(os_pid) when is_integer(os_pid) do
    case run(["kill", "-TERM", Integer.to_string(os_pid)]) do
      {:ok, %Result{exit: %{exit_code: 0}}} -> true
      {:ok, %Result{}} -> false
    end
  end

  @doc """
  Sends `SIGKILL` to the operating-system process with pid `os_pid`, ending it
  at once.

  Runs `kill -KILL <os_pid>`. Returns `true` when the signal was sent, and
  `false` when the process is absent or this VM's user lacks permission to
  signal it.
  `SIGKILL` takes effect whatever the process does to handle or ignore it.

  Where `signal/2` takes a handle from `open/2` and signals the program's
  whole process group, this signals the one process `os_pid` names,
  including one started outside this library.

  ## Examples

      {:ok, program} = Exec.open("sleep 30")
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      true = Exec.send_sigkill(os_pid)
  """
  @spec send_sigkill(non_neg_integer()) :: boolean()
  def send_sigkill(os_pid) when is_integer(os_pid) do
    case run(["kill", "-KILL", Integer.to_string(os_pid)]) do
      {:ok, %Result{exit: %{exit_code: 0}}} -> true
      {:ok, %Result{}} -> false
    end
  end

  @doc """
  Runs `command` to completion and returns its output.

  Consumes `stream/2` eagerly: the frames it yields are folded into a
  `t:Exec.Result.t/0` rather than handed to the caller one at a time.

  Returns `{:ok, %Exec.Result{}}` whenever the command ran, including when it
  exited non-zero. A non-zero exit is an outcome, reported in the result like
  any other — `grep` finding zero matches exits `1` — so the code arrives in
  the result inside `{:ok, _}`.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Pass it only trusted input, and use
  > the list form for anything else. See the module documentation.

  ## Examples

      iex> Exec.run("echo hi")
      {:ok,
       %Exec.Result{
         stdout: "hi\\n",
         stderr: "",
         exit: %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}
       }}

      iex> {:ok, result} = Exec.run("exit 3")
      iex> result.exit.exit_code
      3

  ## Options

  Accepts every option in `t:options/0`. `:timeout` bounds the whole call rather
  than the gap between two chunks, so a command that prints continuously still
  times out. It defaults to `5_000`; pass `:infinity` to lift the bound. On
  expiry the program is stopped:

      iex> Exec.run("sleep 30", timeout: 200)
      {:error, :timeout}

  `:stream` is called with each `{:stdout, chunk}` and `{:stderr, chunk}` as
  it arrives, which is what makes a long command visible while it runs rather
  than only once it ends:

      Exec.run("mix deps.compile", stream: fn
        {:stdout, chunk} -> IO.write(chunk)
        {:stderr, chunk} -> IO.write(chunk)
      end)

  Chunks are exactly what the operating system delivered, whatever the line
  boundaries: one call may carry several lines or half of one, and a progress
  bar that only ever writes `\\r` arrives as it happens, ahead of any delimiter.
  Use `stream/2` for whole lines. The callback runs in the calling process, in
  order, between reads — so a slow one spends the command's `:timeout`, and one
  that raises stops the program and raises through `run/2`. It is passed output
  only; starting, exiting and failing are `run/2`'s return value.

  ## Errors

    * `{:error, :timeout}` - the command outlived `:timeout` and was stopped.
    * `{:error, :empty_command}` - `command` was empty.
    * `{:error, {:executable_not_found, name}}` - a list command's `name` is
      missing from PATH.
    * `{:error, {:exec, message}}` - the runner refused to start the command.

  Raises `ArgumentError` for any option the runner rejects, which includes a
  key outside the set it recognises.
  """
  @spec run(binary() | [binary()]) :: {:ok, Result.t()} | {:error, term()}
  @spec run(binary() | [binary()], options()) ::
          {:ok, Result.t()} | {:error, :timeout} | {:error, term()}
  def run(command, options \\ []) do
    command
    |> stream_chunks(options)
    |> Enum.reduce_while({[], []}, fn
      {:ok, %{stdout: data}}, {out, err} ->
        if options[:stream], do: options[:stream].({:stdout, data})
        {:cont, {[data | out], err}}

      {:ok, %{stderr: data}}, {out, err} ->
        if options[:stream], do: options[:stream].({:stderr, data})
        {:cont, {out, [data | err]}}

      # Halting here rather than waiting for `:"$end_of_stream"` is free: the
      # frames after a terminal one carry only framing, and the stream stops the
      # program on a halt exactly as it does on exhaustion.
      {:ok, %{exit_reason: _} = exit}, {out, err} ->
        {:halt, {:ok, build_result(out, err, exit)}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}

      :"$start_of_stream", acc ->
        {:cont, acc}
    end)
  end

  defp build_result(out, err, exit) do
    stdout = out |> Enum.reverse() |> IO.iodata_to_binary()
    stderr = err |> Enum.reverse() |> IO.iodata_to_binary()

    %Result{stdout: stdout, stderr: stderr, exit: exit}
  end

  @doc """
  Runs `command` and returns its output as a lazy stream of frames.

  The program starts when enumeration begins, so a stream starts a program only
  once it is enumerated.

  Every enumeration is a frame: `:"$start_of_stream"` first, `:"$end_of_stream"`
  last, and in between the program's output as `{:ok, event}` and any failure
  as `{:error, reason}`.

      :"$start_of_stream"
      {:ok, {:stdout, "hello\\n"}}
      {:ok, {:stderr, "oops\\n"}}
      {:ok, {:exit, %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}}}
      :"$end_of_stream"

  So a consumer can tell a command that ended from one that failed to start,
  and a stream that ran out from one that was cut short, from the frames alone:

      Exec.stream("mix test")
      |> Enum.each(fn
        :"$start_of_stream" -> Logger.info("started")
        {:ok, {:stdout, line}} -> Logger.info(line)
        {:ok, {:stderr, line}} -> Logger.warning(line)
        {:ok, {:exit, exit}} -> Logger.info("exited \#{inspect(exit)}")
        {:error, reason} -> Logger.error("failed: \#{inspect(reason)}")
        :"$end_of_stream" -> Logger.info("done")
      end)

  Output is delivered as lines. They keep their delimiter, and a line still
  lacking one is emitted as it stands before the frame that ends the stream.
  Standard output and standard error are each in order, and interleave in
  arbitrary order relative to each other.

  A failure ends the stream: `{:error, reason}` is followed by
  `:"$end_of_stream"` alone. `{:ok, {:exit, _}}` is absent in that case,
  because the program either failed to start or was stopped before it could
  exit.

  Halting early — through `Enum.take/2`, a `Enum.reduce_while/3` halt, or an
  exception — stops the program, and the frames after the halt are dropped.
  A consumer that halted knows it halted; the absent `:"$end_of_stream"` says
  so to anyone further down the pipeline.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Pass it only trusted input, and use
  > the list form for anything else. See the module documentation.

  ## Examples

      iex> ~S(printf 'a\\nb\\n') |> Exec.stream() |> Enum.to_list()
      [:"$start_of_stream", {:ok, {:stdout, "a\\n"}}, {:ok, {:stdout, "b\\n"}}, {:ok, {:exit, %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}}}, :"$end_of_stream"]

      iex> Exec.stream("") |> Enum.to_list()
      [:"$start_of_stream", {:error, :empty_command}, :"$end_of_stream"]

      "tail -f /var/log/system.log"
      |> Exec.stream(timeout: :infinity)
      |> Stream.filter(&match?({:ok, {:stdout, _}}, &1))
      |> Enum.take(5)

  ## Options

  Accepts every option in `t:options/0`. `:timeout` bounds the whole
  enumeration, measured from when it begins rather than from when the stream is
  built, and defaults to `5_000` as it does for `run/2`. A stream meant to
  outlive that — following a log, watching a queue — passes `:infinity`.
  `:stream` is ignored: these frames are the output, delivered as they
  arrive.

  ## Errors

  A failure to start and an expired `:timeout` arrive as `{:error, reason}`
  frames in the stream, and carry the same reasons `run/2` returns. `ArgumentError` is
  still raised for any option the runner rejects, when the program is started.
  """
  @spec stream(binary() | [binary()]) :: Enumerable.t(frame())
  @spec stream(binary() | [binary()], options()) :: Enumerable.t(frame())
  def stream(command, options \\ []) do
    command
    |> stream_chunks(options)
    |> Stream.transform({"", ""}, &split_frame/2)
  end

  # The one read loop. Both public functions consume it, so the deadline, the
  # framing and the program's lifetime are written once and stay in step.
  # It yields the operating system's chunks; assembling them into lines belongs
  # to stream/2, the one consumer that wants them.
  defp stream_chunks(command, options) do
    timeout = options[:timeout] || 5_000

    Stream.resource(
      # The deadline is stamped when enumeration begins, whenever the stream was
      # built: a stream held and enumerated later gets its whole budget. It is
      # stamped before the open below, so a slow start spends the caller's
      # budget rather than being extra to it.
      fn -> {:init, command, options, deadline_after(timeout)} end,
      &next_stream_chunk/1,
      &finalize_stream/1
    )
  end

  defp next_stream_chunk({:init, command, options, deadline}) do
    {[:"$start_of_stream"], {:open, command, options, deadline}}
  end

  defp next_stream_chunk({:open, command, options, deadline}) do
    case open(command, options) do
      {:ok, program} -> {[], {:continue, program, deadline}}
      {:error, reason} -> {[{:error, reason}], {:error, nil}}
    end
  end

  defp next_stream_chunk({:continue, program, deadline}) do
    case read(program, remaining_timeout(deadline)) do
      # The exit is the last event there is, and reading it spends the handle,
      # so the terminal state carries `nil` in place of a program.
      {:ok, %{exit_reason: _} = event} ->
        {[{:ok, event}], {:exit, nil}}

      {:ok, event} ->
        {[{:ok, event}], {:continue, program, deadline}}

      # The program outlived the budget. It is still running, and this loop has
      # finished reading it, so the terminal state carries it to be stopped.
      {:error, :timeout} ->
        {[{:error, :timeout}], {:error, program}}
    end
  end

  defp next_stream_chunk({:exit, _program}), do: {[:"$end_of_stream"], nil}
  defp next_stream_chunk({:error, _program}), do: {[:"$end_of_stream"], nil}
  defp next_stream_chunk(nil), do: {:halt, nil}

  # Runs on exhaustion, on an early halt and on an exception alike, which is
  # what makes the program's lifetime the stream's responsibility rather than
  # every consumer's. A `nil` is a program that already ended on its own.
  defp finalize_stream(response) do
    case response do
      {:continue, program, _deadline} ->
        Program.shutdown(program)

      {:exit, program} when is_pid(program) ->
        Program.shutdown(program)

      {:error, program} when is_pid(program) ->
        Program.shutdown(program)

      # Already shut down. `{:exit, nil}` is the ordinary success path:
      # reading the exit event spends the handle, so `next_stream_chunk/1`
      # carries `nil` into the terminal state in place of a program. `nil` is
      # the state after that terminal chunk emitted `:"$end_of_stream"` and the
      # stream halted. This case once lacked both clauses, so every command that
      # ran to completion crashed in cleanup with a CaseClauseError.
      {:exit, nil} ->
        :ok

      {:error, nil} ->
        :ok

      nil ->
        :ok

      :"$end_of_stream" ->
        :ok
    end
  end

  # Output arrives in chunks, whatever the line boundaries, and one line can
  # span two chunks, so the trailing partial is carried to prepend to the next
  # chunk.
  defp split_frame({:ok, %{stdout: data}}, {out, err}) do
    {lines, partial} = split_complete_lines(out <> data)
    {Enum.map(lines, &{:ok, {:stdout, &1}}), {partial, err}}
  end

  defp split_frame({:ok, %{stderr: data}}, {out, err}) do
    {lines, partial} = split_complete_lines(err <> data)
    {Enum.map(lines, &{:ok, {:stderr, &1}}), {out, partial}}
  end

  # A terminal frame is the last chance to emit a line still lacking its
  # delimiter, so the partials go out ahead of it and reach the caller.
  # That holds for a failure as much as for an exit: output a command produced
  # before it timed out is still output the caller asked for.
  defp split_frame({:ok, %{exit_reason: _} = exit}, buffers),
    do: flush(buffers, {:ok, {:exit, exit}})

  defp split_frame({:error, _} = frame, buffers), do: flush(buffers, frame)

  defp split_frame(frame, buffers) when frame in [:"$start_of_stream", :"$end_of_stream"],
    do: {[frame], buffers}

  defp flush({out, err}, frame) do
    {trailing_line(:stdout, out) ++ trailing_line(:stderr, err) ++ [frame], {"", ""}}
  end

  defp trailing_line(_tag, ""), do: []
  defp trailing_line(tag, partial), do: [{:ok, {tag, partial}}]

  defp split_complete_lines(buffer) do
    {complete, [partial]} = buffer |> String.split("\n") |> Enum.split(-1)
    {Enum.map(complete, &(&1 <> "\n")), partial}
  end

  defp deadline_after(:infinity), do: :infinity
  defp deadline_after(timeout), do: System.monotonic_time(:millisecond) + timeout

  # Absolute, one deadline for every read: a chatty program would reset a
  # per-chunk timer on every line and keep its deadline moving.
  defp remaining_timeout(:infinity), do: :infinity
  defp remaining_timeout(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # erlexec builds the argv with a function accepting only binaries and lists
  # (exec.erl:1362); anything else raises function_clause inside the :exec
  # singleton, which is VM-wide and would take every other running program with
  # it.
  defp to_argv(command) when is_list(command) do
    command |> Enum.map(&to_string/1) |> resolve_executable_path()
  end

  # A string is a shell script, so something has to interpret it. Left to
  # itself erlexec passes the string to $SHELL, which makes the process tree
  # depend on the machine: zsh and bash replace themselves when the script is a
  # single simple command, while dash -- /bin/sh on Debian -- forks and runs the
  # program as a child. That difference decides whether the process this library
  # tracks is the program or only its parent, and with it whether stop/1 and the
  # lifetime guarantee mean anything. Naming /bin/sh here settles it the same way
  # everywhere, as System.shell/2 does.
  #
  # An empty command is passed through as it stands: erlexec rejects an empty
  # command itself (exec.cpp:404-405, "empty command provided"), but that check
  # inspects the first element of the argv it receives, and ["/bin/sh", "-c",
  # ""] is a three-element, non-empty argv. Wrapping "" would silently turn a
  # caller error into a program that runs and exits 0.
  defp to_argv(""), do: {:ok, ""}
  defp to_argv(command), do: {:ok, ["/bin/sh", "-c", to_string(command)]}

  # execve takes the path exactly as given, so a bare name in list form is
  # resolved here. A name containing "/" is already a path; a name missing from
  # PATH is an error. String commands go to a shell, which searches for itself.
  defp resolve_executable_path([exe | args]) do
    if String.contains?(exe, "/") do
      {:ok, [exe | args]}
    else
      case System.find_executable(exe) do
        nil -> {:error, {:executable_not_found, exe}}
        path -> {:ok, [path | args]}
      end
    end
  end

  defp resolve_executable_path(command), do: {:ok, command}

  # Decodes the exit reason erlexec reports for a program. Kept here rather than
  # in Exec.Program because it reads the signal tables above backwards, and one
  # module owning both directions of that mapping is what keeps a name sent and
  # a name reported the same name.
  #
  # The bits are the ones erlexec's own status/1 reads: the signal in the low
  # seven, the core-dump flag above them, the exit code in the next byte.
  defp decode_exit_reason(exit_reason) do
    signal = Bitwise.band(exit_reason, 0x7F)
    exited? = signal === 0

    %{
      exit_reason: exit_reason,
      exit_code: if(exited?, do: Bitwise.bsr(exit_reason, 8), else: nil),
      signal: if(exited?, do: nil, else: signal),
      exit_status: if(exited?, do: nil, else: lookup_signal(signal)),
      core_dump: Bitwise.band(exit_reason, 0x80) === 0x80
    }
  end

  # A number the running system's table lacks a name for is named `nil`.
  # The number itself is kept in the exit's `:signal`.
  defp lookup_signal(number) do
    Enum.find_value(signal_table(), fn {name, n} -> if n === number, do: name end)
  end

  # Every entry in each platform map has a number distinct from every entry in
  # the shared map, so the reverse lookup above has exactly one answer.
  defp signal_table do
    case :os.type() do
      {:unix, :darwin} -> Map.merge(@signals_shared, @signals_darwin)
      {:unix, _} -> Map.merge(@signals_shared, @signals_linux)
    end
  end

  defp signal_to_int!(number) when is_integer(number), do: number

  defp signal_to_int!(name) when is_atom(name) do
    case Map.fetch(signal_table(), name) do
      {:ok, number} ->
        number

      :error ->
        raise ArgumentError, "unknown signal #{inspect(name)}"
    end
  end
end
