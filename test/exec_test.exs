defmodule ExecTest do
  use ExUnit.Case

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

  describe "os_process_alive?/1" do
    test "returns true for a running process" do
      {:ok, program} = Exec.open(["sleep", "30"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)

      assert Exec.os_process_alive?(os_pid)

      Exec.stop(program)
    end

    test "returns false for a process that has ended" do
      {:ok, program} = Exec.open(["true"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      {:ok, {:exit, 0}} = Exec.read(program)

      refute Exec.os_process_alive?(os_pid)
    end
  end

  describe "send_sigterm/1" do
    test "ends a running process with SIGTERM" do
      {:ok, program} = Exec.open(["sleep", "30"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)

      assert Exec.send_sigterm(os_pid)
      assert {:ok, {:exit, {:signal, :sigterm}}} = Exec.read(program)
    end

    test "returns false for a process that has ended" do
      {:ok, program} = Exec.open(["true"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      {:ok, {:exit, 0}} = Exec.read(program)

      refute Exec.send_sigterm(os_pid)
    end
  end

  describe "send_sigkill/1" do
    test "ends a running process with SIGKILL" do
      {:ok, program} = Exec.open(["sleep", "30"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)

      assert Exec.send_sigkill(os_pid)
      assert {:ok, {:exit, {:signal, :sigkill}}} = Exec.read(program)
    end

    test "returns false for a process that has ended" do
      {:ok, program} = Exec.open(["true"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      {:ok, {:exit, 0}} = Exec.read(program)

      refute Exec.send_sigkill(os_pid)
    end
  end
end
