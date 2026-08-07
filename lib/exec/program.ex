defmodule Exec.Program do
  @moduledoc false

  # One process per running program.
  #
  # It calls :exec.run, so the program's output is delivered here -- a bare
  # :stdout means "whoever made the call" (exec.erl:337). Output is held in a
  # queue until read/2 asks for it, so nothing ever reaches the caller's
  # mailbox.
  #
  # It monitors the owner and stops the program if the owner dies. erlexec does
  # not do this: under `link` it links whoever called :exec.run (exec.erl:1207),
  # which is this process, not the owner.
  #
  # That link is the reason `link` is used here rather than `monitor`. erlexec
  # kills an OS process when its controller dies (exec.erl:1327), and the
  # controller dies with whatever it is linked to -- so linking it here means
  # the program is reaped however this process goes, including a brutal kill or
  # the supervision tree going down, neither of which leaves us any code to run.
  # Under `monitor` the controller outlives us and the OS process is orphaned.
  #
  # The link is bidirectional, and a non-zero exit does exit the controller
  # abnormally (exec.erl:1230), so this process traps exits. The program's exit
  # then arrives as a message like any other. None of this reaches the owner,
  # which is held by a monitor and never a link.

  use GenServer

  # `owner` is whoever the program belongs to. It defaults to the calling
  # process, so starting one directly needs nothing extra; going through the
  # supervisor does, because start_link then runs in the supervisor.
  def start_link(command, owner, opts \\ []) do
    GenServer.start_link(__MODULE__, {command, owner, opts})
  end

  # :infinity on the call itself: the timeout is the worker's to enforce, so a
  # slow program never exits the caller and never leaves a late reply behind.
  def read(conn, timeout), do: GenServer.call(conn, {:read, timeout}, :infinity)

  def write(conn, data), do: GenServer.call(conn, {:write, data})

  def stop(conn), do: GenServer.call(conn, :stop)

  # stop/1 ends the OS program and leaves this process alive, because the caller
  # still has the remaining events -- including the exit -- to read. shutdown/1
  # is for a caller that is done reading: run/2 after its timeout, a halted
  # stream!/2. Without it the exit arrives with no reader, gets queued, and this
  # process sits holding a monitor and a queue nobody will ever read until the
  # owner dies -- unbounded accumulation under a long-lived owner.
  #
  # Terminating is safe: the controller link reaps the OS program however this
  # process goes (see the module comment above), so the stop below is a
  # courtesy, not the mechanism.
  #
  # Both calls may find the process already gone -- it stops itself on the exit
  # event, which can land between the caller's decision and this call -- so a
  # :noproc exit is the expected outcome, not an error.
  def shutdown(conn) do
    # Only the stop is allowed to fail quietly. Wrapping the termination in the
    # same catch would mean a failed stop skips it, which silently restores the
    # leak this function exists to prevent.
    _ =
      try do
        stop(conn)
      catch
        :exit, _reason -> :ok
      end

    try do
      GenServer.stop(conn, :normal)
    catch
      :exit, _reason -> :ok
    end
  end

  def kill(conn, signal), do: GenServer.call(conn, {:kill, signal})

  # The owner monitor is never demonitored: this process stops on that DOWN,
  # and monitors are released when the process holding them dies.
  #
  # Trapping exits is what makes the controller's link (see above) survivable:
  # the program's exit arrives as {:EXIT, controller, reason} instead of killing
  # us. It is set before :exec.run so a program that exits immediately cannot
  # land in the window before it.
  @impl GenServer
  def init({command, owner, opts}) do
    Process.flag(:trap_exit, true)

    case :exec.run(command, build_exec_options(opts)) do
      {:ok, _controller, os_pid} ->
        {:ok,
         %{
           os_pid: os_pid,
           owner_ref: Process.monitor(owner),
           events: :queue.new(),
           reader: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  # The exit is the last thing there is to read, so the process ends with it.
  def handle_call({:read, timeout}, from, state) do
    case :queue.out(state.events) do
      {{:value, {:exit, _} = event}, events} ->
        {:stop, :normal, {:ok, event}, %{state | events: events}}

      {{:value, event}, events} ->
        {:reply, {:ok, event}, %{state | events: events}}

      {:empty, _events} ->
        {:noreply, %{state | reader: {from, start_read_timer(timeout)}}}
    end
  end

  def handle_call({:write, :eof}, _from, state) do
    {:reply, :exec.send(state.os_pid, :eof), state}
  end

  def handle_call({:write, data}, _from, state) do
    {:reply, :exec.send(state.os_pid, IO.iodata_to_binary(data)), state}
  end

  # stop sends SIGTERM and escalates to SIGKILL; kill sends one signal now.
  def handle_call(:stop, _from, state), do: {:reply, :exec.stop(state.os_pid), state}

  def handle_call({:kill, signal}, _from, state) do
    {:reply, :exec.kill(state.os_pid, signal), state}
  end

  @impl GenServer
  def handle_info({stream, _os_pid, data}, state) when stream in [:stdout, :stderr] do
    deliver_or_queue(state, {stream, data})
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    # The owner is gone, so this process goes too, and the controller's link
    # takes the program with it (see above). We do not stop the program here:
    # that would be a second stop racing erlexec's own link teardown, and when
    # the program has already exited the teardown's stop lands on a dead os_pid
    # with no caller to answer -- which erlexec logs as an unknown message.
    {:stop, :normal, state}
  end

  # The controller is the only process this one is linked to, and gen_server
  # handles its parent's exit itself, so any EXIT reaching here is the program
  # ending. Its reason carries the exit status (exec.erl:1224-1231).
  def handle_info({:EXIT, _controller, reason}, state) do
    deliver_or_queue(state, {:exit, decode_exit_reason(reason)})
  end

  def handle_info(:read_timeout, %{reader: {from, _timer}} = state) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %{state | reader: nil}}
  end

  # A :read_timeout with nobody waiting for it. The timer fired just as the
  # event it was bounding arrived, or a second read/2 replaced the reader and
  # orphaned the first one's timer. Either way there is no caller to answer, and
  # crashing here would kill the running program and lose every queued event.
  def handle_info(:read_timeout, state), do: {:noreply, state}

  # Hands an event to a waiting reader, or queues it until one asks.
  defp deliver_or_queue(%{reader: nil} = state, event) do
    {:noreply, %{state | events: :queue.in(event, state.events)}}
  end

  defp deliver_or_queue(%{reader: {from, timer}} = state, {:exit, _} = event) do
    _ = cancel_read_timer(timer)
    GenServer.reply(from, {:ok, event})
    {:stop, :normal, %{state | reader: nil}}
  end

  defp deliver_or_queue(%{reader: {from, timer}} = state, event) do
    _ = cancel_read_timer(timer)
    GenServer.reply(from, {:ok, event})
    {:noreply, %{state | reader: nil}}
  end

  defp start_read_timer(:infinity), do: nil
  defp start_read_timer(timeout), do: Process.send_after(self(), :read_timeout, timeout)

  defp cancel_read_timer(nil), do: :ok

  # Cancelling does not unsend: a timer that has already fired leaves its
  # message in the mailbox, where it would be handled after the reader is gone.
  defp cancel_read_timer(timer) do
    _ = Process.cancel_timer(timer)

    receive do
      :read_timeout -> :ok
    after
      0 -> :ok
    end
  end

  defp build_exec_options(opts) do
    stdin? = Keyword.get(opts, :stdin, true)
    stdout? = Keyword.get(opts, :stdout, true)
    stderr? = Keyword.get(opts, :stderr, true)

    # :link is what makes erlexec reap the program when this process dies; see
    # the module comment above.
    #
    # {:group, 0} puts the program in a new process group of its own, and
    # :kill_group makes erlexec signal that whole group rather than the single
    # pid it tracked. Both are needed, and only together.
    #
    # A string command is interpreted by /bin/sh, which may run the program as a
    # child rather than becoming it. Signalling only the tracked pid then kills
    # the shell and leaves the program orphaned to init -- so stop/1 returns :ok
    # while the program keeps running. Signalling the group reaches the program
    # whichever shape the shell chose.
    #
    # :kill_group without {:group, 0} would signal erlexec's own process group,
    # killing the VM-wide exec-port and every other running program with it.
    proplist = [:link, :kill_group, {:group, 0}]
    proplist = if stdin?, do: [:stdin | proplist], else: proplist
    proplist = if stdout?, do: [:stdout | proplist], else: proplist
    proplist = if stderr?, do: [:stderr | proplist], else: proplist

    # Only the three stream flags read just above are dropped. Exec.open/2 has
    # already taken :owner and :timeout, which never reach this module.
    #
    # :group is deliberately absent: this module sets it, and a caller
    # overriding it would silently break the lifetime guarantee above.
    run_opts = Keyword.drop(opts, [:stdin, :stdout, :stderr])

    proplist ++ run_opts
  end

  defp decode_exit_reason(status) do
    case status do
      :normal -> 0
      {:exit_status, raw} when Bitwise.band(raw, 0xFF) === 0 -> Bitwise.bsr(raw, 8)
      {:exit_status, raw} -> raw |> Bitwise.band(0x7F) |> :exec.signal() |> then(&{:signal, &1})
      other -> other
    end
  end
end
