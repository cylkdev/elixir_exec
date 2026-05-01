defmodule ElixirExec.Stream.Buffer do
  @moduledoc """
  Internal — the data structure that holds buffered output for one
  stream.

  This module is just data and functions on data. It never starts a
  process, sends a message, or watches anyone for exit. Its job is to
  remember what output has arrived but not yet been read, and to
  decide what the next element to emit should be. The
  `ElixirExec.Stream` worker is the one that talks to the outside
  world; it calls into this module to update the buffer.

  ## Modes

  Each buffer is built in one of four modes, picked once at
  construction:

    * `:chunks` — stdout chunks are stored as raw strings, in the
      order they arrived. Stderr is dropped.
    * `:lines` — stdout chunks are stitched together and split on
      `"\\n"`. Each complete line keeps its trailing newline and is
      queued for emission. Any leftover tail (the bytes after the
      last newline) is held in the `:partial` field until either more
      stdout arrives or the program exits. On exit, a non-empty tail
      is queued as the final element. Stderr is dropped.
    * `:stderr` — stderr chunks are stored as raw strings. Stdout is
      dropped.
    * `:merged` — both channels are stored, each chunk tagged as
      `{:stdout, data}` or `{:stderr, data}`.

  ## Functions

    * `new/1` — build an empty buffer in a chosen mode.
    * `attach/3` — remember the program's controller pid and the
      reference returned when the owning worker watched it for exit.
      (This module just stores them; the actual watch is set up by
      the worker.)
    * `ingest_stdout/2` and `ingest_stderr/2` — feed in a chunk that
      arrived on the relevant channel.
    * `pop/1` — take the next element off the front of the queue.
      Returns `:empty` when there is nothing to give.
    * `park/2` and `clear_client/1` — remember (and later forget)
      that one consumer is waiting for the next element.
    * `mark_done/1` — note that the program has exited. In `:lines`
      mode this also flushes any partial tail onto the queue.
    * `exhausted?/1` — true once the program has exited and the queue
      is empty.

  ## Example

      iex> buffer = ElixirExec.Stream.Buffer.new(:chunks)
      iex> buffer.mode
      :chunks
      iex> :queue.is_empty(buffer.queue)
      true
  """

  @typedoc "Stream mode."
  @type mode :: :lines | :chunks | :stderr | :merged

  @typedoc "Element emitted by `pop/1`. Shape depends on `mode`."
  @type element :: binary() | {:stdout, binary()} | {:stderr, binary()}

  @typedoc "Buffer state."
  @type t :: %__MODULE__{
          mode: mode(),
          queue: :queue.queue(element()),
          partial: binary(),
          done: boolean(),
          client: nil | GenServer.from(),
          port_pid: nil | pid(),
          monitor_ref: nil | reference()
        }

  @enforce_keys [:mode, :queue]
  defstruct mode: nil,
            queue: nil,
            partial: "",
            done: false,
            client: nil,
            port_pid: nil,
            monitor_ref: nil

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc """
  Build a fresh buffer in `mode`.

  ## Examples

      iex> buffer = ElixirExec.Stream.Buffer.new(:chunks)
      iex> buffer.mode
      :chunks
      iex> :queue.is_empty(buffer.queue)
      true
  """
  @spec new(mode()) :: t()
  def new(mode) when mode in [:lines, :chunks, :stderr, :merged] do
    %__MODULE__{mode: mode, queue: :queue.new()}
  end

  # ---------------------------------------------------------------------------
  # Attach a port pid + monitor reference
  # ---------------------------------------------------------------------------

  @doc """
  Record the upstream port pid and the monitor reference the owning
  GenServer has installed for it.

  This is pure bookkeeping: the buffer does not call `Process.monitor/1`
  itself. The fields are retained so the owning GenServer can match the
  `:DOWN` message it later receives.
  """
  @spec attach(t(), pid(), reference()) :: t()
  def attach(%__MODULE__{} = buffer, port_pid, monitor_ref)
      when is_pid(port_pid) and is_reference(monitor_ref) do
    %{buffer | port_pid: port_pid, monitor_ref: monitor_ref}
  end

  # ---------------------------------------------------------------------------
  # Ingestion
  # ---------------------------------------------------------------------------

  @doc """
  Feed a stdout chunk into the buffer.

  In `:chunks` mode the binary is enqueued as-is. In `:merged` mode it is
  tagged `{:stdout, data}`. In `:lines` mode it is combined with the current
  partial fragment and split on `"\\n"`. In `:stderr` mode it is dropped.
  """
  @spec ingest_stdout(t(), binary()) :: t()
  def ingest_stdout(buffer, data)

  def ingest_stdout(%__MODULE__{mode: :chunks} = buffer, data) when is_binary(data) do
    enqueue(buffer, data)
  end

  def ingest_stdout(%__MODULE__{mode: :merged} = buffer, data) when is_binary(data) do
    enqueue(buffer, {:stdout, data})
  end

  def ingest_stdout(%__MODULE__{mode: :lines} = buffer, data) when is_binary(data) do
    ingest_lines(buffer, data)
  end

  def ingest_stdout(%__MODULE__{mode: :stderr} = buffer, data) when is_binary(data) do
    buffer
  end

  @doc """
  Feed a stderr chunk into the buffer.

  In `:stderr` mode the binary is enqueued as-is. In `:merged` mode it is
  tagged `{:stderr, data}`. In `:chunks` and `:lines` modes it is dropped.
  """
  @spec ingest_stderr(t(), binary()) :: t()
  def ingest_stderr(buffer, data)

  def ingest_stderr(%__MODULE__{mode: :stderr} = buffer, data) when is_binary(data) do
    enqueue(buffer, data)
  end

  def ingest_stderr(%__MODULE__{mode: :merged} = buffer, data) when is_binary(data) do
    enqueue(buffer, {:stderr, data})
  end

  def ingest_stderr(%__MODULE__{mode: mode} = buffer, data)
      when mode in [:chunks, :lines] and is_binary(data) do
    buffer
  end

  # ---------------------------------------------------------------------------
  # Consumer-facing operations
  # ---------------------------------------------------------------------------

  @doc """
  Pop the head element of the queue.

  Returns `{:ok, element, new_buffer}` when the queue is non-empty, and
  `:empty` otherwise. This function never blocks and never inspects
  `:done` -- "queue empty" and "stream done" are distinct states the caller
  must handle separately.

  ## Examples

      iex> ElixirExec.Stream.Buffer.pop(ElixirExec.Stream.Buffer.new(:chunks))
      :empty
  """
  @spec pop(t()) :: {:ok, element(), t()} | :empty
  def pop(%__MODULE__{queue: q} = buffer) do
    case :queue.out(q) do
      {{:value, element}, q2} -> {:ok, element, %{buffer | queue: q2}}
      {:empty, _} -> :empty
    end
  end

  @doc """
  Record that a consumer is parked, waiting for the next element.

  At most one consumer can be parked at a time; calling `park/2` a second
  time overwrites the previous `from`. The owning GenServer is responsible
  for replying to the parked consumer when an element becomes available
  (or when the stream ends) and then calling `clear_client/1`.
  """
  @spec park(t(), GenServer.from()) :: t()
  def park(%__MODULE__{} = buffer, from) do
    %{buffer | client: from}
  end

  @doc """
  Reset the parked-consumer slot to `nil`.

  Called by the owning GenServer after it has replied to the previously
  parked consumer.
  """
  @spec clear_client(t()) :: t()
  def clear_client(%__MODULE__{} = buffer) do
    %{buffer | client: nil}
  end

  # ---------------------------------------------------------------------------
  # End-of-stream
  # ---------------------------------------------------------------------------

  @doc """
  Mark the stream as done because the upstream port pid has exited.

  In `:lines` mode any non-empty `partial` is flushed onto the back of the
  queue as the final element (without a trailing newline). In every other
  mode this is a pure flag flip on `:done`.

  Calling `mark_done/1` more than once is safe: subsequent calls leave
  `:done` set and (in `:lines` mode) find an already-empty partial.
  """
  @spec mark_done(t()) :: t()
  def mark_done(%__MODULE__{} = buffer) do
    buffer
    |> flush_partial()
    |> Map.put(:done, true)
  end

  @doc """
  Returns `true` only when `mark_done/1` has been called *and* the queue
  is empty.

  This is the condition the owning GenServer uses to decide whether to
  send `:end_of_stream` to a parked consumer and shut down.
  """
  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{done: true, queue: q}), do: :queue.is_empty(q)
  def exhausted?(%__MODULE__{done: false}), do: false

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  @spec enqueue(t(), element()) :: t()
  defp enqueue(%__MODULE__{queue: q} = buffer, element) do
    %{buffer | queue: :queue.in(element, q)}
  end

  # Combine the chunk with `partial`, split on "\n", queue every complete
  # line (with its trailing "\n"), and keep the tail as the new partial.
  @spec ingest_lines(t(), binary()) :: t()
  defp ingest_lines(%__MODULE__{partial: partial, queue: q} = buffer, data) do
    combined = partial <> data

    case String.split(combined, "\n") do
      [tail] ->
        %{buffer | partial: tail}

      parts ->
        complete = Enum.drop(parts, -1)
        new_partial = List.last(parts)

        new_q =
          Enum.reduce(complete, q, fn line, acc ->
            :queue.in(line <> "\n", acc)
          end)

        %{buffer | queue: new_q, partial: new_partial}
    end
  end

  # Flush any non-empty :lines-mode partial onto the queue as the final
  # element (no trailing newline). No-op for other modes or when partial
  # is already empty.
  @spec flush_partial(t()) :: t()
  defp flush_partial(%__MODULE__{mode: :lines, partial: ""} = buffer), do: buffer

  defp flush_partial(%__MODULE__{mode: :lines, partial: partial, queue: q} = buffer) do
    %{buffer | queue: :queue.in(partial, q), partial: ""}
  end

  defp flush_partial(%__MODULE__{} = buffer), do: buffer
end
