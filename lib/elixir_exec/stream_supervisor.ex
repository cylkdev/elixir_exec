defmodule ElixirExec.StreamSupervisor do
  @moduledoc """
  Internal — owns the worker processes that turn a running program's
  output into something you can iterate.

  You don't need to use this module directly. When you call
  `ElixirExec.stream/2`, the library asks this supervisor to start a
  fresh worker (`ElixirExec.Stream`) for the run, and returns you
  something built from `Stream.unfold/2` that you can pass to `Enum`
  or `Stream` functions. Each worker buffers one program's output as
  it arrives.

  ## What `start_stream/1` returns

  It returns `{:ok, server, enum}`:

    * `server` is the worker's process id. You hand this to
      `ElixirExec.Stream.attach/2` so the worker can watch the
      controller pid for exit.
    * `enum` pulls one element at a time out of the worker. When the
      worker has nothing left to give — including when it has already
      shut down for any normal reason — iteration ends cleanly rather
      than crashing.

  Workers are started as `:temporary`. If one exits, this supervisor
  does not restart it: there would be nothing to restart it for, since
  the program whose output it was buffering is also gone.
  """

  use DynamicSupervisor

  alias ElixirExec.Stream, as: StreamServer

  @typedoc "Result of `start_stream/1`."
  @type start_stream_result :: {:ok, pid(), Enumerable.t()} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Supervisor lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts the supervisor under the given (ignored) init argument and registers
  it under the module's own name.
  """
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_init_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a new `ElixirExec.Stream` worker in `mode` under this supervisor.

  Returns `{:ok, pid, enum}` on success, where `enum` is the `Enumerable.t()`
  the caller should iterate to drain the worker's output. The third element
  produced by `ElixirExec.Stream.start_link/1` (when present) is discarded:
  the supervisor builds its own unfold over the worker pid so the contract
  is identical regardless of how the worker chooses to surface the enum.

  Workers are started with `restart: :temporary`. A stream worker is
  meaningless without the upstream OS process whose output it buffers, and
  the supervisor cannot bring that process back. If the worker exits — for
  any reason — it is removed from the supervisor and not restarted.
  """
  @spec start_stream(StreamServer.mode()) :: start_stream_result()
  def start_stream(mode) do
    spec = Supervisor.child_spec({StreamServer, mode}, restart: :temporary)

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid, build_enum(pid)}

      {:ok, pid, _info} ->
        {:ok, pid, build_enum(pid)}

      {:error, _reason} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  # Build the Enumerable.t() that pulls one element at a time from the worker.
  # Mirrors the unfold step the worker would otherwise build itself, keeping
  # the StreamSupervisor's public API self-contained.
  @spec build_enum(pid()) :: Enumerable.t()
  defp build_enum(server) do
    Stream.unfold(server, &next_element/1)
  end

  # Pull the next element. Returns `nil` to terminate the unfold when the
  # worker reports end-of-stream OR when the worker has already exited
  # (`:noproc`, `:normal`, `:shutdown`) — those are all valid terminal states
  # for an `ElixirExec.Stream` GenServer and should produce a clean end of the
  # enumeration rather than a crash.
  @spec next_element(pid()) :: {term(), pid()} | nil
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
end
