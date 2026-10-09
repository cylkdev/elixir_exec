defmodule Exec.Result do
  @moduledoc """
  The output and exit status of a command run to completion.

  Returned by `Exec.run/2`.

  ## Fields

    * `:stdout` — everything the command wrote on standard output, as a single
      binary. Empty when the command wrote zero bytes, or when it was started with
      `stdout: false`.

    * `:stderr` — the same, for standard error.

    * `:exit` — how the command ended, as described in `t:Exec.exit/0`.
  """

  defstruct [:stdout, :stderr, :exit]

  @type t :: %__MODULE__{
          stdout: binary(),
          stderr: binary(),
          exit: Exec.exit()
        }
end
