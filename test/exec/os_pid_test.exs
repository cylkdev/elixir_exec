defmodule Exec.OsPidTest do
  use ExUnit.Case, async: true

  describe "os_pid/1" do
    test "returns the pid the operating system knows the program by" do
      {:ok, program} = Exec.open(["sleep", "30"])

      assert {:ok, os_pid} = Exec.os_pid(program)
      assert is_integer(os_pid) and os_pid > 0

      # The number means something outside the VM, which is the whole point of
      # exposing it: the OS agrees this process exists.
      assert {:ok, %{exit_status: 0}} = Exec.run(["ps", "-p", to_string(os_pid)])

      Exec.stop(program)
    end

    test "is still answered after the program exits" do
      {:ok, program} = Exec.open(["sh", "-c", "exit 0"])
      {:ok, os_pid} = Exec.os_pid(program)

      assert {:ok, {:exit, _}} = drain_to_exit(program)
      assert {:error, :not_running} = Exec.os_pid(program)
      assert is_integer(os_pid)
    end
  end

  defp drain_to_exit(program) do
    case Exec.read(program) do
      {:ok, {:exit, _} = event} -> {:ok, event}
      {:ok, _} -> drain_to_exit(program)
    end
  end
end
