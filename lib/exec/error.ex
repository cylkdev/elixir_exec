defmodule Exec.Error do
  @moduledoc """
  Raised by `Exec.stream!/2` when a command cannot be started.

  The `:reason` field carries the same value `Exec.open/2` would have returned
  in `{:error, reason}`.
  """

  defexception [:reason]

  @impl Exception
  def message(%__MODULE__{reason: reason}) do
    "could not start the command: #{inspect(reason)}"
  end
end
