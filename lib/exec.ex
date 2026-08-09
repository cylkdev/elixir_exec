defmodule Exec do
  @moduledoc """
  Runs and controls operating system processes.

  Three entry points, in increasing order of control:

    * `run/2` runs a command to completion and returns its output.
    * `stream/2` runs a command and yields its output lazily, line by line.
    * `open/2` starts a command and returns a handle for `read/2`, `write/2`,
      `stop/1` and `signal/2`.

  There is one reading loop underneath, not three. `open/2` and `read/2` are the
  primitives; `stream/2` is the loop that reads until the program ends, bounded
  by `:timeout` and framed as `t:frame/0`; and `run/2` is `stream/2` consumed
  eagerly into a `t:Exec.Result.t/0`. Anything true of one is true of the next,
  because there is nowhere for them to disagree.

      iex> {:ok, result} = Exec.run("echo hello")
      iex> result.stdout
      "hello\\n"

  ---

  ## Command forms

  A command is either a binary, run as `/bin/sh -c command`, or a list of
  binaries, passed to `execve` directly with no shell involved:

      Exec.run("ls -l | wc -l")   # /bin/sh handles PATH, pipes and redirection
      Exec.run(["echo", "hi"])    # no shell, no expansion, no interpolation

  In list form a bare executable name is resolved against `PATH` first, so
  `["echo", "hi"]` behaves as `"echo hi"` does. A name containing `/` is used
  exactly as given.

  `/bin/sh` is named explicitly rather than taken from `$SHELL`, so a binary
  command behaves the same way on every machine.

  > #### Watch out {: .warning}
  >
  > A binary command is interpreted by a shell, so never pass untrusted input to
  > it. `Exec.run("cat \#{user_input}")` runs whatever the input says. Use the
  > list form, which involves no shell, whenever any part of the command comes
  > from outside the application.

  ---

  ## Lifetime

  A program never outlives the process that started it. If that process dies,
  including under `Process.exit(pid, :kill)`, the program is stopped. This holds
  for `run/2`, `stream/2` and `open/2` alike, and does not survive the VM
  itself going down.

  Each program runs in a process group of its own, and `stop/1` and `signal/2`
  act on that group. A binary command therefore takes the shell and everything
  the shell started with it, rather than leaving the real work orphaned.

  The reverse does not hold: a program that fails or exits non-zero does not
  disturb the process that started it.

  Pass `owner: pid` to tie a program's lifetime to a process other than the
  caller.

  ---

  ## Exit status

  `signal/2` signals the program's whole process group, so a binary command and
  a list command report a signal the same way:

      {:exit, {:signal, :sigterm}}

  `stop/1` is an ordered termination rather than a raw signal, and reports exit
  status `0` whichever form the command took.

  A signal that arrives from outside that group is different. It reaches only
  the program, leaving `/bin/sh` to reap it and exit `128 + signal` with a
  diagnostic of its own on standard error. An operator running
  `kill -TERM <pid>` against the inner program of `Exec.open("sleep 30")`
  produces:

      {:stderr, "Terminated\\n"}
      {:exit, 143}

  That `"Terminated\\n"` comes from the shell, not from the program. A list
  command has no shell to write it.

  ---

  ## Signals sent immediately after starting

  `SIGHUP`, `SIGINT`, `SIGPIPE` and `SIGTERM` can be lost if they are sent in
  the moment between a program being created and its beginning to run. The
  runner's own port program installs handlers for those four, and a newly
  created program inherits them until it replaces itself with the command being
  run, so a signal arriving in that gap is absorbed by an inherited handler
  instead of reaching the program.

  This module sends such a signal again, every 50 milliseconds, for as long as
  the program is still running and no more than 250 milliseconds have passed
  since it started: at most six further sends, the last of them no later than
  300 milliseconds after the program started. A program that installs its own handler
  for one of those four signals inside that window may therefore observe the
  signal more than once. That is preferred deliberately: a signal delivered
  twice is a nuisance, and a signal lost outright is the caller's instruction
  not being carried out at all.

  `stop/1` always ends the program, because it escalates to `SIGKILL`, which no
  handler can absorb. Its opening `SIGTERM` can still be swallowed in that same
  moment, though, and then the program ends at the escalation rather than
  promptly -- around five seconds later by default, or after `:kill_timeout`.
  Signals outside those four are not absorbed this way: the only other handler
  the runner's port program installs is for `SIGCHLD`, which a program ignores
  by default in any case, so nothing a caller can send through `signal/2` is
  swallowed except those four.

  ---

  ## Failure to launch

  A missing executable, a permission failure and an unreachable `:cd` are
  reported as a non-zero exit status with a diagnostic on standard error, not as
  `{:error, reason}`:

      iex> {:ok, result} = Exec.run(["/nonexistent/nope"])
      iex> result.exit_status
      1

  `{:error, reason}` means the command could not be handed to the operating
  system at all.
  """

  alias Exec.{Program, ProgramSupervisor, Result}

  # The budget `run/2` gives a command when the caller names none. Long enough
  # for a slow build or a big download, short enough that a wedged command does
  # not hang the caller forever. Pass `timeout: :infinity` to opt out.
  @default_timeout :timer.minutes(5)

  # Signal numbers are not the same on every system. SIGUSR1 is 10 on Linux and
  # 30 on Darwin, SIGCHLD 17 and 20, SIGSTOP 19 and 17.
  #
  # erlexec's own table (exec.erl:816) hardcodes the Linux numbers, so asking it
  # to translate :sigchld on a Mac sends signal 17 -- SIGSTOP there. It also has
  # no entry at all for :sigusr1 or :sigusr2, the two signals conventionally
  # reserved for application use, and raises function_clause on any name it does
  # not know. That raise happens inside Exec.Program, whose link to erlexec's
  # controller then kills the running program: a typo destroys the thing it was
  # meant to signal.
  #
  # Resolving names here, and passing :exec.kill/2 an integer, means erlexec's
  # table is never consulted and that crash is unreachable. The same tables are
  # read backwards by lookup_signal/1 below, so a signal number arriving from a
  # dying program is named from the running system's table rather than from
  # erlexec's.
  #
  # The entries below carry the number each name has on both Linux and Darwin.
  # They are grouped this way because the numbers were checked and found to
  # agree, not because any rule guarantees it: SIGUSR1 is under 16 and differs.
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
      `stream/2` enumeration, measured from when it begins. Defaults to five
      minutes; pass `:infinity` for no bound. Ignored by `open/2`, which hands
      back a handle rather than reading anything; `read/2` takes its own
      timeout per call.
    * `:owner` - the process whose death stops the program. Defaults to the
      calling process.
    * `:stdin`, `:stdout`, `:stderr` - whether to connect that stream to the
      program. Each defaults to `true`. A program started with `stdout: false`
      produces no `{:stdout, _}` events at all.
    * `:stream` - a one-argument function `run/2` calls with each
      `{:stdout, chunk}` and `{:stderr, chunk}` as it arrives. Ignored by
      `stream/2` and `open/2`, which hand the caller their output already.

  Forwarded to the underlying runner unchanged: `:executable`, `:cd`, `:env`,
  `:kill`, `:kill_timeout`, `:user`, `:nice`, `:success_exit_code`,
  `:winsz`, `:pty`, `:capabilities` and `:debug`. See
  [erlexec](https://hexdocs.pm/erlexec/exec.html) for their meanings.

  `:group` is not accepted. This module sets it, so that `stop/1` and
  `signal/2` reach the program's whole process group.

  Any option the runner rejects raises `ArgumentError`, which includes a key it
  does not know.
  """
  @type options :: keyword()

  @typedoc "A running program, as returned by `open/2`."
  @opaque t :: pid()

  @typedoc "How a command ended: an exit code, or `{:signal, name}` if a signal killed it."
  @type exit_status :: non_neg_integer() | {:signal, atom() | pos_integer()}

  @typedoc "One thing a program produced, as returned by `read/2`."
  @type event :: {:stdout, binary()} | {:stderr, binary()} | {:exit, exit_status()}

  @typedoc """
  One element of `stream/2`.

  `:"$start_of_stream"` opens every enumeration and `:"$end_of_stream"` closes it, so a consumer can tell
  a stream that ran out from one that was cut short. Between them, `{:ok,
  event}` is what the program produced and `{:error, reason}` is why it could
  not be run to the end.
  """
  @type frame :: :"$start_of_stream" | {:ok, event()} | {:error, term()} | :"$end_of_stream"

  @doc """
  Starts `command` and returns a handle to it.

  The handle is passed to `read/2`, `write/2`, `stop/1` and `signal/2`. Output
  is held until `read/2` asks for it, so nothing reaches the caller's mailbox
  and nothing is lost between reads.

  Standard input, output and error are connected unless `stdin: false`,
  `stdout: false` or `stderr: false` is given.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Never pass untrusted input to it; use
  > the list form instead. See the module documentation.

  ## Examples

      {:ok, program} = Exec.open("cat")

      Exec.write(program, "hello\\n")
      {:ok, {:stdout, "hello\\n"}} = Exec.read(program)

      Exec.write(program, :eof)
      {:ok, {:exit, 0}} = Exec.read(program)

  ## Options

  Accepts every option in `t:options/0`. `:timeout` is accepted and ignored —
  it applies to `run/2`. `read/2` takes its own timeout per call.

  ## Errors

    * `{:error, :empty_command}` - `command` was empty.
    * `{:error, {:exec, message}}` - the runner refused to start the command.

  Raises `ArgumentError` for any option the runner rejects, which includes a
  key it does not know.
  """
  @spec open(binary() | [binary()]) :: {:ok, t()} | {:error, term()}
  @spec open(binary() | [binary()], options()) :: {:ok, t()} | {:error, term()}
  def open(command, options \\ []) do
    {owner, options} = Keyword.pop(options, :owner, self())
    options = for {key, value} <- options, key not in [:timeout, :stream], do: {key, value}
    command = to_argv(command)

    case ProgramSupervisor.start_program(command, owner, options) do
      {:ok, program} -> {:ok, program}
      {:error, {:invalid_option, {key, value}}} -> raise ArgumentError, invalid_value(key, value)
      {:error, reason} -> {:error, normalize_start_error(reason)}
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
  Reads the next event from `program`.

  Blocks until an event arrives or `timeout` milliseconds pass. `timeout`
  defaults to `:infinity`. Events are held in order, so none is lost between
  calls.

  `{:ok, {:exit, status}}` is the last event a program produces. The handle is
  spent once it is read, and reading again exits the calling process.

  ## Examples

      {:ok, {:stdout, "line one\\n"}} = Exec.read(program)
      {:error, :timeout} = Exec.read(program, 0)

  ## Errors

    * `{:error, :timeout}` - no event arrived within `timeout`. The program is
      left running.
  """
  @spec read(t()) :: {:ok, event()} | {:error, :timeout}
  @spec read(t(), timeout()) :: {:ok, event()} | {:error, :timeout}
  def read(program, timeout \\ :infinity), do: Program.read(program, timeout)

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

  A program stopped this way reports exit status `0`, not a signal.

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
  `{:exit, {:signal, name}}`, so a signal sent by name comes back under that
  name.

  Unlike `stop/1` nothing is escalated: the signal sent is the signal asked for,
  and never a different one, to the program's whole process group.

  One of `:sighup`, `:sigint`, `:sigpipe` or `:sigterm` is sent again, though,
  as long as the program is still running and the call landed in the first 250
  milliseconds of the program's life. A single send can be swallowed there, so a
  program that handles one of those four that early may see it more than once.
  See the module documentation.

  A program that traps a signal is not protected from `signal/2` when its
  command was given as a binary. The `/bin/sh -c` wrapper shares the program's
  process group and traps nothing, so the wrapper dies and its exit is what
  `read/2` reports. Use the list form to signal a program that handles signals
  itself.

  ## Examples

      :ok = Exec.signal(program, :sigkill)
      :ok = Exec.signal(program, 9)

  ## Errors

    * `{:error, :not_running}` - the program had already ended.

  Raises `ArgumentError` for a name that is not a known signal: there is no
  number to send, and guessing one would signal something. An integer is sent as
  it stands, and one the operating system has no signal for comes back as
  `{:error, :einval}`. Signal `0` is accepted: it sends nothing and asks whether
  the program exists.
  """
  @spec signal(t(), atom() | non_neg_integer()) :: :ok | {:error, :not_running}
  def signal(program, signal), do: Program.kill(program, signal_to_int!(signal))

  @doc """
  Runs `command` to completion and returns its output.

  Consumes `stream/2` eagerly: the frames it yields are folded into a
  `t:Exec.Result.t/0` rather than handed to the caller one at a time.

  Returns `{:ok, %Exec.Result{}}` whenever the command ran, including when it
  exited non-zero. A non-zero exit is an outcome, not an error — `grep` finding
  nothing exits `1` — so the code is reported in the result rather than as
  `{:error, _}`.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Never pass untrusted input to it; use
  > the list form instead. See the module documentation.

  ## Examples

      iex> Exec.run("echo hi")
      {:ok, %Exec.Result{stdout: "hi\\n", stderr: "", exit_status: 0}}

      iex> {:ok, result} = Exec.run("exit 3")
      iex> result.exit_status
      3

  ## Options

  Accepts every option in `t:options/0`. `:timeout` bounds the whole call rather
  than the gap between two chunks, so a command that prints continuously still
  times out. It defaults to five minutes; pass `:infinity` for no bound. On
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

  Chunks are what the operating system delivered, not lines: one call may carry
  several lines or half of one, and a progress bar that only ever writes `\\r`
  arrives as it happens rather than being held back waiting for a delimiter.
  Use `stream/2` for whole lines. The callback runs in the calling process, in
  order, between reads — so a slow one spends the command's `:timeout`, and one
  that raises stops the program and raises through `run/2`. It is passed output
  only; starting, exiting and failing are `run/2`'s return value.

  ## Errors

    * `{:error, :timeout}` - the command outlived `:timeout` and was stopped.
    * `{:error, :empty_command}` - `command` was empty.
    * `{:error, {:exec, message}}` - the runner refused to start the command.

  Raises `ArgumentError` for any option the runner rejects, which includes a
  key it does not know.
  """
  @spec run(binary() | [binary()]) :: {:ok, Result.t()} | {:error, term()}
  @spec run(binary() | [binary()], options()) ::
          {:ok, Result.t()} | {:error, :timeout} | {:error, term()}
  def run(command, options \\ []) do
    noop = fn _ -> :ok end
    stream_func = options[:stream] || noop

    command
    |> stream_chunks(options)
    |> Enum.reduce_while({[], []}, fn
      {:ok, {:stdout, data}}, {out, err} ->
        stream_func.({:stdout, data})
        {:cont, {[data | out], err}}

      {:ok, {:stderr, data}}, {out, err} ->
        stream_func.({:stderr, data})
        {:cont, {out, [data | err]}}

      # Halting here rather than waiting for `:"$end_of_stream"` costs nothing: the frames
      # after a terminal one carry no output, and the stream stops the program
      # on a halt exactly as it does on exhaustion.
      {:ok, {:exit, status}}, {out, err} ->
        {:halt, {:ok, build_result(out, err, status)}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}

      :"$start_of_stream", acc ->
        {:cont, acc}
    end)
  end

  defp build_result(out, err, status) do
    %Result{
      stdout: out |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr: err |> Enum.reverse() |> IO.iodata_to_binary(),
      exit_status: status
    }
  end

  @doc """
  Runs `command` and returns its output as a lazy stream of frames.

  Nothing runs until enumeration begins, so a stream that is never enumerated
  never starts a program.

  Every enumeration is a frame: `:"$start_of_stream"` first, `:"$end_of_stream"` last, and in between the
  program's output as `{:ok, event}` and any failure as `{:error, reason}`.

      :"$start_of_stream"
      {:ok, {:stdout, "hello\\n"}}
      {:ok, {:stderr, "oops\\n"}}
      {:ok, {:exit, 0}}
      :"$end_of_stream"

  So a consumer can tell a command that ended from one that never started, and
  a stream that ran out from one that was cut short, without inspecting the
  program itself:

      Exec.stream("mix test")
      |> Enum.each(fn
        :"$start_of_stream" -> Logger.info("started")
        {:ok, {:stdout, line}} -> Logger.info(line)
        {:ok, {:stderr, line}} -> Logger.warning(line)
        {:ok, {:exit, status}} -> Logger.info("exited \#{inspect(status)}")
        {:error, reason} -> Logger.error("failed: \#{inspect(reason)}")
        :"$end_of_stream" -> Logger.info("done")
      end)

  Output is delivered as lines. They keep their delimiter, and a line that never
  gets one is emitted as it stands before the frame that ends the stream.
  Standard output and standard error are each in order, but not ordered relative
  to each other.

  A failure ends the stream: `{:error, reason}` is followed by `:"$end_of_stream"` and
  nothing else. There is no `{:ok, {:exit, _}}` in that case, because the
  program either never started or was stopped before it could exit.

  Halting early — through `Enum.take/2`, a `Enum.reduce_while/3` halt, or an
  exception — stops the program, and the frames after the halt are not emitted.
  A consumer that halted knows it halted; the absent `:"$end_of_stream"` says so to anyone
  further down the pipeline.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Never pass untrusted input to it; use
  > the list form instead. See the module documentation.

  ## Examples

      iex> ~S(printf 'a\\nb\\n') |> Exec.stream() |> Enum.to_list()
      [:"$start_of_stream", {:ok, {:stdout, "a\\n"}}, {:ok, {:stdout, "b\\n"}}, {:ok, {:exit, 0}}, :"$end_of_stream"]

      iex> Exec.stream("") |> Enum.to_list()
      [:"$start_of_stream", {:error, :empty_command}, :"$end_of_stream"]

      "tail -f /var/log/system.log"
      |> Exec.stream(timeout: :infinity)
      |> Stream.filter(&match?({:ok, {:stdout, _}}, &1))
      |> Enum.take(5)

  ## Options

  Accepts every option in `t:options/0`. `:timeout` bounds the whole
  enumeration, measured from when it begins rather than from when the stream is
  built, and defaults to five minutes as it does for `run/2`. A stream meant to
  outlive that — following a log, watching a queue — passes `:infinity`.
  `:stream` is ignored: these frames are the output, delivered as they
  arrive.

  ## Errors

  A failure to start and an expired `:timeout` are `{:error, reason}` frames,
  not exceptions, and carry the same reasons `run/2` returns. `ArgumentError` is
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
  # framing and the program's lifetime are written once and cannot drift apart.
  # It yields the operating system's chunks; assembling them into lines belongs
  # to stream/2, which is the only consumer that wants them.
  defp stream_chunks(command, options) do
    timeout = options[:timeout] || @default_timeout

    Stream.resource(
      # The deadline is stamped when enumeration begins, not when the stream is
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
      # so there is no program left to carry into the terminal state.
      {:ok, {:exit, _} = event} ->
        {[{:ok, event}], {:exit, nil}}

      {:ok, event} ->
        {[{:ok, event}], {:continue, program, deadline}}

      # The program outlived the budget. It is still running, and nothing will
      # read it again, so the terminal state carries it to be stopped.
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

      {:error, nil} ->
        :ok

      :"$end_of_stream" ->
        :ok
    end
  end

  # Output arrives in chunks, not lines, and one line can span two chunks, so
  # the trailing partial is carried to prepend to the next chunk.
  defp split_frame({:ok, {:stdout, data}}, {out, err}) do
    {lines, partial} = split_complete_lines(out <> data)
    {Enum.map(lines, &{:ok, {:stdout, &1}}), {partial, err}}
  end

  defp split_frame({:ok, {:stderr, data}}, {out, err}) do
    {lines, partial} = split_complete_lines(err <> data)
    {Enum.map(lines, &{:ok, {:stderr, &1}}), {out, partial}}
  end

  # A terminal frame is the last chance to emit a line that never got its
  # delimiter, so the partials go out ahead of it rather than being dropped.
  # That holds for a failure as much as for an exit: output a command produced
  # before it timed out is still output the caller asked for.
  defp split_frame({:ok, {:exit, _}} = frame, buffers), do: flush(buffers, frame)
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

  # Absolute, not per-read: a chatty program would reset a per-chunk timer on
  # every line and never time out.
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
  # An empty command is passed through unwrapped: erlexec rejects an empty
  # command itself (exec.cpp:404-405, "empty command provided"), but that check
  # inspects the first element of the argv it receives, and ["/bin/sh", "-c",
  # ""] is a three-element, non-empty argv. Wrapping "" would silently turn a
  # caller error into a program that runs and exits 0.
  defp to_argv(""), do: ""
  defp to_argv(command), do: ["/bin/sh", "-c", to_string(command)]

  # execve does not search PATH, so a bare name in list form is resolved here.
  # A name containing "/" is already a path; an unresolvable one is left alone
  # so the caller sees the real failure. String commands go to a shell, which
  # searches for itself.
  defp resolve_executable_path([exe | args]) do
    if String.contains?(exe, "/"),
      do: [exe | args],
      else: [System.find_executable(exe) || exe | args]
  end

  defp resolve_executable_path(command), do: command

  # Decodes the exit reason erlexec reports for a program. Kept here rather than
  # in Exec.Program because it reads the signal tables above backwards, and one
  # module owning both directions of that mapping is what keeps a name sent and
  # a name reported the same name.
  @doc false
  @spec decode_exit_reason(term()) :: exit_status() | term()
  def decode_exit_reason(:normal), do: 0

  def decode_exit_reason({:exit_status, raw}) do
    case Bitwise.band(raw, 0xFF) do
      0 -> Bitwise.bsr(raw, 8)
      _ -> {:signal, lookup_signal(Bitwise.band(raw, 0x7F))}
    end
  end

  def decode_exit_reason(other), do: other

  # A number the running system's table has no name for is returned as it
  # stands, which says less than a name but never says something false.
  defp lookup_signal(number) do
    signal_table()
    |> Enum.find_value(fn {name, n} -> if n === number, do: name end)
    |> Kernel.||(number)
  end

  # No entry in either platform map shares a number with an entry in the shared
  # map, so the reverse lookup above has exactly one answer.
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
