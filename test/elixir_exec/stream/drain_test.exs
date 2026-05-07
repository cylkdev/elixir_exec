defmodule ElixirExec.Stream.DrainTest do
  use ExUnit.Case, async: true

  alias ElixirExec.Stream.Drain

  # The drain finalizer reads from the *enumerating* process's mailbox.
  # Each test spawns a Task so the test process's own mailbox stays clean
  # between tests.

  describe "attach/3" do
    test "passes elements through unchanged" do
      enum = Drain.attach([:a, :b, :c], 12_345, 20)

      task = Task.async(fn -> Enum.to_list(enum) end)
      assert Task.await(task) === [:a, :b, :c]
    end

    test "drains a matching DOWN from the consumer's mailbox after iteration" do
      os_pid = 99_001
      parent = self()

      task =
        Task.async(fn ->
          # Pre-seed the matching DOWN before iteration finishes.
          send(self(), {:DOWN, os_pid, :process, self(), :normal})

          enum = Drain.attach([:x, :y], os_pid)
          result = Enum.to_list(enum)

          # After enumeration ends, the matching DOWN should have been
          # consumed by the finalizer — so the mailbox is now empty.
          {:messages, msgs} = Process.info(self(), :messages)
          send(parent, {:msgs, msgs})

          result
        end)

      assert Task.await(task) === [:x, :y]
      assert_receive {:msgs, []}, 1_000
    end

    test "ignores non-matching DOWN messages (different os_pid)" do
      os_pid = 99_002
      other_os_pid = 88_888
      parent = self()

      task =
        Task.async(fn ->
          send(self(), {:DOWN, other_os_pid, :process, self(), :normal})

          enum = Drain.attach([:only], os_pid, 50)
          result = Enum.to_list(enum)

          # The non-matching DOWN must be left in the mailbox.
          {:messages, msgs} = Process.info(self(), :messages)
          send(parent, {:msgs, msgs})

          result
        end)

      assert Task.await(task) === [:only]
      assert_receive {:msgs, [{:DOWN, ^other_os_pid, :process, _, :normal}]}, 1_000
    end

    test "times out if no matching DOWN arrives (does not hang)" do
      os_pid = 99_003

      task =
        Task.async(fn ->
          enum = Drain.attach([], os_pid, 20)
          Enum.to_list(enum)
        end)

      # Should return promptly even though no DOWN ever arrives.
      assert Task.await(task, 500) === []
    end
  end
end
