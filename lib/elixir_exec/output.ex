defmodule ElixirExec.Output do
  @moduledoc """
  What a command printed when you ran it and waited for it to finish.

  You get one of these back from `ElixirExec.run/2` when you pass
  `sync: true`. It collects everything the command wrote to its
  standard output and standard error.

  ## Fields

    * `:stdout` — a list of strings. Each entry is one chunk the
      command printed to its normal output, in the order it printed
      them. Empty list if the command printed nothing on stdout (or if
      you didn't ask to capture stdout).
    * `:stderr` — same idea, but for what the command printed to its
      error output.

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

  defstruct stdout: [], stderr: []

  @typedoc """
  Captured output from a synchronous run.
  """
  @type t :: %__MODULE__{
          stdout: [binary()],
          stderr: [binary()]
        }

  @doc """
  Builds an `%ElixirExec.Output{}` from the keyword list `:erlexec`
  returns for a synchronous run.

  ## Parameters

    - `proplist` - `keyword()`. The proplist as returned by
      `:erlexec` — `:stdout` and `:stderr` are both optional. The
      order of keys does not matter.

  ## Returns

  A new `%ElixirExec.Output{}` whose `:stdout` and `:stderr` are
  copied from the corresponding entries in `proplist`. Any missing
  key defaults to `[]`. Element order within each list is preserved
  exactly as it appears in the input.

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
