defmodule ElixirExec.OSProcess do
  @moduledoc """
  A handle to a running external program.

  You get one of these back when you start a command in the background
  with `ElixirExec.run/2`, `ElixirExec.run_link/2`,
  `ElixirExec.stream/2`, or `ElixirExec.manage/2`. Hold onto it: that's
  how you talk to the program afterwards.

  ## Fields

    * `:controller` — the Elixir process that owns the running program
      for you. Pass it (or `:os_pid`) to functions like
      `ElixirExec.kill/2` or `ElixirExec.write_stdin/2` when you want to
      do something to the program.
    * `:os_pid` — the operating-system process id of the running
      program. The same number you'd see in `ps` or in Activity Monitor.
    * `:stream` — `nil` for a normal background run. When you started
      the command with `ElixirExec.stream/2` (or with `stdout: :stream`),
      this holds something you can iterate over with `Enum` or `Stream`
      to read the program's output as it arrives.

  ## Decoding exit reasons

  `decode_reason/1` turns the raw exit reason that `:erlexec` reports
  into a plain integer where it can. A clean exit (`:normal`) becomes
  `0`. A specific exit code (`{:exit_status, n}`) becomes `n`. Anything
  else — like `:killed` — is returned unchanged so you can decide what
  to do with it.

      iex> ElixirExec.OSProcess.decode_reason(:normal)
      0

      iex> ElixirExec.OSProcess.decode_reason({:exit_status, 9})
      9

      iex> ElixirExec.OSProcess.decode_reason({:exit_status, 0})
      0

      iex> ElixirExec.OSProcess.decode_reason(:killed)
      :killed
  """

  @enforce_keys [:controller, :os_pid]
  defstruct [:controller, :os_pid, stream: nil]

  @type t :: %__MODULE__{
          controller: pid(),
          os_pid: non_neg_integer(),
          stream: nil | Enumerable.t()
        }

  @doc """
  Decodes the exit reason that `:erlexec` reports into a plain integer
  when it can.

  ## Parameters

    - `reason` - `term()`. The exit reason as it arrives from
      `:erlexec`, typically inside a `:DOWN` message or as a
      `stop_and_wait/2` return.

  ## Returns

  `0` when `reason` is the atom `:normal` (a clean exit).

  The integer `n` when `reason` is `{:exit_status, n}` — including
  when `n` is `0`.

  The original term, unchanged, for anything else: signal atoms (e.g.
  `:killed`), unrecognised tuples, or custom reasons. The caller
  decides how to interpret these.

  ## Examples

      iex> ElixirExec.OSProcess.decode_reason(:normal)
      0

      iex> ElixirExec.OSProcess.decode_reason({:exit_status, 9})
      9

      iex> ElixirExec.OSProcess.decode_reason({:exit_status, 0})
      0

      iex> ElixirExec.OSProcess.decode_reason(:killed)
      :killed
  """
  @spec decode_reason(term()) :: non_neg_integer() | term()
  def decode_reason(:normal), do: 0
  def decode_reason({:exit_status, n}) when is_integer(n), do: n
  def decode_reason(other), do: other
end
