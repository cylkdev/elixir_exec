defmodule ElixirExec.Stream.Drain do
  @moduledoc """
  Internal — wraps a stream `Enumerable` with a finalizer that consumes the
  `monitor: true` `:DOWN` message from the caller's mailbox after iteration
  ends.

  When `ElixirExec.stream/2` runs, it forces `monitor: true` on `:erlexec`,
  which causes the calling process to receive
  `{:DOWN, os_pid, :process, controller_pid, reason}` once the OS process
  exits. The stream worker handles its own monitor independently; the
  caller-side `:DOWN` is left in the mailbox unless it is drained.

  This module installs a `Stream.transform/4` finalizer that receives that
  one message (with a 5 s timeout fallback) when iteration completes. It
  only works when the process consuming the enumeration is the same one
  that owns the mailbox — which is the normal case.
  """

  @default_timeout 5_000

  @doc """
  Wrap `enum` with a finalizer that drains one
  `{:DOWN, os_pid, :process, _, _}` from the calling process's mailbox
  after enumeration ends.

  `timeout` (milliseconds) caps how long the finalizer waits before
  giving up. Defaults to 5 s.
  """
  @spec attach(Enumerable.t(), non_neg_integer(), timeout()) :: Enumerable.t()
  def attach(enum, os_pid, timeout \\ @default_timeout) when is_integer(os_pid) do
    Stream.transform(
      enum,
      fn -> :ok end,
      fn element, :ok -> {[element], :ok} end,
      fn :ok ->
        drain_exit(os_pid, timeout)
        {[], :ok}
      end,
      fn :ok -> :ok end
    )
  end

  @spec drain_exit(non_neg_integer(), timeout()) :: :ok
  defp drain_exit(os_pid, timeout) do
    receive do
      {:DOWN, ^os_pid, :process, _pid, _reason} -> :ok
    after
      timeout -> :ok
    end
  end
end
