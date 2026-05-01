defmodule ElixirExec.StreamSupervisorTest do
  use ExUnit.Case

  alias ElixirExec.Stream, as: ExStream
  alias ElixirExec.StreamSupervisor

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # The application supervisor may already have started ElixirExec.StreamSupervisor.
    # If running in isolation (no app), start it here.
    case Process.whereis(StreamSupervisor) do
      nil -> start_supervised!({StreamSupervisor, []})
      _pid -> :ok
    end

    :ok
  end

  # Wire a stand-in port pid into a stream server so DOWN reaches the buffer.
  defp attach_dummy_port(server) do
    port_pid =
      spawn(fn ->
        receive do
          :exit -> :ok
        end
      end)

    :ok = ExStream.attach(server, port_pid)
    port_pid
  end

  # Stop a stream server and wait for it to actually exit before continuing.
  defp stop_and_await(server) do
    ref = Process.monitor(server)
    :ok = ExStream.stop(server)

    receive do
      {:DOWN, ^ref, :process, ^server, _reason} -> :ok
    after
      1_000 -> raise "stream server did not stop in time"
    end
  end

  # ---------------------------------------------------------------------------
  # start_stream/1 contract
  # ---------------------------------------------------------------------------

  describe "start_stream/1" do
    test "returns {:ok, pid, enum} with a live pid and an Enumerable" do
      assert {:ok, pid, enum} = StreamSupervisor.start_stream(:chunks)
      assert is_pid(pid)
      assert Process.alive?(pid)
      # Stream.unfold/2 returns a %Stream{}; any Enumerable is acceptable.
      assert is_function(enum, 2) or is_struct(enum) or is_list(enum)
      # Round-trip: the enum should be consumable.
      port_pid = attach_dummy_port(pid)
      send(pid, {:stdout, 1, "x"})
      send(port_pid, :exit)
      assert Enum.to_list(enum) === ["x"]
    end

    test "started pid is a child of ElixirExec.StreamSupervisor" do
      assert {:ok, pid, _enum} = StreamSupervisor.start_stream(:chunks)

      children = DynamicSupervisor.which_children(StreamSupervisor)
      assert Enum.any?(children, fn
               {:undefined, ^pid, :worker, _modules} -> true
               _ -> false
             end)

      stop_and_await(pid)
    end

    for mode <- [:lines, :chunks, :stderr, :merged] do
      test "accepts mode #{inspect(mode)}" do
        assert {:ok, pid, enum} = StreamSupervisor.start_stream(unquote(mode))
        assert is_pid(pid)
        assert Process.alive?(pid)
        # Sanity: enum is consumable. Wire a dummy port and immediately end.
        port_pid = attach_dummy_port(pid)
        send(port_pid, :exit)
        assert is_list(Enum.to_list(enum))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Crash isolation
  # ---------------------------------------------------------------------------

  describe "crash isolation" do
    test "a child crash does not take down the supervisor" do
      sup_pid = Process.whereis(StreamSupervisor)
      assert is_pid(sup_pid)
      sup_ref = Process.monitor(sup_pid)

      assert {:ok, pid, _enum} = StreamSupervisor.start_stream(:chunks)
      child_ref = Process.monitor(pid)

      Process.exit(pid, :kill)

      # Wait for the child to actually go down.
      receive do
        {:DOWN, ^child_ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> raise "stream child did not exit after kill"
      end

      # The supervisor must still be alive and responsive.
      refute_received {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}
      assert Process.alive?(sup_pid)
      assert is_list(DynamicSupervisor.which_children(StreamSupervisor))

      Process.demonitor(sup_ref, [:flush])
    end
  end

  # ---------------------------------------------------------------------------
  # Clean termination
  # ---------------------------------------------------------------------------

  describe "clean termination" do
    test "after a child stops cleanly it is removed from the supervisor" do
      assert {:ok, pid, _enum} = StreamSupervisor.start_stream(:chunks)

      assert pid in child_pids()

      stop_and_await(pid)

      refute pid in child_pids()
    end
  end

  defp child_pids do
    StreamSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, child_pid, _, _} -> child_pid end)
  end
end
