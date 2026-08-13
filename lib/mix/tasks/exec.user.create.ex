defmodule Mix.Tasks.Exec.User.Create do
  @shortdoc "Create a dedicated non-root OS user for running child commands"

  @moduledoc """
  Create a dedicated NON-root system user (default: `elixir_exec`) that child
  commands can drop to, so erlexec never has to run as root. Root
  execution stays disabled.

      mix exec.user.create
      mix exec.user.create --username myapp_exec --group myapp

  Then run commands as that user:

      Exec.run("whoami", user: "elixir_exec")

  or restrict at the exec level in config. `:erlexec` starts itself and reads
  its own options, so this goes under `:erlexec`, not `:elixir_exec`:

      config :erlexec, limit_users: ["elixir_exec"]

  This is a thin wrapper over `priv/scripts/create-erlexec-user.sh`, which
  performs the platform-specific (Linux/macOS) account creation and will
  re-exec itself via `sudo` for the privileged step.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Exec.Utils.ensure_app_started!()

    script = script_path()

    unless File.exists?(script) do
      Mix.raise("create-erlexec-user.sh not found at #{script}")
    end

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [username: :string, group: :string],
        aliases: [u: :username, g: :group]
      )

    username = Keyword.fetch!(opts, :username)
    group = Keyword.get(opts, :group, username)

    # No `root: true` here: that is a server option, not a command option, and
    # erlexec fails the whole run with `{:invalid_option, :root}` when it is
    # passed per command. The script re-execs itself through `sudo` for the one
    # privileged step, so the command itself does not need to start elevated.
    case Exec.Core.run([script, "--username", username, "--group", group], sync: true) do
      {:ok, result} ->
        print_stdout(result.stdout)

      {:error, reason} ->
        Mix.raise("create-erlexec-user.sh failed: #{inspect(reason)}")
    end
  end

  defp print_stdout(entries) do
    entries
    |> List.flatten()
    |> Enum.each(&IO.write/1)
  end

  # Resolves priv/ whether running in this repo or from a consumer's
  # deps/elixir_exec. (Not available inside an escript, but user setup is a
  # deploy-host operation, not an escript-runtime one.)
  defp script_path do
    priv_dir = :code.priv_dir(:elixir_exec)
    priv = List.to_string(priv_dir)
    Path.join([priv, "scripts", "create-erlexec-user.sh"])
  end
end
