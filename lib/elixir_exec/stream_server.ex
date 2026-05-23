defmodule ElixirExec.StreamServer do
  @moduledoc """
  Internal — receives a program's output messages and hands them to
  the consumer, one element at a time.

  When `ElixirExec` streams a program's output, it starts one of these
  workers and tells the underlying runner to deliver output here. The
  worker stores what arrives in a small buffer (see
  `ElixirExec.StreamServer.Buffer`) and hands elements out as the
  consumer asks for them. If the consumer asks while the buffer is
  empty, the call waits until more output arrives or the program
  exits.

  ## How a stream ends

  Call `attach/2` once with the controller pid of the running program.
  The worker calls `Process.monitor/1` on that pid *before* `attach/2`
  returns — so there is no window where the program could exit
  unobserved. When the program exits, the worker emits any output
  still in the buffer and then shuts down. The next iteration step
  sees the worker is gone and ends the iteration cleanly.

  ## Functions

    * `start_link/1` — start a fresh worker in one of the four modes.

    * `attach/2` — wire the worker up to the controller pid.

      Synchronous: by the time it returns, the monitor is in place.
    * `stop/1` — shut the worker down by hand.

  ## The four modes

  Each worker is started in one mode, picked once at construction:

    * `:lines` — read stdout, splitting on the configured delim
      (default `"\\n"`, override with `start_link(:lines, delim: ...)`).
      Each complete line keeps its trailing delim. Any unfinished tail
      is held back until either more stdout arrives or the program
      exits — on exit, a non-empty tail is emitted as the final
      element (without a trailing delim).

    * `:chunks` — read stdout, emitting each chunk exactly as it
      arrived from the program.

    * `:stderr` — like `:chunks` but for stderr.

    * `:merged` — read both stdout and stderr, tagged as
      `{:stdout, data}` or `{:stderr, data}` so you can tell them
      apart.
  """

  use GenServer

  alias ElixirExec.StreamServer.Buffer

  @typedoc "Stream mode. Determines which messages are buffered and the shape of emitted elements."
  @type mode :: :lines | :chunks | :stderr | :merged

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a linked stream server in `mode` and return the server pid plus an
  `Enumerable.t()` backed by `Stream.unfold/2`.

  Three call shapes are supported:

    * `start_link(mode)` — start with default options.

    * `start_link(mode, opts)` — pass options. In `:lines` mode, `:delim`
      (a non-empty binary, default `"\\n"`) controls how stdout is split
      into lines.

    * `start_link({mode, opts})` — tuple form for use with the default
      `child_spec/1` (e.g. `Supervisor.child_spec({__MODULE__, {mode,
      opts}}, ...)`).

  The caller (or whoever owns the erlexec process) is responsible for
  delivering `{:stdout, _, _}` / `{:stderr, _, _}` messages to `server`.
  Once the controlling port pid is wired in via `attach/2`, its `:DOWN`
  message will signal end-of-stream after the buffer drains.
  """
  @spec start_link({mode(), keyword()} | mode()) :: {:ok, pid(), Enumerable.t()}
  def start_link({mode, opts}) when is_list(opts), do: start_link(mode, opts)
  def start_link(mode) when is_atom(mode), do: start_link(mode, [])

  @spec start_link(mode(), keyword()) :: {:ok, pid(), Enumerable.t()}
  def start_link(mode, opts) when mode in [:lines, :chunks, :stderr, :merged] and is_list(opts) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {mode, opts})
    enum = Stream.unfold(pid, &next_element(&1, opts))
    {:ok, pid, enum}
  end

  @doc """
  Synchronously attach the upstream port pid that owns the OS process.

  The server installs `Process.monitor/1` on `port_pid` *before* replying.
  This eliminates the race in which the port pid could exit between the
  attach request and the monitor installation: by the time `attach/2`
  returns `:ok`, the monitor is in place.

  `opts[:timeout]` overrides the default `GenServer.call/3` timeout of
  `5_000` ms.
  """
  @spec attach(pid(), pid(), keyword()) :: :ok
  def attach(server, port_pid, opts \\ []) when is_pid(server) and is_pid(port_pid) do
    GenServer.call(server, {:attach, port_pid}, opts[:timeout] || 5_000)
  end

  @doc """
  Stop the stream server cleanly with reason `:shutdown`.

  Any parked consumer is released and the stream terminates. After this
  returns, the server pid is no longer alive.
  """
  @spec stop(pid()) :: :ok
  def stop(server) when is_pid(server) do
    GenServer.stop(server, :shutdown)
  end

  # ---------------------------------------------------------------------------
  # Stream.unfold/2 step
  # ---------------------------------------------------------------------------

  @doc """
  Pull the next element from `server` for use as a `Stream.unfold/2` step.

  Returns `{element, server}` while elements remain and `nil` once the
  server reports `:end_of_stream` — the shape `Stream.unfold/2` expects.

  `opts[:timeout]` overrides the default `GenServer.call/3` timeout of
  `:infinity`. A streaming consumer typically wants to wait indefinitely
  for the next element, so the default is `:infinity` rather than
  `5_000` ms.

  Catches the three exit reasons (`:noproc`, `:normal`, `:shutdown`)
  that mean the server has already shut down between elements, so the
  consumer sees a clean end of enumeration instead of a crash.
  """
  @spec next_element(pid(), keyword()) :: {Buffer.element(), pid()} | nil
  def next_element(server, opts \\ []) do
    case GenServer.call(server, :next, opts[:timeout] || :infinity) do
      :end_of_stream -> nil
      element -> {element, server}
    end
  catch
    :exit, {:noproc, _} -> nil
    :exit, {:normal, _} -> nil
    :exit, {:shutdown, _} -> nil
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({mode, opts}) do
    {:ok, Buffer.new(mode, opts)}
  end

  # --- attach (synchronous; installs monitor before replying) ---------------

  @impl true
  def handle_call({:attach, port_pid}, _from, %Buffer{} = state) do
    ref = Process.monitor(port_pid)
    {:reply, :ok, Buffer.attach(state, port_pid, ref)}
  end

  # --- next (consumer pulls the head, or parks if empty) --------------------

  def handle_call(:next, from, %Buffer{} = state) do
    case Buffer.pop(state) do
      {:ok, element, state2} ->
        {:reply, element, state2}

      :empty ->
        if Buffer.exhausted?(state) do
          {:stop, :shutdown, :end_of_stream, state}
        else
          {:noreply, Buffer.park(state, from)}
        end
    end
  end

  # --- erlexec-shaped inbound messages --------------------------------------

  @impl true
  def handle_info({:stdout, _os_pid, data}, %Buffer{} = state) when is_binary(data) do
    {:noreply, maybe_serve(Buffer.ingest_stdout(state, data))}
  end

  def handle_info({:stderr, _os_pid, data}, %Buffer{} = state) when is_binary(data) do
    {:noreply, maybe_serve(Buffer.ingest_stderr(state, data))}
  end

  # --- DOWN from the monitored port pid -------------------------------------

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %Buffer{monitor_ref: ref, port_pid: pid} = state
      ) do
    state = Buffer.mark_done(state)

    case state.client do
      nil -> {:noreply, state}
      from -> drain_to_client(state, from)
    end
  end

  # DOWN from an unrelated pid is ignored (e.g. stale monitor).
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %Buffer{} = state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  # When fresh data arrives and a consumer is parked, hand them the head.
  # A consumer can only be parked when the buffer was empty at the time of
  # the call, so after at least one ingest there is exactly one element to
  # serve.
  @spec maybe_serve(Buffer.t()) :: Buffer.t()
  defp maybe_serve(%Buffer{client: nil} = state), do: state

  defp maybe_serve(%Buffer{client: from} = state) do
    case Buffer.pop(state) do
      {:ok, element, state2} ->
        GenServer.reply(from, element)
        Buffer.clear_client(state2)

      :empty ->
        state
    end
  end

  # Called after `mark_done/1` when a consumer is parked: hand them the
  # next head if one exists, otherwise reply `:end_of_stream` and shut down.
  @spec drain_to_client(Buffer.t(), GenServer.from()) ::
          {:noreply, Buffer.t()} | {:stop, :shutdown, Buffer.t()}
  defp drain_to_client(%Buffer{} = state, from) do
    case Buffer.pop(state) do
      {:ok, element, state2} ->
        GenServer.reply(from, element)
        {:noreply, Buffer.clear_client(state2)}

      :empty ->
        GenServer.reply(from, :end_of_stream)
        {:stop, :shutdown, state}
    end
  end
end
