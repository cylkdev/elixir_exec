defmodule ElixirExecTest do
  use ExUnit.Case

  alias ElixirExec.Output

  doctest ElixirExec

  describe "run/2, read/2, write/2" do
    test "reads a program's output, then its exit" do
      {:ok, conn} = ElixirExec.run("echo hi")

      assert ElixirExec.read(conn) === {:ok, {:stdout, "hi\n"}}
      assert ElixirExec.read(conn) === {:ok, {:exit, 0}}
    end

    test "reads stderr separately from stdout" do
      {:ok, conn} = ElixirExec.run("echo err 1>&2")

      assert ElixirExec.read(conn) === {:ok, {:stderr, "err\n"}}
      assert ElixirExec.read(conn) === {:ok, {:exit, 0}}
    end

    test "reports a non-zero exit as the shell's code" do
      {:ok, conn} = ElixirExec.run("exit 3")

      assert ElixirExec.read(conn) === {:ok, {:exit, 3}}
    end

    test "reports a signal death as {:signal, name}" do
      {:ok, conn} = ElixirExec.run("kill -TERM $$")

      assert ElixirExec.read(conn) === {:ok, {:exit, {:signal, :sigterm}}}
    end

    test "a read that finds nothing within its timeout returns {:error, :timeout}" do
      {:ok, conn} = ElixirExec.run("sleep 30")

      assert ElixirExec.read(conn, 0) === {:error, :timeout}

      assert ElixirExec.stop(conn) === :ok
    end

    test "write/2 sends data the program reads back, and :eof closes it" do
      {:ok, conn} = ElixirExec.run("cat", stdin: true)

      assert ElixirExec.write(conn, "hello\n") === :ok
      assert ElixirExec.read(conn) === {:ok, {:stdout, "hello\n"}}

      assert ElixirExec.write(conn, :eof) === :ok
      assert ElixirExec.read(conn) === {:ok, {:exit, 0}}
    end

    test "stdin: false leaves the program without stdin, so it sees EOF at once" do
      {:ok, conn} = ElixirExec.run("cat", stdin: false)

      assert ElixirExec.read(conn) === {:ok, {:exit, 0}}
    end

    test "stdout: false delivers no stdout, only the exit" do
      {:ok, conn} = ElixirExec.run("echo hi", stdout: false)

      assert ElixirExec.read(conn) === {:ok, {:exit, 0}}
    end

    test "stderr: false delivers no stderr, only the exit" do
      {:ok, conn} = ElixirExec.run("echo hi 1>&2", stderr: false)

      assert ElixirExec.read(conn) === {:ok, {:exit, 0}}
    end

    test "list form resolves a bare name through PATH" do
      {:ok, conn} = ElixirExec.run(["echo", "hi"])

      assert ElixirExec.read(conn) === {:ok, {:stdout, "hi\n"}}
    end

    test "list form uses a path containing a slash as given" do
      {:ok, conn} = ElixirExec.run(["/bin/echo", "hi"])

      assert ElixirExec.read(conn) === {:ok, {:stdout, "hi\n"}}
    end

    test "list form coerces its arguments to strings" do
      {:ok, conn} = ElixirExec.run(["echo", 42])

      assert ElixirExec.read(conn) === {:ok, {:stdout, "42\n"}}
    end

    test "an empty command is an error" do
      assert ElixirExec.run("") === {:error, ~c"empty command provided"}
    end

    test "an option the runner does not take is ignored" do
      {:ok, conn} = ElixirExec.run("echo hi", definitely_not_an_option: 1)

      assert ElixirExec.read(conn) === {:ok, {:stdout, "hi\n"}}
    end
  end

  describe "stop/1 and kill/2" do
    # A requested stop is reported as a normal exit, unlike kill/2 below, which
    # surfaces the signal.
    test "stop/1 ends the program" do
      {:ok, conn} = ElixirExec.run("sleep 30")

      assert ElixirExec.stop(conn) === :ok
      assert ElixirExec.read(conn) === {:ok, {:exit, 0}}
    end

    test "kill/2 ends the program with the signal given" do
      {:ok, conn} = ElixirExec.run("sleep 30")

      assert ElixirExec.kill(conn, 9) === :ok
      assert ElixirExec.read(conn) === {:ok, {:exit, {:signal, :sigkill}}}
    end

    test "stop/1 ends a program that ignores SIGTERM" do
      {:ok, conn} = ElixirExec.run("/usr/local/fixtures/ignores-sigterm", kill_timeout: 1)

      assert ElixirExec.read(conn) === {:ok, {:stdout, "ready\n"}}
      assert ElixirExec.stop(conn) === :ok
      assert ElixirExec.read(conn) === {:ok, {:exit, 0}}
    end
  end

  describe "capture/2" do
    test "returns stdout, stderr and the exit status" do
      assert ElixirExec.capture("echo out; echo err 1>&2") ===
               {:ok, %Output{stdout: ["out\n"], stderr: ["err\n"], exit_status: 0}}
    end

    test "reports a non-zero exit as success, with the shell's code" do
      assert ElixirExec.capture("echo partial; exit 3") ===
               {:ok, %Output{stdout: ["partial\n"], stderr: [], exit_status: 3}}
    end

    test "a program that outlives its timeout returns {:error, :timeout}" do
      assert ElixirExec.capture("sleep 30", timeout: 200) === {:error, :timeout}
    end

    test "an empty command is an error, not an exit status" do
      assert ElixirExec.capture("") === {:error, ~c"empty command provided"}
    end
  end

  describe "stream/2" do
    # stdout and stderr are not ordered relative to each other, so each is
    # asserted on its own.
    test "yields stdout lines with the delimiter retained, then the exit status" do
      assert ~S(printf 'a\nb\n') |> ElixirExec.stream() |> Enum.to_list() ===
               [{:stdout, "a\n"}, {:stdout, "b\n"}, {:exit_status, 0}]
    end

    test "yields stderr lines the same way" do
      assert ~S(printf 'e\n' 1>&2) |> ElixirExec.stream() |> Enum.to_list() ===
               [{:stderr, "e\n"}, {:exit_status, 0}]
    end

    test "flushes a trailing partial line that has no delimiter" do
      assert ~S(printf 'a\nb') |> ElixirExec.stream() |> Enum.to_list() ===
               [{:stdout, "a\n"}, {:stdout, "b"}, {:exit_status, 0}]
    end

    test "halting early stops the program and emits no exit status" do
      assert "echo ready; sleep 30" |> ElixirExec.stream() |> Enum.take(1) ===
               [{:stdout, "ready\n"}]
    end

    test "a command that cannot be started raises" do
      stream = ElixirExec.stream("")

      assert_raise RuntimeError, fn -> Enum.to_list(stream) end
    end
  end

  describe "lifetime" do
    test "a program does not outlive the process that started it" do
      me = self()

      owner =
        spawn(fn ->
          {:ok, conn} = ElixirExec.run("sleep 30")
          send(me, {:conn, conn})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:conn, conn}, 5_000

      ref = Process.monitor(conn)
      Process.exit(owner, :kill)

      # The program's process stops the OS process, then exits normally.
      assert_receive {:DOWN, ^ref, :process, ^conn, :normal}, 10_000
    end

    test "a program does not outlive its own process, even killed outright" do
      token = unique_token()
      {:ok, conn} = ElixirExec.run("sleep #{token}")

      assert await_os_process(token, :present)

      # Nothing in the program's process gets to run, so whatever reaps the OS
      # process here is outside the BEAM.
      Process.exit(conn, :kill)

      assert await_os_process(token, :absent)
    end

    # Killing the supervisor logs the connection's own death, which is the
    # point of the test rather than a problem with it.
    @tag :capture_log
    test "a program does not outlive the supervision tree that owns it" do
      token = unique_token()
      {:ok, _conn} = ElixirExec.run("sleep #{token}")

      assert await_os_process(token, :present)

      ElixirExec.ConnectionSupervisor |> Process.whereis() |> Process.exit(:kill)

      assert await_os_process(token, :absent)
    end
  end

  describe "process lifetime of shell commands" do
    # A string command is interpreted by a shell, and a shell may run the
    # program as a child rather than becoming it. These tests pin the outcome
    # the caller cares about -- the program is gone -- rather than the
    # mechanism, which differs between shells.
    test "stop/1 ends the program itself, not merely the shell that started it" do
      token = unique_token()
      {:ok, conn} = ElixirExec.run("sleep #{token}")

      assert await_os_process(token, :present)
      assert ElixirExec.stop(conn) === :ok
      assert await_os_process(token, :absent)
    end

    test "kill/2 reaches the program itself" do
      token = unique_token()
      {:ok, conn} = ElixirExec.run("sleep #{token}")

      assert await_os_process(token, :present)
      assert ElixirExec.kill(conn, 9) === :ok
      assert await_os_process(token, :absent)
    end
  end

  # A fractional argument `sleep` accepts, unique per test, so one test's
  # program is never confused with another's or with a stray from an earlier
  # run. 300 seconds is far longer than any poll below, so a program going
  # missing means it was reaped and never that it finished on its own.
  defp unique_token, do: "300.0#{System.unique_integer([:positive])}"

  defp await_os_process(token, expected, attempts \\ 60)

  defp await_os_process(token, expected, 0) do
    flunk("the OS process for `sleep #{token}` was never #{expected}")
  end

  defp await_os_process(token, expected, attempts) do
    {out, _status} = System.cmd("pgrep", ["-f", "sleep #{token}"], stderr_to_stdout: true)
    running? = String.trim(out) !== ""

    if running? === (expected === :present) do
      true
    else
      Process.sleep(100)
      await_os_process(token, expected, attempts - 1)
    end
  end
end
