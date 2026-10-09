defmodule Exec.InfoTest do
  use ExUnit.Case, async: true

  describe "info/1" do
    test "returns the handle, erlexec's controller and the operating-system pid" do
      {:ok, program} = Exec.open(["sleep", "30"])

      assert {:ok, %{handle_pid: ^program, controller_pid: controller_pid, os_pid: os_pid}} =
               Exec.info(program)

      assert ^os_pid = :exec.ospid(controller_pid)
      assert ^controller_pid = :exec.pid(os_pid)

      Exec.stop(program)
    end
  end
end
