defmodule ElixirExec.StreamTest do
  use ExUnit.Case, async: true

  alias ElixirExec.Stream, as: ExStream

  # The stream server is started with `start_link/1`, so the test pid is
  # linked to it. When the server shuts down with `:shutdown` (the normal
  # end-of-stream path) the link would otherwise propagate to the test pid
  # and abort the test. Trapping exits turns the linked exit into a
  # benign `{:EXIT, _, _}` message that we discard.
  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @os_pid 1234

  # Inbound erlexec-shaped messages: in production these come from erlexec
  # via raw `send/2` to the owner pid, so injecting them via `send/2` here
  # mirrors reality. This is NOT what the no-`send` rule prohibits — that
  # rule applies to *our* code talking to its own GenServer.
  defp send_stdout(server, data), do: send(server, {:stdout, @os_pid, data})
  defp send_stderr(server, data), do: send(server, {:stderr, @os_pid, data})

  # Synchronously stop the server and wait for it to actually exit.
  defp stop_and_await(server) do
    ref = Process.monitor(server)
    :ok = ExStream.stop(server)

    receive do
      {:DOWN, ^ref, :process, ^server, _reason} -> :ok
    after
      1_000 -> raise "stream server did not stop in time"
    end
  end

  # Monitor a pid, asserting it exits within `timeout` ms.
  defp assert_down(pid, timeout \\ 1_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> raise "pid #{inspect(pid)} did not exit within #{timeout}ms"
    end
  end

  # Spawn a port-pid stand-in and attach it to `server` via the synchronous
  # `attach/2` call. Because `attach/2` is synchronous, the monitor is
  # guaranteed to be installed before this helper returns — no further
  # synchronization needed.
  defp spawn_dummy_port(server) do
    port_pid =
      spawn(fn ->
        receive do
          :exit -> :ok
        end
      end)

    :ok = ExStream.attach(server, port_pid)
    port_pid
  end

  # ---------------------------------------------------------------------------
  # :chunks mode
  # ---------------------------------------------------------------------------

  describe ":chunks mode" do
    test "emits stdout chunks exactly as received" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      port_pid = spawn_dummy_port(server)

      send_stdout(server, "alpha")
      send_stdout(server, "beta")
      send_stdout(server, "gamma")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === ["alpha", "beta", "gamma"]
      assert_down(server)
    end

    test "ignores stderr in :chunks mode" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      port_pid = spawn_dummy_port(server)

      send_stderr(server, "noise")
      send_stdout(server, "ok")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === ["ok"]
    end
  end

  # ---------------------------------------------------------------------------
  # :lines mode
  # ---------------------------------------------------------------------------

  describe ":lines mode" do
    test "reassembles chunks split across newline boundaries" do
      {:ok, server, stream} = ExStream.start_link(:lines)
      port_pid = spawn_dummy_port(server)

      send_stdout(server, "hello\nworld")
      send_stdout(server, "\n!")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === ["hello\n", "world\n", "!"]
    end

    test "emits trailing partial line only on end-of-stream" do
      {:ok, server, stream} = ExStream.start_link(:lines)
      port_pid = spawn_dummy_port(server)

      send_stdout(server, "abc")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === ["abc"]
    end

    test "single chunk with multiple newlines yields one element per line" do
      {:ok, server, stream} = ExStream.start_link(:lines)
      port_pid = spawn_dummy_port(server)

      send_stdout(server, "a\nb\nc\n")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === ["a\n", "b\n", "c\n"]
    end

    test "empty output yields empty list" do
      {:ok, server, stream} = ExStream.start_link(:lines)
      port_pid = spawn_dummy_port(server)
      send(port_pid, :exit)

      assert Enum.to_list(stream) === []
    end
  end

  # ---------------------------------------------------------------------------
  # :stderr mode
  # ---------------------------------------------------------------------------

  describe ":stderr mode" do
    test "emits only stderr chunks" do
      {:ok, server, stream} = ExStream.start_link(:stderr)
      port_pid = spawn_dummy_port(server)

      send_stdout(server, "stdout-noise")
      send_stderr(server, "err-1")
      send_stdout(server, "more-noise")
      send_stderr(server, "err-2")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === ["err-1", "err-2"]
    end
  end

  # ---------------------------------------------------------------------------
  # :merged mode
  # ---------------------------------------------------------------------------

  describe ":merged mode" do
    test "yields tagged tuples in arrival order" do
      {:ok, server, stream} = ExStream.start_link(:merged)
      port_pid = spawn_dummy_port(server)

      send_stdout(server, "out-1")
      send_stderr(server, "err-1")
      send_stdout(server, "out-2")
      send_stderr(server, "err-2")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === [
               {:stdout, "out-1"},
               {:stderr, "err-1"},
               {:stdout, "out-2"},
               {:stderr, "err-2"}
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # End-of-stream via attached port pid death
  # ---------------------------------------------------------------------------

  describe "attach/2 end-of-stream" do
    test "down from attached port pid signals end after buffer drains" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      port_pid = spawn_dummy_port(server)

      send_stdout(server, "x")
      send_stdout(server, "y")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === ["x", "y"]
    end

    test "parked consumer is released when port pid exits with empty buffer" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      port_pid = spawn_dummy_port(server)

      task =
        Task.async(fn ->
          Enum.to_list(stream)
        end)

      # Give the task time to park on the GenServer call.
      Process.sleep(50)
      send(port_pid, :exit)

      assert Task.await(task, 1_000) === []
    end

    test "parked consumer receives data that arrives later" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      port_pid = spawn_dummy_port(server)

      task =
        Task.async(fn ->
          Enum.take(stream, 2)
        end)

      # Let the task park inside the GenServer call.
      Process.sleep(50)
      send_stdout(server, "first")
      send_stdout(server, "second")

      assert Task.await(task, 1_000) === ["first", "second"]
      send(port_pid, :exit)
    end

    test "down from an unrelated pid does not end the stream" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      port_pid = spawn_dummy_port(server)

      # Synthesize a DOWN for a pid that is NOT the attached port_pid.
      other = spawn(fn -> :ok end)
      send(server, {:DOWN, make_ref(), :process, other, :normal})

      send_stdout(server, "still-alive")
      send(port_pid, :exit)

      assert Enum.to_list(stream) === ["still-alive"]
    end
  end

  # ---------------------------------------------------------------------------
  # attach/2 is synchronous and race-free (NEW for the call/cast rewrite)
  # ---------------------------------------------------------------------------

  describe "attach/2 race-freedom" do
    test "monitor is installed before attach/2 returns; immediate kill ends stream" do
      {:ok, server, stream} = ExStream.start_link(:chunks)

      port_pid =
        spawn(fn ->
          receive do
            :exit -> :ok
          end
        end)

      # Synchronous: when this returns, Process.monitor/1 is in place.
      :ok = ExStream.attach(server, port_pid)

      # Kill the port pid IMMEDIATELY after attach returns. With the old
      # `send/2`-based monitor wiring there was a window where this could
      # be missed; with the synchronous call, the monitor must already
      # exist, so this DOWN is delivered and the stream ends cleanly.
      send(port_pid, :exit)

      assert Enum.to_list(stream) === []
    end
  end

  # ---------------------------------------------------------------------------
  # Lifecycle: partial consumption + stop
  # ---------------------------------------------------------------------------

  describe "lifecycle" do
    test "enum take leaves the server alive when more data is buffered" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      _port_pid = spawn_dummy_port(server)

      send_stdout(server, "a")
      send_stdout(server, "b")
      send_stdout(server, "c")

      assert Enum.take(stream, 1) === ["a"]
      assert Process.alive?(server)

      stop_and_await(server)
      refute Process.alive?(server)
    end

    test "stop/1 closes the stream cleanly" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      _port_pid = spawn_dummy_port(server)

      send_stdout(server, "only")

      task =
        Task.async(fn ->
          Enum.to_list(stream)
        end)

      Process.sleep(50)
      stop_and_await(server)

      # Once the server is gone, the unfold call returns nil and the
      # consumer finishes (with whatever it had already drained).
      result = Task.await(task, 1_000)
      assert is_list(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Consumer-side :noproc handling
  # ---------------------------------------------------------------------------

  describe "consumer-side :noproc" do
    test "calling the stream after the server has stopped yields []" do
      {:ok, server, stream} = ExStream.start_link(:chunks)
      _port_pid = spawn_dummy_port(server)

      stop_and_await(server)

      # The unfold function should catch the :noproc exit and return nil,
      # so the enumerable cleanly produces [] rather than crashing.
      assert Enum.to_list(stream) === []
    end
  end
end
