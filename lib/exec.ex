defmodule Exec do
  @moduledoc """
  Runs and controls operating system processes.

  Three entry points, in increasing order of control:

    * `run/2` runs a command to completion and returns its output.
    * `stream!/2` runs a command and yields its output lazily, line by line.
    * `open/2` starts a command and returns a handle for `read/2`, `write/2`,
      `stop/1` and `signal/2`.

  `run/2` and `stream!/2` are both written in terms of `open/2` and `read/2`.

      iex> {:ok, result} = Exec.run("echo hello")
      iex> result.stdout
      "hello\\n"

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

  ## Lifetime

  A program never outlives the process that started it. If that process dies,
  including under `Process.exit(pid, :kill)`, the program is stopped. This holds
  for `run/2`, `stream!/2` and `open/2` alike, and does not survive the VM
  itself going down.

  Each program runs in a process group of its own, and `stop/1` and `signal/2`
  act on that group. A binary command therefore takes the shell and everything
  the shell started with it, rather than leaving the real work orphaned.

  The reverse does not hold: a program that fails or exits non-zero does not
  disturb the process that started it.

  Pass `owner: pid` to tie a program's lifetime to a process other than the
  caller.

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

  # Read by this module, never forwarded to :exec.run/2.
  @own_options [:timeout, :owner, :stdin, :stdout, :stderr]

  # Passed to :exec.run/2 unchanged. Documented in this module's own terms; see
  # the `options` typedoc.
  @forwarded_options [
    :executable,
    :cd,
    :env,
    :kill,
    :kill_timeout,
    :user,
    :nice,
    :success_exit_code,
    :winsz,
    :pty,
    :capabilities,
    :debug
  ]

  @typedoc """
  Options for a command, as a keyword list.

  Read by this module:

    * `:timeout` - milliseconds bounding a whole `run/2` call. Defaults to
      `:infinity`. Ignored by `stream!/2` and `open/2`, which have no total
      duration to bound.
    * `:owner` - the process whose death stops the program. Defaults to the
      calling process.
    * `:stdin`, `:stdout`, `:stderr` - whether to connect that stream to the
      program. Each defaults to `true`. A program started with `stdout: false`
      produces no `{:stdout, _}` events at all.

  Forwarded to the underlying runner unchanged: `:executable`, `:cd`, `:env`,
  `:kill`, `:kill_timeout`, `:user`, `:nice`, `:success_exit_code`,
  `:winsz`, `:pty`, `:capabilities` and `:debug`. See
  [erlexec](https://hexdocs.pm/erlexec/exec.html) for their meanings.

  `:group` is not accepted. This module sets it, so that `stop/1` and
  `signal/2` reach the program's whole process group.

  Any other key raises `ArgumentError`, as does a value the runner rejects.
  """
  @type options :: keyword()

  @typedoc "A running program, as returned by `open/2`."
  @opaque t :: pid()

  @typedoc "How a command ended: an exit code, or `{:signal, name}` if a signal killed it."
  @type exit_status :: non_neg_integer() | {:signal, atom() | pos_integer()}

  @typedoc "One thing a program produced, as returned by `read/2`."
  @type event :: {:stdout, binary()} | {:stderr, binary()} | {:exit, exit_status()}

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

  Raises `ArgumentError` for an unknown option key or a value the runner
  rejects.
  """
  @spec open(binary() | [binary()]) :: {:ok, t()} | {:error, term()}
  @spec open(binary() | [binary()], options()) :: {:ok, t()} | {:error, term()}
  def open(command, options \\ []) do
    validate_options!(options)
    {owner, options} = Keyword.pop(options, :owner, self())
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

  # A dropped option is an invisible bug: the command runs, quietly ignoring the
  # `cd:` that was meant to place it. System.cmd/3 raises here too.
  defp validate_options!(options) do
    known = @own_options ++ @forwarded_options

    case options |> Keyword.keys() |> Enum.find(&(&1 not in known)) do
      nil -> :ok
      key -> raise ArgumentError, "unknown option #{inspect(key)}"
    end
  end

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

  Returns `{:error, reason}` if the program has already exited. A program
  started with `stdin: false` accepts the write and discards it.

  ## Examples

      :ok = Exec.write(program, "hello\\n")
      :ok = Exec.write(program, :eof)
  """
  @spec write(t(), iodata() | :eof) :: :ok | {:error, term()}
  def write(program, data), do: Program.write(program, data)

  @doc """
  Ends `program` gracefully.

  Sends `SIGTERM` and escalates to `SIGKILL` after roughly five seconds, so a
  program that ignores `SIGTERM` can take that long to end. The `:kill_timeout`
  option changes that delay. `signal/2` with `:sigkill` ends it immediately.

  A program stopped this way reports exit status `0`, not a signal.
  """
  @spec stop(t()) :: :ok | {:error, term()}
  def stop(program), do: Program.stop(program)

  @doc """
  Sends `signal` to `program`.

  `signal` is an atom such as `:sigterm`, `:sigkill` or `:sighup`, or the
  integer number. Unlike `stop/1` nothing is escalated: exactly one signal is
  sent.

  ## Examples

      :ok = Exec.signal(program, :sigkill)
      :ok = Exec.signal(program, 9)
  """
  @spec signal(t(), atom() | integer()) :: :ok | {:error, term()}
  def signal(program, signal), do: Program.kill(program, signal)

  @doc """
  Runs `command` to completion and returns its output.

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
  times out. On expiry the program is stopped:

      iex> Exec.run("sleep 30", timeout: 200)
      {:error, :timeout}

  ## Errors

    * `{:error, :timeout}` - the command outlived `:timeout` and was stopped.
    * `{:error, :empty_command}` - `command` was empty.
    * `{:error, {:exec, message}}` - the runner refused to start the command.

  Raises `ArgumentError` for an unknown option key or a value the runner
  rejects.
  """
  @spec run(binary() | [binary()]) :: {:ok, Result.t()} | {:error, term()}
  @spec run(binary() | [binary()], options()) ::
          {:ok, Result.t()} | {:error, :timeout} | {:error, term()}
  def run(command, options \\ []) do
    with {:ok, program} <- open(command, options) do
      read_until_exit(program, [], [], deadline_after(options[:timeout] || :infinity))
    end
  end

  defp read_until_exit(program, out, err, deadline) do
    case read(program, remaining_timeout(deadline)) do
      {:ok, {:stdout, data}} ->
        read_until_exit(program, [data | out], err, deadline)

      {:ok, {:stderr, data}} ->
        read_until_exit(program, out, [data | err], deadline)

      {:ok, {:exit, status}} ->
        {:ok,
         %Result{
           stdout: out |> Enum.reverse() |> IO.iodata_to_binary(),
           stderr: err |> Enum.reverse() |> IO.iodata_to_binary(),
           exit_status: status
         }}

      {:error, :timeout} ->
        # This call started it and nothing else is holding it, and there is
        # nothing left to read, so the program's process goes too.
        _ = Program.shutdown(program)
        {:error, :timeout}
    end
  end

  defp deadline_after(:infinity), do: :infinity
  defp deadline_after(timeout), do: System.monotonic_time(:millisecond) + timeout

  # Absolute, not per-read: a chatty program would reset a per-chunk timer on
  # every line and never time out.
  defp remaining_timeout(:infinity), do: :infinity
  defp remaining_timeout(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  Runs `command` and returns its output as a lazy stream of lines.

  Nothing runs until enumeration begins, so a stream that is never enumerated
  never starts a program.

  Elements are `{:stdout, line}`, `{:stderr, line}`, and a final
  `{:exit, status}`. Lines keep their delimiter, and a final line without one is
  emitted as it stands. Standard output and standard error are each in order,
  but not ordered relative to each other.

  The `{:exit, status}` element is emitted only when the program ends on its
  own. Halting early — through `Enum.take/2`, a `Enum.reduce_while/3` halt, or
  an exception — stops the program and emits no exit element. That absence
  distinguishes a halted enumeration from a finished program.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Never pass untrusted input to it; use
  > the list form instead. See the module documentation.

  ## Examples

      iex> ~S(printf 'a\\nb\\n') |> Exec.stream!() |> Enum.to_list()
      [stdout: "a\\n", stdout: "b\\n", exit: 0]

      "tail -f /var/log/system.log"
      |> Exec.stream!()
      |> Stream.filter(&match?({:stdout, _}, &1))
      |> Enum.take(5)

  ## Options

  Accepts every option in `t:options/0`. `:timeout` is accepted and ignored —
  a lazy stream has no total duration to apply to.

  ## Errors

  Raises `Exec.Error` when the command cannot be started, rather than returning
  `{:error, reason}` as `run/2` and `open/2` do: a lazy stream has no error
  channel. Raises `ArgumentError` for an unknown option key or a value the
  runner rejects.
  """
  @spec stream!(binary() | [binary()]) :: Enumerable.t()
  @spec stream!(binary() | [binary()], options()) :: Enumerable.t()
  def stream!(command, options \\ []) do
    Stream.resource(
      fn ->
        case open(command, options) do
          {:ok, program} -> {program, "", ""}
          {:error, reason} -> raise Exec.Error, reason: reason
        end
      end,
      &emit_lines/1,
      &stop_unless_exited/1
    )
  end

  defp emit_lines(:done), do: {:halt, :done}

  defp emit_lines({program, out, err}) do
    case read(program) do
      {:ok, {:stdout, data}} ->
        {lines, partial} = split_complete_lines(out <> data)
        {Enum.map(lines, &{:stdout, &1}), {program, partial, err}}

      {:ok, {:stderr, data}} ->
        {lines, partial} = split_complete_lines(err <> data)
        {Enum.map(lines, &{:stderr, &1}), {program, out, partial}}

      {:ok, {:exit, status}} ->
        {trailing_line(:stdout, out) ++ trailing_line(:stderr, err) ++ [{:exit, status}], :done}
    end
  end

  # Runs on halt, exhaustion and exception alike.
  defp stop_unless_exited(:done), do: :ok
  # The stream owns the program, and a halted stream will never read again, so
  # the program's process is terminated rather than left holding its queue.
  defp stop_unless_exited({program, _out, _err}), do: Program.shutdown(program)

  # Output arrives in chunks, not lines, and one line can span two chunks, so
  # the trailing partial is returned to prepend to the next chunk.
  defp split_complete_lines(buffer) do
    {complete, [partial]} = buffer |> String.split("\n") |> Enum.split(-1)
    {Enum.map(complete, &(&1 <> "\n")), partial}
  end

  defp trailing_line(_tag, ""), do: []
  defp trailing_line(tag, partial), do: [{tag, partial}]

  # erlexec builds the argv with a function accepting only binaries and lists
  # (exec.erl:1356); anything else raises function_clause inside the :exec
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
  # command itself (exec.cpp:401, "empty command provided"), but that check
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
end
