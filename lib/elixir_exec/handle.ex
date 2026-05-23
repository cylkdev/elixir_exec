defmodule ElixirExec.Handle do
  @moduledoc """
  Handle for a background-running external program.

  Every call that starts a program in the background —
  `ElixirExec.run/2`, `ElixirExec.run_link/2`, `ElixirExec.stream/2`,
  and `ElixirExec.manage/2` — returns `{:ok, %ElixirExec.Handle{}}`.
  The struct is how the caller addresses the program afterwards:
  pattern-match it, then hand `:controller` or `:os_pid` to any of the
  control or query functions in `ElixirExec` (`stop/1`,
  `stop_and_wait/2`, `kill/2`, `write_stdin/2`, `os_pid/1`, `pid/1`,
  `await_exit/2`, `receive_output/2`, and so on).

  The same struct also carries an optional live `Enumerable` over the
  program's stdout. That field is populated only when the command was
  started with `ElixirExec.stream/2` or `stdout: :stream`; for a plain
  background run it is `nil` and the struct acts purely as a handle.

  ## Fields

    * `:controller` — the Elixir pid that owns the running program.
      Accepted as the target of every `ElixirExec` control function.
    * `:os_pid` — the operating-system process id. The same number
      you'd see in `ps` or Activity Monitor. Also accepted as the
      target of every `ElixirExec` control function.
    * `:stream` — `nil` for a plain background run. When the command
      was started with `ElixirExec.stream/2` (or `stdout: :stream`),
      this is an `Enumerable` over the program's stdout, one chunk
      per element (lines, when the default `:delim` is in effect).
      Iteration ends cleanly when the program exits and the buffer
      drains.

  ## Exit-reason decoding

  This module also exposes `decode_reason/1`, which normalizes a raw
  OS exit reason into the integer code most callers want: `:normal`
  becomes `0`, `{:exit_status, n}` becomes `n`, and any other term
  (signal atoms, unfamiliar tuples) is passed through unchanged.
  `ElixirExec.receive_output/2` and `ElixirExec.await_exit/2` use it
  to translate `:DOWN` reasons before handing them back to the
  caller; you can call it directly when you receive a `:DOWN`
  yourself.
  """

  @enforce_keys [:controller, :os_pid]
  defstruct [:controller, :os_pid, stream: nil]

  @type t :: %__MODULE__{
          controller: pid(),
          os_pid: non_neg_integer(),
          stream: nil | Enumerable.t()
        }

  @doc """
  Decodes a raw exit reason into a plain integer where it can.

  Pass the reason you got back — usually from a `:DOWN` message or
  from `ElixirExec.stop_and_wait/2`.

  Returns `0` for the atom `:normal` (a clean exit).

  Returns the integer `n` for `{:exit_status, n}`, including when `n`
  is `0`.

  Returns the original term, unchanged, for anything else — signal
  atoms like `:killed`, unfamiliar tuples, or custom reasons. The
  caller decides how to interpret these.

  ## Examples

      iex> ElixirExec.Handle.decode_reason(:normal)
      0

      iex> ElixirExec.Handle.decode_reason({:exit_status, 9})
      9

      iex> ElixirExec.Handle.decode_reason({:exit_status, 0})
      0

      iex> ElixirExec.Handle.decode_reason(:killed)
      :killed
  """
  @spec decode_reason(term()) :: non_neg_integer() | term()
  def decode_reason(:normal), do: 0
  def decode_reason({:exit_status, n}) when is_integer(n), do: n
  def decode_reason(other), do: other
end
