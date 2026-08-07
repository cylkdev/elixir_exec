defmodule ExecTest do
  use ExUnit.Case

  alias Exec.Result

  doctest Exec

  describe "open/2, read/2, write/2" do
    test "reads a program's output, then its exit" do
      {:ok, program} = Exec.open("echo hi")

      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "reads stderr separately from stdout" do
      {:ok, program} = Exec.open("echo err 1>&2")

      assert Exec.read(program) === {:ok, {:stderr, "err\n"}}
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "reports a non-zero exit as the shell's code" do
      {:ok, program} = Exec.open("exit 3")

      assert Exec.read(program) === {:ok, {:exit, 3}}
    end

    test "reports a signal death as {:signal, name}" do
      {:ok, program} = Exec.open("kill -TERM $$")

      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigterm}}}
    end

    test "a read that finds nothing within its timeout returns {:error, :timeout}" do
      {:ok, program} = Exec.open("sleep 30")

      assert Exec.read(program, 0) === {:error, :timeout}

      assert Exec.stop(program) === :ok
    end

    test "write/2 sends data the program reads back, and :eof closes it" do
      {:ok, program} = Exec.open("cat", stdin: true)

      assert Exec.write(program, "hello\n") === :ok
      assert Exec.read(program) === {:ok, {:stdout, "hello\n"}}

      assert Exec.write(program, :eof) === :ok
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "stdin: false leaves the program without stdin, so it sees EOF at once" do
      {:ok, program} = Exec.open("cat", stdin: false)

      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "stdout: false delivers no stdout, only the exit" do
      {:ok, program} = Exec.open("echo hi", stdout: false)

      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "stderr: false delivers no stderr, only the exit" do
      {:ok, program} = Exec.open("echo hi 1>&2", stderr: false)

      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "list form resolves a bare name through PATH" do
      {:ok, program} = Exec.open(["echo", "hi"])

      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
    end

    test "list form uses a path containing a slash as given" do
      {:ok, program} = Exec.open(["/bin/echo", "hi"])

      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
    end

    test "list form coerces its arguments to strings" do
      {:ok, program} = Exec.open(["echo", 42])

      assert Exec.read(program) === {:ok, {:stdout, "42\n"}}
    end

    test "an empty command is an error" do
      assert Exec.open("") === {:error, ~c"empty command provided"}
    end

    test "an unrecognised option raises" do
      assert_raise ArgumentError, ~r/unknown option :definitely_not_an_option/, fn ->
        Exec.open("echo hi", definitely_not_an_option: 1)
      end
    end

    test "an option value the runner rejects raises" do
      assert_raise ArgumentError, ~r/invalid value for :cd/, fn ->
        Exec.open("echo hi", cd: 12_345)
      end
    end

    test ":timeout is accepted without being forwarded to the runner" do
      {:ok, program} = Exec.open("echo hi", timeout: 5_000)

      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
    end
  end

  describe "stop/1 and signal/2" do
    # A requested stop is reported as a normal exit, unlike signal/2 below, which
    # surfaces the signal.
    test "stop/1 ends the program" do
      {:ok, program} = Exec.open("sleep 30")

      assert Exec.stop(program) === :ok
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "kill/2 ends the program with the signal given" do
      {:ok, program} = Exec.open("sleep 30")

      assert Exec.signal(program, 9) === :ok
      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigkill}}}
    end

    test "stop/1 ends a program that ignores SIGTERM" do
      {:ok, program} = Exec.open("/usr/local/fixtures/ignores-sigterm", kill_timeout: 1)

      assert Exec.read(program) === {:ok, {:stdout, "ready\n"}}
      assert Exec.stop(program) === :ok
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end
  end

  describe "run/2" do
    test "returns stdout, stderr and the exit status" do
      assert Exec.run("echo out; echo err 1>&2") ===
               {:ok, %Result{stdout: "out\n", stderr: "err\n", exit_status: 0}}
    end

    test "reports a non-zero exit as success, with the shell's code" do
      assert Exec.run("echo partial; exit 3") ===
               {:ok, %Result{stdout: "partial\n", stderr: "", exit_status: 3}}
    end

    test "joins output written in separate chunks into one binary" do
      assert {:ok, %Result{stdout: "abc"}} = Exec.run("printf a; sleep 0.2; printf bc")
    end

    test "a program that outlives its timeout returns {:error, :timeout}" do
      assert Exec.run("sleep 30", timeout: 200) === {:error, :timeout}
    end

    test "an empty command is an error, not an exit status" do
      assert Exec.run("") === {:error, ~c"empty command provided"}
    end

    test "an unrecognised option raises" do
      assert_raise ArgumentError, ~r/unknown option :nope/, fn -> Exec.run("echo hi", nope: 1) end
    end
  end

  describe "stream!/2" do
    # stdout and stderr are not ordered relative to each other, so each is
    # asserted on its own.
    test "yields stdout lines with the delimiter retained, then the exit status" do
      assert ~S(printf 'a\nb\n') |> Exec.stream!() |> Enum.to_list() ===
               [{:stdout, "a\n"}, {:stdout, "b\n"}, {:exit, 0}]
    end

    test "yields stderr lines the same way" do
      assert ~S(printf 'e\n' 1>&2) |> Exec.stream!() |> Enum.to_list() ===
               [{:stderr, "e\n"}, {:exit, 0}]
    end

    test "flushes a trailing partial line that has no delimiter" do
      assert ~S(printf 'a\nb') |> Exec.stream!() |> Enum.to_list() ===
               [{:stdout, "a\n"}, {:stdout, "b"}, {:exit, 0}]
    end

    test "halting early stops the program and emits no exit status" do
      assert "echo ready; sleep 30" |> Exec.stream!() |> Enum.take(1) ===
               [{:stdout, "ready\n"}]
    end

    test "a command that cannot be started raises" do
      stream = Exec.stream!("")

      assert_raise RuntimeError, fn -> Enum.to_list(stream) end
    end
  end

  describe "lifetime" do
    test "a program does not outlive the process that started it" do
      me = self()

      owner =
        spawn(fn ->
          {:ok, conn} = Exec.open("sleep 30")
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
      {:ok, conn} = Exec.open("sleep #{token}")

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
      {:ok, _conn} = Exec.open("sleep #{token}")

      assert await_os_process(token, :present)

      Exec.ProgramSupervisor |> Process.whereis() |> Process.exit(:kill)

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
      {:ok, program} = Exec.open("sleep #{token}")

      assert await_os_process(token, :present)
      assert Exec.stop(program) === :ok
      assert await_os_process(token, :absent)
    end

    test "signal/2 reaches the program itself" do
      token = unique_token()
      {:ok, program} = Exec.open("sleep #{token}")

      assert await_os_process(token, :present)
      assert Exec.signal(program, 9) === :ok
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
