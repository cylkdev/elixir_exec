defmodule Exec.Result do
  @moduledoc """
  The output and exit status of a command run to completion.

  Returned by `Exec.run/2`.

  ## Fields

    * `:stdout` — everything the command wrote on standard output, as a single
      binary. Empty when the command wrote nothing, or when it was started with
      `stdout: false`.

    * `:stderr` — the same, for standard error.

    * `:exit_status` — the code the command exited with, as a shell reports it:
      `0` for success, `3` for `exit 3`. A command killed by a signal reports
      `{:signal, name}`, such as `{:signal, :sigterm}`, or `{:signal, number}`
      for a signal `:exec.signal/1` does not name, such as a real-time signal.
  """

  defstruct [:stdout, :stderr, :exit_status]

  @type t :: %__MODULE__{
          stdout: binary(),
          stderr: binary(),
          exit_status: Exec.exit_status()
        }
end
