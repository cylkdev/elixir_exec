defmodule ElixirExec.StreamSupervisor do
  @moduledoc """
  Internal — owns the worker processes that turn a program's output
  into an iterable stream.

  `ElixirExec.stream/2` asks this supervisor to start a fresh worker
  (`ElixirExec.StreamServer`) for the run. Each worker buffers one
  program's output as it arrives.

  ## What `start_dispatcher/2` returns

  Returns `{:ok, server, enum}`:

    * `server` is the worker's process id. Hand it to
      `ElixirExec.StreamServer.attach/2` so the worker can watch the
      controller pid for exit.

    * `enum` pulls one element at a time out of the worker. When the
      worker has nothing left to give — including when it has already
      shut down — iteration ends cleanly rather than crashing.

  Workers are started as `:temporary`. If one exits, the supervisor
  does not restart it: the program whose output it was buffering is
  gone too, so there is nothing left to serve.
  """

  use DynamicSupervisor

  alias ElixirExec.StreamServer

  @typedoc "Result of `start_dispatcher/1`."
  @type start_dispatcher_result :: {:ok, pid(), Enumerable.t()} | {:error, term()}

  @name __MODULE__
  @genserver_opts_keys [
    :debug,
    :name,
    :timeout,
    :spawn_opt,
    :hibernate_after
  ]

  # ---------------------------------------------------------------------------
  # Supervisor lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts the supervisor and registers it under the module's own name.

  Recognised keys in `opts` that match `GenServer` startup options
  (`:debug`, `:name`, `:timeout`, `:spawn_opt`, `:hibernate_after`)
  are forwarded to `DynamicSupervisor.start_link/3`. Other keys are
  passed to `init/1` and currently ignored.
  """
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {genserver_opts, init_opts} = Keyword.split(opts, @genserver_opts_keys)
    genserver_opts = Keyword.put(genserver_opts, :name, @name)
    DynamicSupervisor.start_link(__MODULE__, init_opts, genserver_opts)
  end

  @impl DynamicSupervisor
  def init(opts) do
    opts
    |> Keyword.put(:strategy, :one_for_one)
    |> DynamicSupervisor.init()
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a new `ElixirExec.StreamServer` worker in `mode` under this
  supervisor.

  `opts` is forwarded to `ElixirExec.StreamServer.Buffer.new/2`. In
  `:lines` mode the only meaningful option today is `:delim` — a
  non-empty binary, default `"\\n"` — that controls how stdout chunks
  are split into lines.

  Returns `{:ok, pid, enum}` on success. The caller iterates `enum`
  to drain the worker's output.

  Workers are started with `restart: :temporary`. Without the OS
  process whose output it was buffering, a stream worker has nothing
  to do, and the supervisor cannot bring that process back — so if a
  worker exits for any reason, it is removed and not restarted.
  """
  @spec start_dispatcher(StreamServer.mode(), keyword()) :: start_dispatcher_result()
  def start_dispatcher(mode, opts \\ []) when is_list(opts) do
    spec = Supervisor.child_spec({StreamServer, {mode, opts}}, restart: :temporary)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
