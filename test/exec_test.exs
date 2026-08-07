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
      assert Exec.open("") === {:error, :empty_command}
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

    test "signal/2 ends the program with the signal given" do
      {:ok, program} = Exec.open("sleep 30")

      assert Exec.signal(program, 9) === :ok
      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigkill}}}
    end

    # The program runs in a process group of its own and both calls act on that
    # group, so the shell a binary command goes through makes no difference to
    # what the caller sees. Each waits for the program to be running first: a
    # signal sent into the window between starting a command and the program
    # replacing it is a signal to something that is not the program yet.
    test "stop/1 reports {:exit, 0} for a binary command" do
      token = unique_token()
      {:ok, program} = Exec.open("sleep #{token}")
      assert await_os_process(token, :present)

      assert Exec.stop(program) === :ok
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "stop/1 reports {:exit, 0} for a list command" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])
      assert await_os_process(token, :present)

      assert Exec.stop(program) === :ok
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "signal/2 reports {:exit, {:signal, :sigterm}} for a binary command" do
      token = unique_token()
      {:ok, program} = Exec.open("sleep #{token}")
      assert await_os_process(token, :present)

      assert Exec.signal(program, :sigterm) === :ok
      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigterm}}}
    end

    test "signal/2 reports {:exit, {:signal, :sigterm}} for a list command" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])
      assert await_os_process(token, :present)

      assert Exec.signal(program, :sigterm) === :ok
      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigterm}}}
    end

    test "stop/1 ends a program that ignores SIGTERM" do
      {:ok, program} = Exec.open("/usr/local/fixtures/ignores-sigterm", kill_timeout: 1)

      assert Exec.read(program) === {:ok, {:stdout, "ready\n"}}
      assert Exec.stop(program) === :ok
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end
  end

  describe "signal/2 argument handling" do
    # The name has to survive the round trip, not merely end the program: on a
    # Mac the number 30 is SIGUSR1 and on Linux it is SIGPWR, so a table read in
    # one direction and not the other reports a signal nobody sent. Both of
    # these are names erlexec's own table has no entry for, and both are
    # numbered differently on Linux and Darwin.
    test "a signal whose number differs between platforms round-trips by name" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])
      assert await_os_process(token, :present)

      assert Exec.signal(program, :sigusr1) === :ok
      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigusr1}}}
    end

    test "sigusr2 round-trips by name" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])
      assert await_os_process(token, :present)

      assert Exec.signal(program, :sigusr2) === :ok
      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigusr2}}}
    end

    # Numbered 27 on both systems, and not in erlexec's table either.
    test "a signal numbered the same on both platforms round-trips by name" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])
      assert await_os_process(token, :present)

      assert Exec.signal(program, :sigprof) === :ok
      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigprof}}}
    end

    # Accepted by erlexec before this module took over resolving names, so
    # dropping them would have been a silent breaking change.
    test "accepts the resource-limit names" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])
      assert await_os_process(token, :present)

      assert Exec.signal(program, :sigxcpu) === :ok
      assert Exec.read(program) === {:ok, {:exit, {:signal, :sigxcpu}}}
    end

    # SIGTTIN and SIGTTOU stop a program rather than end it, so what is checked
    # here is that the name resolves and the send is accepted. The stop that
    # follows escalates to SIGKILL, which reaches a stopped program.
    test "accepts the job-control names" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token], kill_timeout: 1)
      assert await_os_process(token, :present)

      assert Exec.signal(program, :sigttin) === :ok
      assert Exec.signal(program, :sigttou) === :ok
      assert Exec.stop(program) === :ok
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "an unknown signal name raises and leaves the program running" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])

      assert await_os_process(token, :present)

      assert_raise ArgumentError, ~r/unknown signal :not_a_signal/, fn ->
        Exec.signal(program, :not_a_signal)
      end

      assert await_os_process(token, :present)
      assert Exec.stop(program) === :ok
    end

    test "a signal that is neither a name nor an integer raises" do
      {:ok, program} = Exec.open(["sleep", unique_token()])

      assert_raise ArgumentError, ~r/signal must be/, fn ->
        Exec.signal(program, "sigterm")
      end

      assert Exec.stop(program) === :ok
    end

    test "an integer outside the signal range raises" do
      {:ok, program} = Exec.open(["sleep", unique_token()])

      assert_raise ArgumentError, ~r/signal must be/, fn -> Exec.signal(program, 9999) end
      assert_raise ArgumentError, ~r/signal must be/, fn -> Exec.signal(program, -1) end

      assert Exec.stop(program) === :ok
    end

    test "signal 0 is accepted, since it asks whether the program exists" do
      {:ok, program} = Exec.open(["sleep", unique_token()])

      assert Exec.signal(program, 0) === :ok
      assert Exec.stop(program) === :ok
    end
  end

  describe "a program that has ended" do
    test "write/2, stop/1 and signal/2 report it, with the exit still unread" do
      {:ok, program} = Exec.open("echo hi")

      # Wait for the exit to reach the handle without reading it, so the handle
      # is still alive and holding the queued events.
      Process.sleep(500)

      assert Exec.write(program, "x") === {:error, :not_running}
      assert Exec.stop(program) === {:error, :not_running}
      assert Exec.signal(program, :sigterm) === {:error, :not_running}
    end

    test "the queued output is still readable afterwards" do
      {:ok, program} = Exec.open("echo hi")
      Process.sleep(500)

      assert Exec.write(program, "x") === {:error, :not_running}

      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "write/2, stop/1 and signal/2 report it on a spent handle" do
      {:ok, program} = Exec.open("echo hi")
      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
      assert Exec.read(program) === {:ok, {:exit, 0}}

      assert Exec.write(program, "x") === {:error, :not_running}
      assert Exec.stop(program) === {:error, :not_running}
      assert Exec.signal(program, :sigterm) === {:error, :not_running}
    end
  end

  describe "signals sent immediately after open/2" do
    # erlexec's port program installs handlers for SIGHUP, SIGINT, SIGPIPE and
    # SIGTERM, and a forked child inherits them until execve replaces the image.
    # A signal in those four sent in that window is swallowed. Measured at
    # roughly nine losses in a hundred before the resend below.
    #
    # 100 iterations asserting zero losses, rather than sampling a rate: at a
    # loss probability of 0.09 a regression appears with probability above
    # 1 - 0.91^100, which is greater than 0.9999, while a working resend gives
    # zero on any machine.
    test "are not lost" do
      losses =
        Enum.count(1..100, fn _ ->
          {:ok, program} = Exec.open(["sleep", unique_token()])
          :ok = Exec.signal(program, :sigterm)

          case Exec.read(program, 3000) do
            {:ok, {:exit, _}} -> false
            {:error, :timeout} -> true
          end
        end)

      assert losses === 0
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
      assert Exec.run("") === {:error, :empty_command}
    end

    test "a missing executable exits non-zero with a diagnostic, rather than erroring" do
      assert {:ok, result} = Exec.run(["/nonexistent/nope"])

      assert result.exit_status === 1
      assert result.stderr =~ "No such file or directory"
    end

    test "an unrecognised option raises" do
      assert_raise ArgumentError, ~r/unknown option :nope/, fn -> Exec.run("echo hi", nope: 1) end
    end

    test "a :timeout that is not a number of milliseconds raises" do
      assert_raise ArgumentError, ~r/invalid value for :timeout/, fn ->
        Exec.run("echo hi", timeout: "5")
      end
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

      assert_raise Exec.Error, "could not start the command: :empty_command", fn ->
        Enum.to_list(stream)
      end
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

    test "owner: keeps the program alive after the process that started it ends" do
      me = self()
      token = unique_token()

      owner =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      starter =
        spawn(fn ->
          {:ok, program} = Exec.open("sleep #{token}", owner: owner)
          send(me, {:program, program})
        end)

      assert_receive {:program, program}, 5_000

      starter_ref = Process.monitor(starter)
      assert_receive {:DOWN, ^starter_ref, :process, ^starter, _reason}, 5_000

      # The caller is gone and the program is not.
      assert await_os_process(token, :present)
      assert Process.alive?(program)

      program_ref = Process.monitor(program)
      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^program_ref, :process, ^program, :normal}, 10_000
      assert await_os_process(token, :absent)
    end
  end

  describe "process cleanup" do
    # A spent program must not leave its process behind: it would hold a monitor
    # and an unread queue for as long as its owner lived.
    test "a run/2 timeout leaves no program process behind" do
      before = program_count()

      assert Exec.run("sleep 30", timeout: 200) === {:error, :timeout}

      assert await_program_count(before)
    end

    test "a halted stream!/2 leaves no program process behind" do
      before = program_count()

      assert "echo ready; sleep 30" |> Exec.stream!() |> Enum.take(1) === [{:stdout, "ready\n"}]

      assert await_program_count(before)
    end

    test "a completed run/2 leaves no program process behind" do
      before = program_count()

      assert {:ok, %Result{stdout: "hi\n"}} = Exec.run("echo hi")

      assert await_program_count(before)
    end

    # A read timeout that fires just as its event arrives leaves a stale
    # :read_timeout in the mailbox with no reader to answer. Sending one
    # directly tests the guarantee that matters: it is ignored, and the queued
    # events survive.
    test "a stray :read_timeout does not disturb a program with no reader waiting" do
      {:ok, program} = Exec.open("echo hi")

      send(program, :read_timeout)

      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
      assert Process.alive?(program)
      assert Exec.read(program) === {:ok, {:exit, 0}}
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

  describe "large and chunked output" do
    test "joins output arriving in many chunks into one binary" do
      {:ok, result} = Exec.run(~S(head -c 1000000 /dev/zero | tr '\0' a))

      assert byte_size(result.stdout) === 1_000_000
    end

    test "stream!/2 reassembles a line split across chunks" do
      [{:stdout, line} | _] =
        ~S(head -c 1000000 /dev/zero | tr '\0' a; echo) |> Exec.stream!() |> Enum.to_list()

      assert byte_size(line) === 1_000_001
    end
  end

  describe "output that is not text" do
    test "run/2 returns raw bytes rather than assuming UTF-8" do
      {:ok, result} = Exec.run(~S(printf '\377\376'))

      assert result.stdout === <<0xFF, 0xFE>>
    end

    test "stream!/2 splits lines on bytes rather than assuming UTF-8" do
      assert ~S(printf '\377\n\376\n') |> Exec.stream!() |> Enum.to_list() ===
               [stdout: <<0xFF, ?\n>>, stdout: <<0xFE, ?\n>>, exit: 0]
    end
  end

  describe "cd and env options" do
    test "cd: runs the command in the given directory" do
      assert {:ok, %Result{stdout: "/usr/local/fixtures\n"}} =
               Exec.run("pwd", cd: "/usr/local/fixtures")
    end

    test "env: adds variables to the command's environment" do
      assert {:ok, %Result{stdout: "bar\n"}} = Exec.run(~S(echo "$FOO"), env: [{"FOO", "bar"}])
    end
  end

  # A fractional argument `sleep` accepts, unique per test, so one test's
  # program is never confused with another's or with a stray from an earlier
  # run. 300 seconds is far longer than any poll below, so a program going
  # missing means it was reaped and never that it finished on its own.
  defp unique_token, do: "300.0#{System.unique_integer([:positive])}"

  defp program_count, do: Exec.ProgramSupervisor |> DynamicSupervisor.which_children() |> length()

  # A supervisor drops a child when it handles that child's exit, which is a
  # message behind the call that caused it.
  defp await_program_count(expected, attempts \\ 100)

  defp await_program_count(expected, 0) do
    flunk("the program count never returned to #{expected}; it is #{program_count()}")
  end

  defp await_program_count(expected, attempts) do
    if program_count() === expected do
      true
    else
      Process.sleep(50)
      await_program_count(expected, attempts - 1)
    end
  end

  defp await_os_process(token, expected, attempts \\ 150)

  defp await_os_process(token, expected, 0) do
    flunk("the OS process for `sleep #{token}` was never #{expected}")
  end

  defp await_os_process(token, expected, attempts) do
    {out, _status} = System.cmd("pgrep", ["-f", "sleep #{token}$"], stderr_to_stdout: true)
    running? = String.trim(out) !== ""

    if running? === (expected === :present) do
      true
    else
      Process.sleep(100)
      await_os_process(token, expected, attempts - 1)
    end
  end
end
