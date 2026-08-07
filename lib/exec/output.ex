defmodule Exec.Output do
  @moduledoc """
  What a command printed, and how it ended.

  You get one of these back from `Exec.run/2`.

  ## Fields

    * `:stdout` — a list of strings, one per chunk the command wrote on
      stdout, in the order they arrived. Empty when nothing was written.

    * `:stderr` — the same, for stderr.

    * `:exit_status` — the exit code the command ended with, as a shell
      would report it: `0` for success, `1` for `exit 1`. When the command
      was killed by a signal this is `{:signal, name}`, e.g.
      `{:signal, :sigterm}` — or `{:signal, number}` when the signal isn't
      one `:exec.signal/1` recognises (real-time signals, for example).
  """

  defstruct [:stdout, :stderr, :exit_status]

  @type t :: %__MODULE__{
          stdout: [binary()],
          stderr: [binary()],
          exit_status: non_neg_integer() | {:signal, atom() | pos_integer()}
        }
end
