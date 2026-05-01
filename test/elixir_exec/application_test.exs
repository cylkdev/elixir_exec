defmodule ElixirExec.ApplicationTest do
  use ExUnit.Case, async: true

  test "registers ElixirExec.Supervisor and keeps it running" do
    pid = Process.whereis(ElixirExec.Supervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "supervises ElixirExec.StreamSupervisor under ElixirExec.Supervisor" do
    sup_pid = Process.whereis(ElixirExec.Supervisor)
    children = Supervisor.which_children(sup_pid)

    assert Enum.any?(children, fn
      {ElixirExec.StreamSupervisor, child_pid, :supervisor, _} when is_pid(child_pid) -> true
      _ -> false
    end)
  end

  test "registers ElixirExec.StreamSupervisor as a named DynamicSupervisor" do
    pid = Process.whereis(ElixirExec.StreamSupervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end
end
