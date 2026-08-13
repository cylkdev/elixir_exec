defmodule Exec.RunTest do
  use ExUnit.Case, async: true

  # `finalize_stream/1` did not match the states the success path actually
  # produces — `{:exit, nil}` after the exit event is read, `nil` after the
  # stream halts — so every command that ran to completion raised a
  # CaseClauseError during cleanup. Each test here is that path.

  describe "run/2" do
    test "captures stdout and a zero exit status" do
      assert {:ok, result} = Exec.run(["echo", "hello"])
      assert result.stdout === "hello\n"
      assert result.stderr === ""
      assert result.exit_status === 0
    end

    test "reports a non-zero exit status without failing the call" do
      assert {:ok, result} = Exec.run(["false"])
      assert result.exit_status === 1
    end

    test "keeps stdout and stderr apart and carries the exit status" do
      assert {:ok, result} = Exec.run(["sh", "-c", "echo out; echo err >&2; exit 3"])
      assert result.stdout === "out\n"
      assert result.stderr === "err\n"
      assert result.exit_status === 3
    end

    test "runs in :cd when given one" do
      assert {:ok, result} = Exec.run(["pwd"], cd: "/tmp")
      assert String.trim(result.stdout) =~ "tmp"
    end

    test "passes :env through to the command" do
      assert {:ok, result} =
               Exec.run(["sh", "-c", "echo $ELIXIR_EXEC_TEST"],
                 env: [{"ELIXIR_EXEC_TEST", "set"}]
               )

      assert result.stdout === "set\n"
    end

    test "stops a command that outlives its :timeout" do
      assert {:error, :timeout} = Exec.run(["sleep", "5"], timeout: 100)
    end

    test "an empty command is refused" do
      assert {:error, :empty_command} = Exec.run([])
    end
  end
end
