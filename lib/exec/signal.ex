defmodule Exec.Signal do
  @moduledoc false

  # Signal names and numbers, both directions, and the decoding of the exit
  # status erlexec reports. Exec resolves names with it before signalling, and
  # Exec.Program decodes each exit with it before sending it to the owner, so
  # every owner receives the same finished event.

  # Signal numbers differ from system to system. SIGUSR1 is 10 on Linux and 30
  # on Darwin, SIGCHLD 17 and 20, SIGSTOP 19 and 17.
  #
  # erlexec's own table (exec.erl:816) hardcodes the Linux numbers, so asking it
  # to translate :sigchld on a Mac sends signal 17 -- SIGSTOP there. Its table
  # also omits :sigusr1 and :sigusr2 entirely, the two signals conventionally
  # reserved for application use, and it raises function_clause on any name
  # missing from it. That raise happens inside Exec.Program, whose link to
  # erlexec's controller then kills the running program: a typo destroys the
  # thing it was meant to signal.
  #
  # Resolving names here, and passing :exec.kill/2 an integer, bypasses
  # erlexec's table entirely and removes that crash. The same tables are
  # read backwards by name/1 below, so a signal number arriving from a
  # dying program is named from the running system's table rather than from
  # erlexec's.
  #
  # The entries below carry the number each name has on both Linux and Darwin.
  # The grouping rests only on the numbers having been checked and found to
  # agree; any of them could differ, as SIGUSR1, under 16, does.
  # Checked with `kill -l <number>` on Debian and `python3 -c "import signal"`
  # on macOS 15.
  @signals_shared %{
    sighup: 1,
    sigint: 2,
    sigquit: 3,
    sigill: 4,
    sigtrap: 5,
    sigabrt: 6,
    sigfpe: 8,
    sigkill: 9,
    sigsegv: 11,
    sigpipe: 13,
    sigalrm: 14,
    sigterm: 15,
    sigttin: 21,
    sigttou: 22,
    sigxcpu: 24,
    sigxfsz: 25,
    sigvtalrm: 26,
    sigprof: 27,
    sigwinch: 28
  }

  # The names whose number the two systems disagree about.
  @signals_linux %{
    sigusr1: 10,
    sigusr2: 12,
    sigchld: 17,
    sigcont: 18,
    sigstop: 19,
    sigtstp: 20
  }

  @signals_darwin %{
    sigusr1: 30,
    sigusr2: 31,
    sigchld: 20,
    sigcont: 19,
    sigstop: 17,
    sigtstp: 18
  }

  # Decodes the exit status erlexec reports for a program. It lives with the
  # signal tables because it reads them backwards, and one module owning both
  # directions of that mapping is what keeps a name sent and a name reported the
  # same name.
  #
  # The bits are the ones erlexec's own status/1 reads: the signal in the low
  # seven, the core-dump flag above them, the exit code in the next byte.
  def decode_exit(exit_reason) do
    signal = Bitwise.band(exit_reason, 0x7F)
    exited? = signal === 0

    %{
      exit_reason: exit_reason,
      exit_code: if(exited?, do: Bitwise.bsr(exit_reason, 8), else: nil),
      signal: if(exited?, do: nil, else: signal),
      exit_status: if(exited?, do: nil, else: name(signal)),
      core_dump: Bitwise.band(exit_reason, 0x80) === 0x80
    }
  end

  # A number the running system's table lacks a name for is named `nil`.
  # The number itself is kept in the exit's `:signal`.
  defp name(number) do
    Enum.find_value(table(), fn {name, n} -> if n === number, do: name end)
  end

  # Every entry in each platform map has a number distinct from every entry in
  # the shared map, so the reverse lookup above has exactly one answer.
  defp table do
    case :os.type() do
      {:unix, :darwin} -> Map.merge(@signals_shared, @signals_darwin)
      {:unix, _} -> Map.merge(@signals_shared, @signals_linux)
    end
  end

  def to_int!(number) when is_integer(number), do: number

  def to_int!(name) when is_atom(name) do
    case Map.fetch(table(), name) do
      {:ok, number} ->
        number

      :error ->
        raise ArgumentError, "unknown signal #{inspect(name)}"
    end
  end
end
