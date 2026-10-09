defmodule ExecTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  describe "open/2" do
    test "starts the command and returns a handle its output is read from" do
      {:ok, program} = Exec.open(["echo", "hello"])

      assert {:ok, %{stdout: "hello\n"}} = Exec.read(program)
    end

    test "sends each event to the owner's mailbox as {program, event}" do
      {:ok, program} = Exec.open(["echo", "hello"])

      assert_receive {^program, %{stdout: "hello\n"}}

      assert_receive {^program,
                      %{
                        exit_reason: 0,
                        exit_code: 0,
                        signal: nil,
                        exit_status: nil,
                        core_dump: false
                      }}
    end

    test "returns the executable's name when the executable is missing from PATH" do
      assert {:error, {:executable_not_found, "executable-outside-path"}} =
               Exec.open(["executable-outside-path"])
    end
  end

  describe "a program whose owner exits" do
    test "ends with its owner and logs nothing" do
      test_pid = self()

      log =
        capture_log(fn ->
          spawn(fn ->
            {:ok, program} = Exec.open(["sh", "-c", "echo started; exec sleep 30"])
            {:ok, %{stdout: "started\n"}} = Exec.read(program)
            {:ok, info} = Exec.info(program)
            send(test_pid, {:info, info})
          end)

          assert_receive {:info, %{handle_pid: handle_pid, os_pid: os_pid}}

          handle_ref = Process.monitor(handle_pid)
          assert_receive {:DOWN, ^handle_ref, :process, ^handle_pid, :normal}

          assert false === Exec.os_process_alive?(os_pid)
        end)

      assert "" === log
    end
  end

  describe "read/2" do
    test "returns each event in order, ending with the exit" do
      {:ok, program} = Exec.open(["echo", "hello"])

      assert {:ok, %{stdout: "hello\n"}} = Exec.read(program)

      assert {:ok,
              %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}} =
               Exec.read(program)
    end

    test "returns a timeout when the wait for an event runs out" do
      {:ok, program} = Exec.open(["sleep", "30"])

      assert {:error, :timeout} = Exec.read(program, 0)
    end
  end

  describe "write/2" do
    test "sends data to the program's standard input" do
      {:ok, program} = Exec.open(["cat"])

      assert :ok = Exec.write(program, "hello\n")
      assert {:ok, %{stdout: "hello\n"}} = Exec.read(program)
      assert :ok = Exec.write(program, :eof)

      assert {:ok,
              %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}} =
               Exec.read(program)
    end
  end

  # `sh -c "echo started; exec sleep 30"` prints "started" after its own
  # execve, so reading it first means the program runs with its own signal
  # handling and every signal sent afterwards reaches it as sent.
  describe "stop/1" do
    test "ends the program, which erlexec reports as a graceful termination" do
      {:ok, program} = Exec.open(["sh", "-c", "echo started; exec sleep 30"])
      {:ok, %{stdout: "started\n"}} = Exec.read(program)

      assert :ok = Exec.stop(program)

      assert {:ok,
              %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}} =
               Exec.read(program)
    end
  end

  describe "signal/2" do
    test "ends the program with the signal it was sent" do
      {:ok, program} = Exec.open(["sh", "-c", "echo started; exec sleep 30"])
      {:ok, %{stdout: "started\n"}} = Exec.read(program)

      assert :ok = Exec.signal(program, :sigterm)

      assert {:ok,
              %{
                exit_reason: 15,
                exit_code: nil,
                signal: 15,
                exit_status: :sigterm,
                core_dump: false
              }} =
               Exec.read(program)
    end
  end

  describe "info/1" do
    test "returns the handle, erlexec's controller and the operating-system pid of the running program" do
      {:ok, program} = Exec.open(["sleep", "30"])

      {:ok, %{handle_pid: handle_pid, controller_pid: controller_pid, os_pid: os_pid}} =
        Exec.info(program)

      assert program === handle_pid
      assert true === Process.alive?(controller_pid)
      assert true === Exec.os_process_alive?(os_pid)
    end
  end

  describe "os_process_alive?/1" do
    test "returns true for a running process" do
      {:ok, program} = Exec.open(["sleep", "30"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)

      assert true === Exec.os_process_alive?(os_pid)
    end

    test "returns false for a process that has ended" do
      {:ok, program} = Exec.open(["sleep", "30"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      :ok = Exec.signal(program, :sigkill)

      {:ok, %{exit_reason: 9, exit_code: nil, signal: 9, exit_status: :sigkill, core_dump: false}} =
        Exec.read(program)

      assert false === Exec.os_process_alive?(os_pid)
    end
  end

  describe "send_sigterm/1" do
    test "ends a running process with SIGTERM" do
      {:ok, program} = Exec.open(["sh", "-c", "echo started; exec sleep 30"])
      {:ok, %{stdout: "started\n"}} = Exec.read(program)
      {:ok, %{os_pid: os_pid}} = Exec.info(program)

      assert true === Exec.send_sigterm(os_pid)

      assert {:ok,
              %{
                exit_reason: 15,
                exit_code: nil,
                signal: 15,
                exit_status: :sigterm,
                core_dump: false
              }} =
               Exec.read(program)
    end

    test "returns false for a process that has ended" do
      {:ok, program} = Exec.open(["sleep", "30"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      :ok = Exec.signal(program, :sigkill)

      {:ok, %{exit_reason: 9, exit_code: nil, signal: 9, exit_status: :sigkill, core_dump: false}} =
        Exec.read(program)

      assert false === Exec.send_sigterm(os_pid)
    end
  end

  describe "send_sigkill/1" do
    test "ends a running process with SIGKILL" do
      {:ok, program} = Exec.open(["sleep", "30"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)

      assert true === Exec.send_sigkill(os_pid)

      assert {:ok,
              %{
                exit_reason: 9,
                exit_code: nil,
                signal: 9,
                exit_status: :sigkill,
                core_dump: false
              }} =
               Exec.read(program)
    end

    test "returns false for a process that has ended" do
      {:ok, program} = Exec.open(["sleep", "30"])
      {:ok, %{os_pid: os_pid}} = Exec.info(program)
      :ok = Exec.signal(program, :sigkill)

      {:ok, %{exit_reason: 9, exit_code: nil, signal: 9, exit_status: :sigkill, core_dump: false}} =
        Exec.read(program)

      assert false === Exec.send_sigkill(os_pid)
    end
  end

  describe "run/2" do
    test "returns the command's output and exit" do
      assert {:ok,
              %Exec.Result{
                stdout: "hello\n",
                stderr: "",
                exit: %{
                  exit_reason: 0,
                  exit_code: 0,
                  signal: nil,
                  exit_status: nil,
                  core_dump: false
                }
              }} = Exec.run(["echo", "hello"])
    end

    test "calls :stream with each chunk of output as it arrives" do
      test_pid = self()

      Exec.run(["echo", "hello"], stream: fn chunk -> send(test_pid, chunk) end)

      assert_received {:stdout, "hello\n"}
    end
  end

  describe "stream/2" do
    test "returns the command's output as frames, one per line" do
      assert [
               :"$start_of_stream",
               {:ok, {:stdout, "a\n"}},
               {:ok, {:stdout, "b\n"}},
               {:ok,
                {:exit,
                 %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}}},
               :"$end_of_stream"
             ] = ["printf", "a\\nb\\n"] |> Exec.stream() |> Enum.to_list()
    end
  end
end
