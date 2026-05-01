defmodule ElixirExec.Stream.BufferTest do
  use ExUnit.Case, async: true

  alias ElixirExec.Stream.Buffer

  doctest ElixirExec.Stream.Buffer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp queue_to_list(%Buffer{queue: q}), do: :queue.to_list(q)

  # ---------------------------------------------------------------------------
  # new/1
  # ---------------------------------------------------------------------------

  describe "new/1" do
    for mode <- [:lines, :chunks, :stderr, :merged] do
      test "returns a struct in #{inspect(mode)} mode with an empty queue" do
        buffer = Buffer.new(unquote(mode))

        assert %Buffer{mode: unquote(mode)} = buffer
        assert queue_to_list(buffer) === []
        assert buffer.partial === ""
        assert buffer.done === false
        assert buffer.client === nil
        assert buffer.port_pid === nil
        assert buffer.monitor_ref === nil
      end
    end

    test "raises on an unsupported mode" do
      assert_raise FunctionClauseError, fn -> Buffer.new(:bogus) end
    end
  end

  # ---------------------------------------------------------------------------
  # attach/3
  # ---------------------------------------------------------------------------

  describe "attach/3" do
    test "stores port_pid and monitor_ref on the struct" do
      port_pid = self()
      ref = make_ref()

      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.attach(port_pid, ref)

      assert buffer.port_pid === port_pid
      assert buffer.monitor_ref === ref
    end

    test "does not enqueue or otherwise mutate the queue" do
      port_pid = self()
      ref = make_ref()

      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.attach(port_pid, ref)

      assert queue_to_list(buffer) === []
    end
  end

  # ---------------------------------------------------------------------------
  # :chunks mode
  # ---------------------------------------------------------------------------

  describe ":chunks mode ingest_stdout/2" do
    test "enqueues stdout chunks as raw binaries in order" do
      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.ingest_stdout("alpha")
        |> Buffer.ingest_stdout("beta")
        |> Buffer.ingest_stdout("gamma")

      assert queue_to_list(buffer) === ["alpha", "beta", "gamma"]
    end
  end

  describe ":chunks mode ingest_stderr/2" do
    test "ignores stderr data" do
      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.ingest_stderr("error")

      assert queue_to_list(buffer) === []
    end
  end

  # ---------------------------------------------------------------------------
  # :stderr mode
  # ---------------------------------------------------------------------------

  describe ":stderr mode ingest_stderr/2" do
    test "enqueues stderr chunks as raw binaries in order" do
      buffer =
        :stderr
        |> Buffer.new()
        |> Buffer.ingest_stderr("e1")
        |> Buffer.ingest_stderr("e2")

      assert queue_to_list(buffer) === ["e1", "e2"]
    end
  end

  describe ":stderr mode ingest_stdout/2" do
    test "ignores stdout data" do
      buffer =
        :stderr
        |> Buffer.new()
        |> Buffer.ingest_stdout("alpha")

      assert queue_to_list(buffer) === []
    end
  end

  # ---------------------------------------------------------------------------
  # :merged mode
  # ---------------------------------------------------------------------------

  describe ":merged mode" do
    test "ingest_stdout/2 enqueues {:stdout, data}" do
      buffer =
        :merged
        |> Buffer.new()
        |> Buffer.ingest_stdout("a")

      assert queue_to_list(buffer) === [{:stdout, "a"}]
    end

    test "ingest_stderr/2 enqueues {:stderr, data}" do
      buffer =
        :merged
        |> Buffer.new()
        |> Buffer.ingest_stderr("e")

      assert queue_to_list(buffer) === [{:stderr, "e"}]
    end

    test "ingestion order is preserved across both channels" do
      buffer =
        :merged
        |> Buffer.new()
        |> Buffer.ingest_stdout("a")
        |> Buffer.ingest_stderr("e")
        |> Buffer.ingest_stdout("b")

      assert queue_to_list(buffer) === [{:stdout, "a"}, {:stderr, "e"}, {:stdout, "b"}]
    end
  end

  # ---------------------------------------------------------------------------
  # :lines mode
  # ---------------------------------------------------------------------------

  describe ":lines mode ingest_stdout/2" do
    test "ignores stderr data" do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stderr("err\n")

      assert queue_to_list(buffer) === []
      assert Buffer.new(:lines).partial === ""
    end

    test "a chunk without a newline goes entirely into partial" do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("hello")

      assert queue_to_list(buffer) === []
      assert buffer.partial === "hello"
    end

    test ~s("hello\\nworld" emits "hello\\n" and leaves "world" in partial) do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("hello\nworld")

      assert queue_to_list(buffer) === ["hello\n"]
      assert buffer.partial === "world"
    end

    test ~s("\\n!" after a partial of "world" emits "world\\n" and leaves "!" in partial) do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("hello\nworld")
        |> Buffer.ingest_stdout("\n!")

      assert queue_to_list(buffer) === ["hello\n", "world\n"]
      assert buffer.partial === "!"
    end

    test ~s("a\\nb\\nc\\n" emits all three lines and leaves partial empty) do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("a\nb\nc\n")

      assert queue_to_list(buffer) === ["a\n", "b\n", "c\n"]
      assert buffer.partial === ""
    end
  end

  # ---------------------------------------------------------------------------
  # pop/1
  # ---------------------------------------------------------------------------

  describe "pop/1" do
    test "returns :empty on an empty queue" do
      buffer = Buffer.new(:chunks)
      assert Buffer.pop(buffer) === :empty
    end

    test "returns {:ok, head, rest} when the queue has one element" do
      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.ingest_stdout("only")

      assert {:ok, "only", rest} = Buffer.pop(buffer)
      assert queue_to_list(rest) === []
    end

    test "returns the head and a new buffer with the tail of the queue" do
      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.ingest_stdout("a")
        |> Buffer.ingest_stdout("b")
        |> Buffer.ingest_stdout("c")

      assert {:ok, "a", b1} = Buffer.pop(buffer)
      assert {:ok, "b", b2} = Buffer.pop(b1)
      assert {:ok, "c", b3} = Buffer.pop(b2)
      assert Buffer.pop(b3) === :empty
    end

    test ":merged mode pops tagged tuples in FIFO order" do
      buffer =
        :merged
        |> Buffer.new()
        |> Buffer.ingest_stdout("a")
        |> Buffer.ingest_stderr("e")

      assert {:ok, {:stdout, "a"}, b1} = Buffer.pop(buffer)
      assert {:ok, {:stderr, "e"}, b2} = Buffer.pop(b1)
      assert Buffer.pop(b2) === :empty
    end
  end

  # ---------------------------------------------------------------------------
  # park/2 and clear_client/1
  # ---------------------------------------------------------------------------

  describe "park/2" do
    test "stores the from on the buffer" do
      from = {self(), make_ref()}

      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.park(from)

      assert buffer.client === from
    end
  end

  describe "clear_client/1" do
    test "resets client to nil" do
      from = {self(), make_ref()}

      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.park(from)
        |> Buffer.clear_client()

      assert buffer.client === nil
    end
  end

  # ---------------------------------------------------------------------------
  # mark_done/1
  # ---------------------------------------------------------------------------

  describe "mark_done/1" do
    for mode <- [:lines, :chunks, :stderr, :merged] do
      test "in #{inspect(mode)} mode sets done: true" do
        buffer =
          unquote(mode)
          |> Buffer.new()
          |> Buffer.mark_done()

        assert buffer.done === true
      end
    end

    test ":lines mode flushes a non-empty partial as the final element" do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("abc")
        |> Buffer.mark_done()

      assert queue_to_list(buffer) === ["abc"]
      assert buffer.partial === ""
      assert buffer.done === true
    end

    test ":lines mode with a non-empty queue and a non-empty partial appends the partial last" do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("a\nb")
        |> Buffer.mark_done()

      assert queue_to_list(buffer) === ["a\n", "b"]
      assert buffer.partial === ""
    end

    test ":lines mode with an empty partial leaves the queue unchanged" do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("a\n")
        |> Buffer.mark_done()

      assert queue_to_list(buffer) === ["a\n"]
      assert buffer.partial === ""
    end

    test ":chunks mode does not invent a partial element" do
      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.ingest_stdout("a")
        |> Buffer.mark_done()

      assert queue_to_list(buffer) === ["a"]
    end
  end

  # ---------------------------------------------------------------------------
  # exhausted?/1
  # ---------------------------------------------------------------------------

  describe "exhausted?/1" do
    test "false when not done and queue is empty" do
      refute :chunks |> Buffer.new() |> Buffer.exhausted?()
    end

    test "false when not done and queue is non-empty" do
      buffer = :chunks |> Buffer.new() |> Buffer.ingest_stdout("a")
      refute Buffer.exhausted?(buffer)
    end

    test "false when done but queue is non-empty" do
      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.ingest_stdout("a")
        |> Buffer.mark_done()

      refute Buffer.exhausted?(buffer)
    end

    test "true when done and queue is empty" do
      buffer =
        :chunks
        |> Buffer.new()
        |> Buffer.mark_done()

      assert Buffer.exhausted?(buffer)
    end

    test ":lines mode is not exhausted while a partial is pending pre-mark_done" do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("abc")

      refute Buffer.exhausted?(buffer)
    end

    test ":lines mode is exhausted after mark_done flushes the partial and pop drains the queue" do
      buffer =
        :lines
        |> Buffer.new()
        |> Buffer.ingest_stdout("abc")
        |> Buffer.mark_done()

      {:ok, "abc", drained} = Buffer.pop(buffer)
      assert Buffer.exhausted?(drained)
    end
  end
end
