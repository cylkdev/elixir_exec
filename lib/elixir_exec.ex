defmodule ElixirExec do
  @moduledoc """
  Run OS processes from Elixir.

  Start a program, read from it, write to it, stop it:

      {:ok, conn} = ElixirExec.run("cat")

      ElixirExec.write(conn, "hello\\n")
      {:ok, {:stdout, "hello\\n"}} = ElixirExec.read(conn)

      ElixirExec.write(conn, :eof)
      {:ok, {:exit, 0}} = ElixirExec.read(conn)

  `capture/2` and `stream/2` are that loop written for you — one collects
  everything, the other hands it to you as it arrives.

  ## Lifetime

  A program never outlives the process that started it. If that process
  dies — including a brutal kill — the program is stopped. This holds for
  all three entry points.

  It is enforced by a monitor rather than a link, so the reverse is not
  true: a program failing or exiting non-zero never disturbs the process
  that started it.

  The guarantee does not survive the VM going down.
  """

  alias ElixirExec.{Connection, ConnectionSupervisor, Output}

  @typedoc """
  Options for the command, as a keyword list.

  `timeout: ms` is read by `capture/2` and `owner: pid` by `run/2`. Of the
  rest, these are forwarded to `:exec.run/2` unchanged: `:executable`, `:cd`,
  `:env`, `:kill`, `:kill_timeout`, `:group`, `:user`, `:nice`,
  `:success_exit_code`, `:winsz`, `:pty`, `:capabilities` and `:debug`. Any
  other key is ignored.

  `stdin: false`, `stdout: false` and `stderr: false` disconnect that stream
  from the program. All three default to `true`.
  """
  @type options :: keyword()

  @typedoc "A running program. Pass it back to `read/2`, `write/2`, `stop/1` and `kill/2`."
  @opaque conn :: pid()

  @typedoc "One thing a program produced. `status` is a shell exit code, or `{:signal, name}`."
  @type event :: {:stdout, binary()} | {:stderr, binary()} | {:exit, term()}

  @doc """
  Starts `command` and returns something to read from, write to, and stop.

  `command` is either a string, which a shell parses (so the shell handles
  PATH lookup, pipes, and redirection), or a list of strings, which is
  passed to `execve` directly with no shell involved. In list form, a bare
  executable name (no `/`) is resolved against `PATH` first, so
  `run(["echo", "hi"])` works the same as `run("echo hi")`. A name that
  contains `/` is used exactly as given.

  stdin, stdout and stderr are connected by default, so you can `write/2` to
  it and `read/2` from it without asking for anything. Pass `stdin: false`,
  `stdout: false` or `stderr: false` to leave one out.

  ## Lifetime

  The program is stopped if the process that started it dies — including a
  brutal kill. Pass `owner: pid` to tie it to some process other than the
  caller. The owner is held by a monitor, not a link, so the reverse is not
  true: a program failing or exiting non-zero never disturbs you.

      spawn(fn -> {:ok, _} = ElixirExec.run("sleep 3600") end)
      # that process exits immediately, and `sleep 3600` is killed with it.
  """
  @spec run(binary() | [binary()]) :: {:ok, conn()} | {:error, term()}
  @spec run(binary() | [binary()], options()) :: {:ok, conn()} | {:error, term()}
  def run(command, options \\ []) do
    {owner, options} = Keyword.pop(options, :owner, self())
    command = normalize_command(command)
    ConnectionSupervisor.start_supervised_connection(command, owner, options)
  end

  @doc """
  Reads the next thing the program produced.

  Blocks until there is something, or until `timeout` milliseconds pass.
  Output is held for you, so nothing is lost between reads.

      {:ok, {:stdout, "line one\\n"}} = ElixirExec.read(conn)
      {:error, :timeout} = ElixirExec.read(conn, 0)

  `{:ok, {:exit, status}}` is the last thing a program produces; reading past
  it is an error, because there is nothing left to read from.
  """
  @spec read(conn()) :: {:ok, event()} | {:error, :timeout}
  @spec read(conn(), timeout()) :: {:ok, event()} | {:error, :timeout}
  def read(conn, timeout \\ :infinity), do: Connection.read(conn, timeout)

  @doc """
  Writes to the program's standard input, or closes it with `:eof`.

  stdin is connected unless the program was started with `stdin: false`;
  without it the write is accepted and the data goes nowhere. A program that
  has already exited returns `{:error, reason}`.
  """
  @spec write(conn(), iodata() | :eof) :: :ok | {:error, term()}
  def write(conn, data), do: Connection.write(conn, data)

  @doc """
  Ends the program, gently.

  Sends `SIGTERM`, escalating to `SIGKILL` after about five seconds, so a
  program that ignores `SIGTERM` can take that long to die. Use `kill/2` with
  `9` when you need it gone immediately.
  """
  @spec stop(conn()) :: :ok | {:error, term()}
  def stop(conn), do: Connection.stop(conn)

  @doc """
  Sends `signal` to the program.

  `signal` is either an atom (`:sigterm`, `:sigkill`, `:sighup`) or the
  integer number. Unlike `stop/1` this is immediate — no escalation.
  """
  @spec kill(conn(), atom() | integer()) :: :ok | {:error, term()}
  def kill(conn, signal), do: Connection.kill(conn, signal)

  @doc """
  Runs `command` to completion and returns what it printed.

  `command` and `options` are handled as in `run/2`. `timeout: ms` bounds the
  whole call rather than the gap between two chunks, so a program that prints
  continuously still times out; on expiry the program is stopped.

  Returns `{:ok, %ElixirExec.Output{}}` whenever the command *ran* — including
  when it exited non-zero. A non-zero exit is a normal outcome (`grep` finding
  nothing), not an error, so the code is in the struct and you decide whether
  it matters.

  ## Examples

      iex> ElixirExec.capture("echo hi")
      {:ok, %ElixirExec.Output{stdout: ["hi\\n"], stderr: [], exit_status: 0}}

      iex> {:ok, output} = ElixirExec.capture("exit 3")
      iex> output.exit_status
      3
  """
  @spec capture(binary() | [binary()]) :: {:ok, Output.t()} | {:error, term()}
  @spec capture(binary() | [binary()], options()) ::
          {:ok, Output.t()} | {:error, :timeout} | {:error, term()}
  def capture(command, options \\ []) do
    with {:ok, conn} <- run(command, options) do
      collect(conn, [], [], deadline(options[:timeout] || :infinity))
    end
  end

  defp collect(conn, out, err, deadline) do
    case read(conn, time_left(deadline)) do
      {:ok, {:stdout, data}} ->
        collect(conn, [data | out], err, deadline)

      {:ok, {:stderr, data}} ->
        collect(conn, out, [data | err], deadline)

      {:ok, {:exit, status}} ->
        {:ok, %Output{stdout: Enum.reverse(out), stderr: Enum.reverse(err), exit_status: status}}

      {:error, :timeout} ->
        # This call started it, so nothing else is holding it.
        stop(conn)
        {:error, :timeout}
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  # Absolute, not per-read: a chatty program would reset a per-chunk timer on
  # every line and never time out.
  defp time_left(:infinity), do: :infinity
  defp time_left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  Runs `command` and returns its output as a lazy stream.

  `command` and `options` are handled as in `run/2`.

  Nothing runs until iteration begins, so a stream that is never consumed
  never starts a process.

  ## Elements

    * `{:stdout, line}` — one line, delimiter retained
    * `{:stderr, line}` — one line, delimiter retained
    * `{:exit_status, status}` — final element, emitted only when the
      program ends on its own

  stdout and stderr are each delivered in order, but **not** ordered relative
  to each other.

  If you stop early — `Enum.take/2`, `Enum.find/2`, a `reduce_while` halt, or
  an exception — the program is stopped and **no** `{:exit_status, _}` is
  emitted. That absence is meaningful: it distinguishes "I stopped reading"
  from "it finished".

  ## Errors

  Unlike `capture/2` and `run/2`, which return `{:error, reason}` when the
  command cannot be started, `stream/2` raises — a lazy stream has no
  `{:error, _}` channel to put it in.

  ## Examples

      "printf 'a\\nb\\n'"
      |> ElixirExec.stream()
      |> Enum.to_list()
      #=> [{:stdout, "a\\n"}, {:stdout, "b\\n"}, {:exit_status, 0}]

      "tail -f /var/log/system.log"
      |> ElixirExec.stream()
      |> Stream.each(&Logger.info/1)
      |> Enum.take(5)

  """
  @spec stream(binary() | [binary()]) :: Enumerable.t()
  @spec stream(binary() | [binary()], options()) :: Enumerable.t()
  def stream(command, options \\ []) do
    Stream.resource(
      fn ->
        case run(command, options) do
          {:ok, conn} -> {conn, "", ""}
          {:error, reason} -> raise "could not start the command: #{inspect(reason)}"
        end
      end,
      &stream_next/1,
      &stream_teardown/1
    )
  end

  defp stream_next(:done), do: {:halt, :done}

  defp stream_next({conn, out, err}) do
    case read(conn) do
      {:ok, {:stdout, data}} ->
        {lines, partial} = split_lines(out <> data)
        {Enum.map(lines, &{:stdout, &1}), {conn, partial, err}}

      {:ok, {:stderr, data}} ->
        {lines, partial} = split_lines(err <> data)
        {Enum.map(lines, &{:stderr, &1}), {conn, out, partial}}

      {:ok, {:exit, status}} ->
        {flush(:stdout, out) ++ flush(:stderr, err) ++ [{:exit_status, status}], :done}
    end
  end

  # Runs on halt, exhaustion and exception alike.
  defp stream_teardown(:done), do: :ok
  defp stream_teardown({conn, _out, _err}), do: stop(conn)

  # Output arrives in chunks, not lines, and one line can span two chunks, so
  # the trailing partial is returned to prepend to the next chunk.
  defp split_lines(buffer) do
    {complete, [partial]} = buffer |> String.split("\n") |> Enum.split(-1)
    {Enum.map(complete, &(&1 <> "\n")), partial}
  end

  defp flush(_tag, ""), do: []
  defp flush(tag, partial), do: [{tag, partial}]

  # erlexec builds the argv with a function accepting only binaries and lists
  # (exec.erl:1356); anything else raises function_clause inside the :exec
  # singleton, which is VM-wide and would take every other running program with
  # it.
  defp normalize_command(command) when is_list(command) do
    command |> Enum.map(&to_string/1) |> resolve_command()
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
  defp normalize_command(""), do: ""
  defp normalize_command(command), do: ["/bin/sh", "-c", to_string(command)]

  # execve does not search PATH, so a bare name in list form is resolved here.
  # A name containing "/" is already a path; an unresolvable one is left alone
  # so the caller sees the real failure. String commands go to a shell, which
  # searches for itself.
  defp resolve_command([exe | args]) do
    if String.contains?(exe, "/"),
      do: [exe | args],
      else: [System.find_executable(exe) || exe | args]
  end

  defp resolve_command(command), do: command
end
