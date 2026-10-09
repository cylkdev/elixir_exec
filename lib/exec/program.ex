defmodule Exec.Program do
  @moduledoc false

  alias Exec.Core

  require Logger

  # One process per running program.
  #
  # It calls :exec.run, so the program's output is delivered here -- a bare
  # :stdout means "whoever made the call" (exec.erl:337). Each piece is
  # forwarded to the owner as a `{program, event}` message, in the order erlexec
  # delivered it, and Exec.read/2 receives them there.
  #
  # It monitors the owner and stops the program if the owner dies. That job
  # falls to this process: under `link` erlexec links whoever called :exec.run
  # (exec.erl:1207), which is this process rather than the owner.
  #
  # That link is the reason `link` is used here rather than `monitor`. erlexec
  # kills an OS process when its controller dies (exec.erl:1327), and the
  # controller dies with whatever it is linked to -- so linking it here means
  # the program is reaped however this process goes, including a brutal kill or
  # the supervision tree going down, both of which end us before any further
  # code of ours runs.
  # Under `monitor` the controller outlives us and the OS process is orphaned.
  #
  # The link is bidirectional, and a non-zero exit does exit the controller
  # abnormally (exec.erl:1230), so this process traps exits. The program's exit
  # then arrives as a message like any other. All of this stays between this
  # process and the controller; the owner is held by a monitor alone.

  use GenServer

  # The four signals exec-port installs a termination handler for
  # (exec.cpp:151-154), by number: SIGHUP, SIGINT, SIGPIPE, SIGTERM. Those four
  # numbers happen to be the same on Linux and Darwin, checked one at a time,
  # and that agreement was observed rather than guaranteed by any rule -- SIGUSR1
  # is below 16 too, and is 10 on Linux and 30 on Darwin.
  @swallowable_signals [1, 2, 13, 15]

  # Far longer than any observed fork-to-execve window, and short enough to end
  # before any realistic program has begun meaningful work.
  @spawn_window_ms 250

  # Long enough for the execve to have completed in every observed case.
  @resend_after_ms 50

  # `owner` is whoever the program belongs to. It defaults to the calling
  # process, so starting one directly works with the default; going through the
  # supervisor needs it set, because start_link then runs in the supervisor.
  def start_link(command, owner, opts \\ []) do
    GenServer.start_link(__MODULE__, {command, owner, opts})
  end

  def write(conn, data, opts \\ []), do: call(conn, {:write, data}, opts)

  def stop(conn, opts \\ []), do: call(conn, :stop, opts)

  # shutdown/1 is for a caller that is done with the program: run/2 after its
  # timeout, a halted stream/2.
  #
  # Terminating is all it takes: the controller link reaps the OS program
  # however this process goes (see the module comment above), so terminating is
  # the first and only step.
  #
  # The process may already be gone -- it stops itself on the exit event, which
  # can land between the caller's decision and this call -- so a :noproc exit is
  # the expected outcome and counts as success.
  def shutdown(conn, opts \\ []) do
    GenServer.stop(conn, :normal, opts[:timeout] || 5_000)
  catch
    :exit, {:noproc, _} -> :ok
  end

  def kill(conn, signal, opts \\ []), do: call(conn, {:kill, signal}, opts)

  def info(conn, opts \\ []), do: call(conn, :info, opts)

  # This process stops itself when the program exits, so a later call finds it
  # gone. GenServer.call exits the caller with :noproc, which says more about
  # how this is built than about what happened. To a caller it means the same as
  # a program that has ended.
  defp call(conn, message, opts) do
    GenServer.call(conn, message, opts[:timeout] || 5_000)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] -> {:error, :not_running}
  end

  # The owner monitor stays for this process's whole life: this process stops
  # on that DOWN, and monitors are released when the process holding them dies.
  #
  # Trapping exits is what makes the controller's link (see above) survivable:
  # the program's exit arrives as {:EXIT, controller, reason} instead of killing
  # us. It is set before :exec.run so even a program that exits immediately
  # lands after it.
  @impl GenServer
  def init({command, owner, opts}) do
    Process.flag(:trap_exit, true)

    case Core.run(command, opts) do
      {:ok, controller_pid, os_pid} ->
        {:ok,
         %{
           controller_pid: controller_pid,
           os_pid: os_pid,
           owner: owner,
           owner_ref: Process.monitor(owner),
           started_at: System.monotonic_time(:millisecond)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{handle_pid: self(), controller_pid: state.controller_pid, os_pid: state.os_pid}

    {:reply, {:ok, info}, state}
  end

  def handle_call({:write, :eof}, _from, state) do
    {:reply, Core.send(state.os_pid, :eof), state}
  end

  def handle_call({:write, data}, _from, state) do
    {:reply, Core.send(state.os_pid, IO.iodata_to_binary(data)), state}
  end

  # stop sends SIGTERM and escalates to SIGKILL; kill sends one signal now.
  def handle_call(:stop, _from, state), do: {:reply, Core.stop(state.os_pid), state}

  def handle_call({:kill, signal}, _from, state) do
    {:reply, Core.kill(state.os_pid, signal), schedule_resend(state, signal)}
  end

  @impl GenServer
  def handle_info({stream, _os_pid, data}, state) when stream in [:stdout, :stderr] do
    send(state.owner, {self(), %{stream => data}})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    # The owner is gone, so the program goes too. This process stops it with a
    # stop erlexec answers, and ends when the program's exit arrives below.
    # erlexec's own link teardown stops the program fire-and-forget
    # (exec.erl:1338); a program that exits just as its owner dies turns that
    # stop into an "unknown msg" warning. Stopping here first means the exit is
    # handled before the controller ends, so the teardown finds the program
    # already gone.
    Core.stop(state.os_pid)
    {:noreply, state}
  end

  # The controller is the only process this one is linked to, and gen_server
  # handles its parent's exit itself, so any EXIT reaching here is the program
  # ending. Its reason carries the exit status (exec.erl:1224-1231). The exit is
  # the last thing the program produces, so this process ends with it.
  def handle_info({:EXIT, _controller, reason}, state) do
    send(state.owner, {self(), Exec.Signal.decode_exit(exit_reason(reason))})
    {:stop, :normal, state}
  end

  # The program is still running 50ms after a signal that exec-port's inherited
  # handler may have swallowed. Send it again, and keep doing so until it exits
  # or the spawn window closes.
  def handle_info({:resend, signal}, state) do
    case Core.kill(state.os_pid, signal) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "resending signal #{signal} to pid #{state.os_pid} failed: #{inspect(reason)}"
        )
    end

    {:noreply, schedule_resend(state, signal)}
  end

  # erlexec reports a program that "exited with status 0" as `normal`, and every
  # other exit as `{exit_status, Status}`.
  defp exit_reason(:normal), do: 0
  defp exit_reason({:exit_status, status}), do: status

  # A signal swallowed in the fork-to-execve window is lost before it reaches
  # the program, so sending it again is the difference between the caller's
  # instruction being carried out and being silently dropped.
  #
  # Retried rather than tried once: a single retry after 50ms falls short of a
  # bound. On a loaded machine the window can outlast it, and then the original
  # and the retry are both swallowed and the signal is lost anyway. What bounds
  # this is
  # @spawn_window_ms: sends stop once the program is that old, or once it has
  # exited. At 50ms apart within a 250ms window that is at most six further
  # sends, the last at most 300ms after the program started.
  #
  # This treats a swallowed signal and one the program deliberately ignored
  # alike, so a program that installs its own handler for one of these four
  # inside the window may see it several times rather than twice. That is
  # accepted, weighed against a signal being lost outright roughly one time in
  # eleven: a duplicate is a nuisance the caller can see and reason about, while
  # a loss is the instruction silently vanishing.
  #
  # Delete this once erlexec resets the child's signal dispositions before
  # execve; the reproduction and the proposed fix are in ../erlexec_signal_loss.
  defp schedule_resend(state, signal) when signal in @swallowable_signals do
    if System.monotonic_time(:millisecond) - state.started_at <= @spawn_window_ms do
      Process.send_after(self(), {:resend, signal}, @resend_after_ms)
    end

    state
  end

  defp schedule_resend(state, _signal), do: state
end
