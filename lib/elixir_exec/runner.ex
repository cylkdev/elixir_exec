defmodule ElixirExec.Runner do
  @moduledoc """
  Internal — does the actual work of running a command for `ElixirExec`.

  You almost certainly do not need to call this directly. The functions
  in `ElixirExec` (like `run/2` and `stream/2`) call `run/3` here to do
  the real work.

  For each call, four things happen in order:

    1. The caller's options are checked (via `ElixirExec.Options`).
       Anything invalid is rejected before any program is started.
    2. The command and options are converted into the format the Erlang
       library `:erlexec` accepts (charlists and a proplist).
    3. The call is dispatched to `:exec.run/2` or `:exec.run_link/2`,
       depending on whether the caller wants a linked process or not.
    4. The response is wrapped into one of the public structs:
       `%ElixirExec.OSProcess{}` for a background run, or
       `%ElixirExec.Output{}` for a synchronous one.

  If the caller asked for `stdout: :stream`, this module also starts a
  small worker (`ElixirExec.Stream`) under
  `ElixirExec.StreamSupervisor`. The worker receives the program's
  output as it arrives and exposes it as something you can iterate. If
  `:erlexec` then refuses the command, the worker is shut down so it
  doesn't leak.

  ## What `run/3` returns

    * `{:ok, %ElixirExec.OSProcess{stream: nil}}` — normal background
      run.
    * `{:ok, %ElixirExec.OSProcess{stream: enum}}` — background run
      with streaming output.
    * `{:ok, %ElixirExec.Output{}}` — synchronous run.
    * `{:error, reason}` — option validation failed or `:erlexec`
      refused the command.
  """

  alias ElixirExec.{Options, Output, Stream, StreamSupervisor}
  alias ElixirExec.OSProcess, as: ExProcess

  @typedoc "Which `:exec` start function to call."
  @type kind :: :run | :run_link

  @typedoc "An external command — single string or `[exe | args]`."
  @type command :: String.t() | [String.t()]

  @typedoc "Return shape from `run/3`."
  @type result :: {:ok, ExProcess.t()} | {:ok, Output.t()} | {:error, term()}

  # Internal: the optional handle returned by `maybe_swap_stream/1`.
  # Either `nil` (no streaming requested) or `{server_pid, enum}` for a
  # live, supervised stream worker.
  @typep stream_handle :: nil | {pid(), Enumerable.t()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Validate, translate, and dispatch `command` via `:erlexec`.

  `kind` selects between `:exec.run/2` (`:run`) and `:exec.run_link/2`
  (`:run_link`). `command` is either a single binary or a `[exe | args]`
  list of binaries — both shapes are translated to the charlist
  representation `:erlexec` requires.

  See the module documentation for the full set of return shapes.
  """
  @spec run(kind(), command(), keyword()) :: result()
  def run(kind, command, options) when kind in [:run, :run_link] do
    with {:ok, validated} <- Options.validate_command(options) do
      {validated, stream_handle} = maybe_swap_stream(validated)
      erl_cmd = Options.to_erl_command(command)
      erl_opts = Options.to_erl_command_options(validated)
      finalize(dispatch(kind, erl_cmd, erl_opts), stream_handle)
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: dispatch
  # ---------------------------------------------------------------------------

  # Single-line wrappers around `:exec.run/2` and `:exec.run_link/2` so that
  # `run/3` does not have to branch on `kind` itself.
  @spec dispatch(kind(), charlist() | [charlist()], list()) :: term()
  defp dispatch(:run, cmd, opts), do: :exec.run(cmd, opts)
  defp dispatch(:run_link, cmd, opts), do: :exec.run_link(cmd, opts)

  # ---------------------------------------------------------------------------
  # Internal: maybe_swap_stream
  # ---------------------------------------------------------------------------

  # If the caller asked for `stdout: :stream`, start a supervised stream
  # worker in line-mode and rewrite the option to point `:erlexec` at the
  # worker's pid (the message-pid form). The worker pid + the unfold-backed
  # `Enumerable.t/0` are returned alongside the rewritten options so that
  # `finalize/2` can attach the worker to the eventual port pid.
  @spec maybe_swap_stream(keyword()) :: {keyword(), stream_handle()}
  defp maybe_swap_stream(opts) do
    case Keyword.get(opts, :stdout) do
      :stream ->
        {:ok, server, enum} = StreamSupervisor.start_stream(:lines)
        new_opts = Keyword.put(opts, :stdout, server)
        {new_opts, {server, enum}}

      _ ->
        {opts, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: finalize
  # ---------------------------------------------------------------------------

  # Async + stream wired in: attach the worker to the port pid (synchronous
  # call so the monitor is installed before we return), then surface the
  # struct with the live enum.
  @spec finalize(term(), stream_handle()) :: result()
  defp finalize({:ok, pid, os_pid}, {server, enum})
       when is_pid(pid) and is_integer(os_pid) do
    :ok = Stream.attach(server, pid)
    {:ok, %ExProcess{controller: pid, os_pid: os_pid, stream: enum}}
  end

  # Async, no stream: just wrap the controller pid and OS pid into a struct.
  defp finalize({:ok, pid, os_pid}, nil)
       when is_pid(pid) and is_integer(os_pid) do
    {:ok, %ExProcess{controller: pid, os_pid: os_pid}}
  end

  # Sync (`sync: true` was set; `:exec` returns the captured proplist).
  # `stream_handle` is always `nil` here because the
  # `sync: true` + `stdout: :stream` combination is rejected upstream.
  defp finalize({:ok, proplist}, nil) when is_list(proplist) do
    {:ok, Output.from_proplist(proplist)}
  end

  # Error from `:exec` with no stream worker started: surface unchanged.
  defp finalize({:error, _} = err, nil), do: err

  # Error from `:exec` after a stream worker was started: tear the worker
  # down so it doesn't leak, then surface the error.
  defp finalize({:error, _} = err, {server, _enum}) do
    :ok = Stream.stop(server)
    err
  end
end
