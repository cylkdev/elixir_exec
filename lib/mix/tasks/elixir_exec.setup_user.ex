defmodule Mix.Tasks.ElixirExec.SetupUser do
  @shortdoc "Create a dedicated non-root OS user for running child commands"

  @moduledoc """
  Create a dedicated NON-root system user (default: `elixir_exec`) that child
  commands can drop to, so erlexec never has to run as root. Root
  execution stays disabled.

      mix elixir_exec.setup_user
      mix elixir_exec.setup_user --username myapp_exec --group myapp

  Then run commands as that user:

      Exec.run("whoami", user: "elixir_exec")

  or restrict at the exec level in config. `:erlexec` starts itself and reads
  its own options, so this goes under `:erlexec`, not `:elixir_exec`:

      config :erlexec, limit_users: ["elixir_exec"]

  This is a thin wrapper over `priv/scripts/setup-erlexec-user.sh`, which
  performs the platform-specific (Linux/macOS) account creation and will
  re-exec itself via `sudo` for the privileged step.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    script = script_path()

    unless File.exists?(script) do
      Mix.raise("setup-erlexec-user.sh not found at #{script}")
    end

    {_out, status} = System.cmd(script, argv, into: IO.stream(:stdio, :line))
    if status !== 0, do: Mix.raise("setup-erlexec-user.sh exited with status #{status}")
  end

  # Resolves priv/ whether running in this repo or from a consumer's
  # deps/elixir_exec. (Not available inside an escript, but user setup is a
  # deploy-host operation, not an escript-runtime one.)
  defp script_path do
    priv_dir = :code.priv_dir(:elixir_exec)
    priv = List.to_string(priv_dir)
    Path.join([priv, "scripts", "setup-erlexec-user.sh"])
  end
end
