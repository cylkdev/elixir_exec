defmodule ElixirExec.OSProcessTest do
  use ExUnit.Case, async: true

  alias ElixirExec.OSProcess, as: ExProcess

  # ----------------------------------------------------------------------
  # Struct construction
  # ----------------------------------------------------------------------

  describe "%ElixirExec.OSProcess{}" do
    test "builds with the required keys and a nil :stream by default" do
      controller = self()
      proc = %ExProcess{controller: controller, os_pid: 12_345}

      assert proc.controller === controller
      assert proc.os_pid === 12_345
      assert proc.stream === nil
    end

    test "accepts an explicit :stream value" do
      stream = Stream.iterate(0, &(&1 + 1))
      proc = %ExProcess{controller: self(), os_pid: 42, stream: stream}

      assert proc.stream === stream
    end

    test "raises ArgumentError when :controller is missing" do
      assert_raise ArgumentError, fn ->
        Code.eval_string(
          "%ElixirExec.OSProcess{os_pid: 1}",
          [],
          __ENV__
        )
      end
    end

    test "raises ArgumentError when :os_pid is missing" do
      assert_raise ArgumentError, fn ->
        Code.eval_string(
          "%ElixirExec.OSProcess{controller: self()}",
          [self: self()],
          __ENV__
        )
      end
    end
  end

  # ----------------------------------------------------------------------
  # decode_reason/1
  # ----------------------------------------------------------------------

  describe "decode_reason/1" do
    test "maps :normal to 0" do
      assert ExProcess.decode_reason(:normal) === 0
    end

    test "extracts the integer status from {:exit_status, n} for non-zero codes" do
      assert ExProcess.decode_reason({:exit_status, 9}) === 9
    end

    test "extracts the integer status from {:exit_status, 0}" do
      assert ExProcess.decode_reason({:exit_status, 0}) === 0
    end

    test "passes unrecognized atoms through unchanged" do
      assert ExProcess.decode_reason(:killed) === :killed
    end

    test "passes unrecognized tuples through unchanged" do
      assert ExProcess.decode_reason({:something_else, :foo}) === {:something_else, :foo}
    end
  end
end
