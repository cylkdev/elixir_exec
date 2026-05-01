defmodule ElixirExec.RunnerTest do
  # `async: false` is mandatory: every integration test starts real OS
  # processes and relies on the order of messages arriving in the test
  # process's mailbox. Running in parallel would interleave those messages
  # across tests.
  # credo:disable-for-next-line BlitzCredoChecks.NoAsyncFalse
  use ExUnit.Case, async: false

  alias ElixirExec.Output
  alias ElixirExec.OSProcess, as: ExProcess
  alias ElixirExec.Runner
  alias ElixirExec.StreamSupervisor

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # The application supervisor boots ElixirExec.StreamSupervisor automatically;
    # if running in isolation start it here so streaming paths still work.
    case Process.whereis(StreamSupervisor) do
      nil -> start_supervised!({StreamSupervisor, []})
      _pid -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Validation rejection
  # ---------------------------------------------------------------------------

  describe "run/3 validation" do
    test "rejects unknown options with a NimbleOptions ValidationError" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               Runner.run(:run, "ls", bogus_key: 1)
    end

    test "rejects sync: true with stdout: :stream as illegal combination" do
      assert Runner.run(:run, "echo hi", sync: true, stdout: :stream) ===
               {:error, {:illegal_combination, :sync_with_stream}}
    end
  end

  # ---------------------------------------------------------------------------
  # Async happy path — :run
  # ---------------------------------------------------------------------------

  describe "run/3 async with :run" do
    test "returns %ElixirExec.OSProcess{} struct with controller, os_pid, and nil stream" do
      assert {:ok, %ExProcess{} = process} =
               Runner.run(:run, "echo hi", monitor: true, stdout: true)

      assert is_pid(process.controller)
      assert is_integer(process.os_pid)
      assert process.os_pid >= 0
      assert process.stream === nil
    end

    test "delivers {:stdout, _, _} and DOWN messages to the test mailbox" do
      assert {:ok, %ExProcess{controller: pid, os_pid: os_pid, stream: nil}} =
               Runner.run(:run, "echo hi", monitor: true, stdout: true)

      assert_receive {:stdout, ^os_pid, "hi\n"}, 1_000
      assert_receive {:DOWN, ^os_pid, :process, ^pid, _reason}, 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # Async happy path — :run_link
  # ---------------------------------------------------------------------------

  describe "run/3 async with :run_link" do
    test "returns %ElixirExec.OSProcess{} when linking" do
      Process.flag(:trap_exit, true)

      assert {:ok, %ExProcess{controller: pid, os_pid: os_pid, stream: nil}} =
               Runner.run(:run_link, "true", [])

      assert is_pid(pid)
      assert is_integer(os_pid)

      # Drain any EXIT message the linked controller may emit so it does not
      # leak into a subsequent test.
      receive do
        {:EXIT, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Sync path
  # ---------------------------------------------------------------------------

  describe "run/3 sync" do
    test "returns %ElixirExec.Output{} with captured stdout" do
      assert {:ok, %Output{stdout: ["hi\n"], stderr: []}} =
               Runner.run(:run, "echo hi", sync: true, stdout: true)
    end
  end

  # ---------------------------------------------------------------------------
  # Stream path
  # ---------------------------------------------------------------------------

  describe "run/3 stream" do
    test "returns %ElixirExec.OSProcess{} whose stream yields stdout lines" do
      assert {:ok, %ExProcess{stream: enum} = process} =
               Runner.run(
                 :run,
                 "for i in 1 2 3; do echo Iter$i; done",
                 monitor: true,
                 stdout: :stream
               )

      assert is_pid(process.controller)
      assert is_integer(process.os_pid)
      refute is_nil(enum)

      assert Enum.to_list(enum) === ["Iter1\n", "Iter2\n", "Iter3\n"]
    end

    test "stream worker is supervised under ElixirExec.StreamSupervisor" do
      # Snapshot the supervisor's children before starting a stream.
      before_pids =
        StreamSupervisor
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_, pid, _, _} -> pid end)
        |> MapSet.new()

      assert {:ok, %ExProcess{stream: enum}} =
               Runner.run(
                 :run,
                 "for i in 1 2 3; do echo Iter$i; done",
                 monitor: true,
                 stdout: :stream
               )

      # The newly started worker must appear under the supervisor.
      after_children = DynamicSupervisor.which_children(StreamSupervisor)

      new_workers =
        for {_, pid, _, _} <- after_children, not MapSet.member?(before_pids, pid), do: pid

      assert match?([_ | _], new_workers)

      # Drain so the worker shuts down cleanly and doesn't leak across tests.
      _ = Enum.to_list(enum)
    end
  end

  # ---------------------------------------------------------------------------
  # Notes on error-path teardown
  # ---------------------------------------------------------------------------

  # Error-path teardown of the stream server (the {:error, _} branch with a
  # live stream_handle) is hard to provoke directly: :exec.run/2 rarely fails
  # after Options.validate_command/1 succeeds. It is covered indirectly by
  # exercising the success path repeatedly without leaking workers; explicit
  # coverage here would require mocking :exec.run/2, which would couple the
  # test to internals rather than the public contract.
end
