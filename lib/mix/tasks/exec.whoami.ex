defmodule Mix.Tasks.Exec.Whoami do
  @shortdoc "Run whoami as a specified Exec user"

  @moduledoc """
  Run `whoami` under a given non-root Exec user.

      mix exec.whoami
      mix exec.whoami --username elixir_exec
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Exec.Utils.ensure_app_started!()

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [username: :string],
        aliases: [u: :username]
      )

    case Exec.Core.run("whoami", user: opts[:username], sync: true) do
      {:ok, result} ->
        result
        |> Keyword.fetch!(:stdout)
        |> print_stdout()

      {:error, reason} ->
        Mix.raise("whoami failed: #{inspect(reason)}")
    end
  end

  defp print_stdout(entries) do
    entries
    |> List.flatten()
    |> Enum.each(&IO.write/1)
  end
end
