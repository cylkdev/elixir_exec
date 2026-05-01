defmodule ElixirExec.Stream do
  @moduledoc """
  Internal — receives a program's output messages and serves them to
  whoever is iterating, one element at a time.

  When you ask `ElixirExec` to stream a program's output, the library
  starts one of these and tells the underlying Erlang library
  (`:erlexec`) to send the program's output here. This module saves
  what arrives into a small buffer (see `ElixirExec.Stream.Buffer`) and
  hands the elements out as the consumer asks for them. If the
  consumer asks while the buffer is empty, the call waits until either
  more output arrives or the program exits.

  ## How a stream ends

  Call `attach/2` once with the controller pid of the running program.
  This module watches that pid for exit using `Process.monitor/1`, and
  it installs the watch *before* `attach/2` returns — so there's no
  window where the program could exit before being watched. When the
  program does exit, the worker emits any output still in the buffer
  and then shuts down. The next iteration step sees the worker is
  gone and ends the iteration cleanly.

  ## Functions you'll use

    * `start_link/1` — start a fresh worker in one of the four modes.
    * `attach/2` — wire it up to the controller pid. Synchronous: by
      the time it returns, the watch is in place.
    * `stop/1` — shut the worker down by hand.

  ## The four modes

  Each worker is started in one mode, picked once at construction:

    * `:lines` — read stdout, splitting on `"\\n"`. Each complete line
      keeps its trailing newline. Any unfinished tail is held back
      until either more stdout arrives or the program exits — on exit,
      a non-empty tail is emitted as the final element.
    * `:chunks` — read stdout, emitting each chunk exactly as it
      arrived from the program.
    * `:stderr` — like `:chunks` but for stderr.
    * `:merged` — read both stdout and stderr, tagged as
      `{:stdout, data}` or `{:stderr, data}` so you can tell them
      apart.
  """

  use GenServer

  alias ElixirExec.Stream.Buffer

  @typedoc "Stream mode. Determines which messages are buffered and the shape of emitted elements."
  @type mode :: :lines | :chunks | :stderr | :merged

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a linked stream server in `mode` and return the server pid plus an
  `Enumerable.t()` backed by `Stream.unfold/2`.

  The caller (or whoever owns the erlexec process) is responsible for
  delivering `{:stdout, _, _}` / `{:stderr, _, _}` messages to `server`.
  Once the controlling port pid is wired in via `attach/2`, its `:DOWN`
  message will signal end-of-stream after the buffer drains.
  """
  @spec start_link(mode()) :: {:ok, pid(), Enumerable.t()}
  def start_link(mode) when mode in [:lines, :chunks, :stderr, :merged] do
    {:ok, pid} = GenServer.start_link(__MODULE__, mode)
    enum = Stream.unfold(pid, &next_element/1)
    {:ok, pid, enum}
  end

  @doc """
  Synchronously attach the upstream port pid that owns the OS process.

  The server installs `Process.monitor/1` on `port_pid` *before* replying.
  This eliminates the race in which the port pid could exit between the
  attach request and the monitor installation: by the time `attach/2`
  returns `:ok`, the monitor is in place.
  """
  @spec attach(pid(), pid()) :: :ok
  def attach(server, port_pid) when is_pid(server) and is_pid(port_pid) do
    GenServer.call(server, {:attach, port_pid})
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

  # The only consumer-side primitive. Catches the three benign exit reasons
  # that occur when the server has already shut down between elements,
  # letting `Enum` cleanly produce `[]` rather than raising.
  @spec next_element(pid()) :: {Buffer.element(), pid()} | nil
  defp next_element(server) do
    case GenServer.call(server, :next, :infinity) do
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
  def init(mode) do
    {:ok, Buffer.new(mode)}
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
