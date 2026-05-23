defmodule ElixirExec.Core do
  @moduledoc """
  Internal — runs a command on behalf of `ElixirExec`.

  Each call to `run/3` does four things in order:

    1. Validates the caller's options (via `ElixirExec.Options`).
       Invalid options are rejected before any program starts.
    2. Translates the command and options into the charlists and
       proplist the underlying runner expects.
    3. Dispatches to `:exec.run/2` or `:exec.run_link/2`, depending on
       whether the caller asked for a linked process.
    4. Wraps the result into `%ElixirExec.Handle{}` for a background
       run or `%ElixirExec.Output{}` for a synchronous one.

  When the caller asks for `stdout: :stream`, this module also starts
  an `ElixirExec.StreamServer` worker under
  `ElixirExec.StreamSupervisor`. The worker receives the program's
  output and exposes it as an `Enumerable`. If the runner then refuses
  the command, the worker is shut down so nothing leaks.

  ## Return values

    * `{:ok, %ElixirExec.Handle{stream: nil}}` — plain background run.

    * `{:ok, %ElixirExec.Handle{stream: enum}}` — background run with
      streaming output.

    * `{:ok, %ElixirExec.Output{}}` — synchronous run.

    * `{:error, reason}` — option validation failed, or the runner
      refused the command.
  """

  alias ElixirExec.{Handle, Options, Output, StreamServer, StreamSupervisor}

  @typedoc "Which `:exec` start function to call."
  @type kind :: :run | :run_link

  @typedoc "An external command — single string or `[exe | args]`."
  @type command :: String.t() | [String.t()]

  @typedoc "Return shape from `run/3`."
  @type result :: {:ok, Handle.t()} | {:ok, Output.t()} | {:error, term()}

  # Internal: the optional handle returned by `start_stream/1`.
  # Either `nil` (no streaming requested) or `{server_pid, enum}` for a
  # live, supervised stream worker.
  @typep stream_handle :: nil | {pid(), Enumerable.t()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Validates, translates, and dispatches `command`.

  `kind` picks between `:exec.run/2` (when `:run`) and
  `:exec.run_link/2` (when `:run_link`). `command` is a string or a
  `[exe | args]` list of strings; both shapes are translated to the
  charlists the runner needs.

  See the module doc for the full set of return shapes.
  """
  @spec run(kind(), command(), keyword()) :: result()
  def run(kind, command, options) when kind in [:run, :run_link] do
    with {:ok, valid_cmd_opts} <- Options.validate_command(options) do
      stream? = Keyword.get(valid_cmd_opts, :stdout) === :stream

      {rewritten, stream_handle} =
        if stream? do
          start_stream(valid_cmd_opts)
        else
          {valid_cmd_opts, nil}
        end

      erl_cmd = Options.to_erl_command(command)
      erl_opts = Options.to_erl_command_options(rewritten)

      kind
      |> dispatch(erl_cmd, erl_opts)
      |> finalize(stream_handle, valid_cmd_opts)
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
  # Internal: start_stream
  # ---------------------------------------------------------------------------

  # If the caller asked for `stdout: :stream`, start a supervised stream
  # worker in line-mode and rewrite the option to point `:erlexec` at the
  # worker's pid (the message-pid form). The worker pid + the unfold-backed
  # `Enumerable.t/0` are returned alongside the rewritten options so that
  # `finalize/3` can attach the worker to the eventual port pid.
  @spec start_stream(keyword()) :: {keyword(), stream_handle()}
  defp start_stream(opts) do
    delim = Keyword.fetch!(opts, :delim)

    {:ok, server, enum} =
      case StreamSupervisor.start_dispatcher(:lines, delim: delim) do
        {:ok, pid, _info} ->
          {:ok, pid, build_enum(pid, opts)}

        {:error, _reason} = error ->
          error
      end

    new_opts = Keyword.put(opts, :stdout, server)
    {new_opts, {server, enum}}
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  # Build the Enumerable.t() that pulls one element at a time from the worker.
  # Delegates the unfold step to `StreamServer.next_element/2` so there is
  # exactly one source of truth for the consumer-side primitive. Threads
  # `opts` so `opts[:timeout]` reaches the underlying `GenServer.call/3`.
  @spec build_enum(pid(), keyword()) :: Enumerable.t()
  defp build_enum(server, opts) do
    Stream.unfold(server, &StreamServer.next_element(&1, opts))
  end

  # ---------------------------------------------------------------------------
  # Internal: finalize
  # ---------------------------------------------------------------------------

  # Async + stream wired in: attach the worker to the port pid (synchronous
  # call so the monitor is installed before we return), then surface the
  # struct with the live enum. When `:drain` is true (the schema default),
  # wrap the enum with `ElixirExec.StreamServer.Drain.attach/2` so iteration's
  # finalizer drains the caller-side `:DOWN` left in the mailbox by the
  # forced `monitor: true`.
  @spec finalize(term(), stream_handle(), keyword()) :: result()
  defp finalize({:ok, pid, os_pid}, {server, enum}, valid_cmd_opts)
       when is_pid(pid) and is_integer(os_pid) do
    :ok = StreamServer.attach(server, pid, valid_cmd_opts)

    enum =
      if Keyword.fetch!(valid_cmd_opts, :drain) do
        StreamServer.Drain.attach(enum, os_pid)
      else
        enum
      end

    {:ok, %Handle{controller: pid, os_pid: os_pid, stream: enum}}
  end

  # Async, no stream: just wrap the controller pid and OS pid into a struct.
  defp finalize({:ok, pid, os_pid}, nil, _valid_cmd_opts)
       when is_pid(pid) and is_integer(os_pid) do
    {:ok, %Handle{controller: pid, os_pid: os_pid}}
  end

  # Sync (`sync: true` was set; `:exec` returns the captured proplist).
  # `stream_handle` is always `nil` here because the
  # `sync: true` + `stdout: :stream` combination is rejected upstream.
  defp finalize({:ok, proplist}, nil, _valid_cmd_opts) when is_list(proplist) do
    {:ok, Output.from_proplist(proplist)}
  end

  # Error from `:exec` with no stream worker started: surface unchanged.
  defp finalize({:error, _} = err, nil, _valid_cmd_opts), do: err

  # Error from `:exec` after a stream worker was started: tear the worker
  # down so it doesn't leak, then surface the error.
  defp finalize({:error, _} = err, {server, _enum}, _valid_cmd_opts) do
    :ok = StreamServer.stop(server)
    err
  end
end
