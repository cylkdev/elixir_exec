defmodule ElixirExec.Output do
  @moduledoc """
  What a command printed when it was run with `sync: true`.

  You get one of these back from `ElixirExec.run/2` when you wait for
  the command to finish. It collects everything the command wrote to
  its standard output and standard error.

  ## Fields

    * `:stdout` — a list of strings, one per chunk the command wrote
      on stdout, in the order they arrived. Empty list if the command
      printed nothing on stdout (or if stdout was not captured).

    * `:stderr` — the same, for stderr.
  """

  defstruct stdout: [], stderr: []

  @typedoc """
  Captured output from a synchronous run.
  """
  @type t :: %__MODULE__{
          stdout: [binary()],
          stderr: [binary()]
        }

  @doc """
  Builds an `%ElixirExec.Output{}` from the keyword list returned by a
  synchronous run.

  `:stdout` and `:stderr` are both optional, and key order does not
  matter. Missing keys default to `[]`. Element order within each list
  is preserved exactly as it appears in the input.

  ## Examples

      iex> ElixirExec.Output.from_proplist([])
      %ElixirExec.Output{stdout: [], stderr: []}

      iex> ElixirExec.Output.from_proplist(stdout: ["hi\\n"])
      %ElixirExec.Output{stdout: ["hi\\n"], stderr: []}

      iex> ElixirExec.Output.from_proplist(stderr: ["err\\n"])
      %ElixirExec.Output{stdout: [], stderr: ["err\\n"]}

      iex> ElixirExec.Output.from_proplist(stdout: ["a\\n", "b\\n"], stderr: ["c\\n"])
      %ElixirExec.Output{stdout: ["a\\n", "b\\n"], stderr: ["c\\n"]}
  """
  @spec from_proplist(keyword()) :: t()
  def from_proplist(proplist) when is_list(proplist) do
    %__MODULE__{
      stdout: Keyword.get(proplist, :stdout, []),
      stderr: Keyword.get(proplist, :stderr, [])
    }
  end
end
