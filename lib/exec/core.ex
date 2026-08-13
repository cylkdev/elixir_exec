defmodule Exec.Core do
  @moduledoc """
  `Exec.Core` provides an API for running commands in a subprocess, capturing their output and exit status.
  """

  @default_kill_command "kill -TERM ${CHILD_PID}"

  # erlexec splits its options in two, and the split is not cosmetic.
  #
  # `root`, `limit_users`, `portexe`, `alarm`, `args`, `verbose` and `valgrind`
  # configure the `exec` *server*. It reads them from the `:erlexec` application
  # environment once, when the application boots — see `init/1` in erlexec's
  # `exec.erl`, which keeps only that set.
  #
  # Everything else is a *command* option, validated per run by
  # `check_cmd_options/5`. That function ends in a catch-all that throws
  # `{invalid_option, Opt}`, so handing it a server option does not warn or get
  # ignored: it fails the whole command.
  #
  # So this module never invents `root:` or `limit_users:` for a run. Configure
  # them where erlexec actually reads them, before it starts:
  #
  #     config :erlexec, root: true, user: "app", limit_users: ["app"]
  #
  # This used to be read here with `Application.compile_env/3` and baked in at
  # build time, which was wrong twice over: it froze a deployment detail into
  # the artifact, and it appended `root:`/`limit_users:` to every command, so
  # configuring a user broke every call with `{:invalid_option, :root}`.
  @server_options [:root, :limit_users]

  @doc """
  Run a command with the given options.

  ## Options

    * `:monitor` — Whether to monitor the command process. Defaults to false.
    * `:sync` — Whether to run the command synchronously. Defaults to false.
    * `:executable` — The executable to run. Defaults to the first argument of the command.
    * `:cd` — The working directory for the command. Defaults to the current working directory.
    * `:env` — A list of environment variables for the command. Defaults to an empty list.
    * `:kill` — The signal to send when stopping the command. Defaults to :sigterm.
    * `:kill_timeout` — The timeout in milliseconds before sending a SIGKILL after a SIGTERM. Defaults to 5000.
    * `:nice` — The nice value for the command. Defaults to 0.
    * `:success_exit_code` — The exit code(s) that indicate success. Defaults to 0.
    * `:winsz` — The window size for the command's terminal. Defaults to {80, 24}.
    * `:pty` — Whether to allocate a pseudo-terminal for the command. Defaults to false.
    * `:pty_echo` — Whether to enable echo on the pseudo-terminal. Defaults to true.
    * `:debug` — Whether to enable debug logging for the command. Defaults to false.
    * `:user` — The user to run the command as. Unset by default, meaning the
      command runs as whoever is running the VM. Requires the server to be
      started with `root: true` and this name in its `limit_users`.
    * `:capabilities` — Capabilities to grant the command, or `:all`. Unset by default.
    * `:link` — Whether to link the command process to the calling process. Defaults to true.
    * `:kill_group` — Whether to kill the entire process group when stopping the command. Defaults to true.

  `:root` and `:limit_users` are not accepted here and are dropped if passed.
  They configure the `exec` server rather than a command, and are read from the
  application environment when `:erlexec` boots:

      config :erlexec, root: true, user: "app", limit_users: ["app"]

  These reserved options are set conservatively so commands run with the least privilege necessary
  and are less likely to affect the system or other processes unexpectedly.

  They are not a security boundary. To prevent commands from running with elevated privileges,
  run the application as a non-root user and ensure that user has only the permissions the
  application requires.

  System security, OS users, and permission configuration must be enforced outside this library.

  ## Examples

      iex> Exec.Core.run("echo hello", [:sync, :stdout])
      {:ok, [stdout: ["hello\n"]]}

      iex> Exec.Core.run("printf 'hello world'", [:sync, :stdout])
      {:ok, [stdout: ["hello world"]]}
  """
  @spec run(binary() | [binary()], Keyword.t()) :: term()
  def run(command, opts \\ []) do
    :exec.run(command, build_run_options(opts))
  end

  @doc """
  Send data to the stdin of a running process.

  ## Examples

      iex> {:ok, pid} = :exec.run("cat", [:sync, :stdin])
      ...> Exec.Core.send(pid, "hello\n")
      {:ok, :sent}
  """
  @spec send(integer() | pid(), iodata()) :: term()
  def send(os_pid, data), do: :exec.send(os_pid, data)

  @doc """
  Stop a running process by sending the default termination sequence.

  ## Examples

      iex> {:ok, pid} = :exec.run("sleep 30", [:sync])
      ...> Exec.Core.stop(pid)
      {:ok, :stopped}
  """
  @spec stop(integer() | pid() | port()) :: term()
  def stop(os_pid), do: :exec.stop(os_pid)

  @doc """
  Send a signal to a running process.

  ## Examples

      iex> {:ok, pid} = :exec.run("sleep 30", [:sync])
      ...> Exec.Core.kill(pid, :sigterm)
      {:ok, :killed}
  """
  @spec kill(integer() | pid() | port(), atom() | integer()) :: term()
  def kill(os_pid, signal), do: :exec.kill(os_pid, signal)

  # Based on the erlexec documentation in deps/erlexec/src/exec.erl and
  # https://hexdocs.pm/erlexec/exec.html. These settings change whether a child
  # process can run as root, under a specific user, with extra capabilities, or
  # as part of a linked process group. Enabling them broadens the child's power
  # and increases the risk of privilege escalation or unintended process control,
  # so the least-privileged defaults here are intentionally conservative.
  #
  # The option `:executable` is intentionally omitted.
  defp build_run_options(opts) do
    opts = Keyword.drop(opts, @server_options)

    stdin? = Keyword.get(opts, :stdin, true)
    stdout? = Keyword.get(opts, :stdout, true)
    stderr? = Keyword.get(opts, :stderr, true)

    debug? = Keyword.get(opts, :debug, false)
    sync? = Keyword.get(opts, :sync, false)
    monitor? = Keyword.get(opts, :monitor, true)

    cd = Keyword.get(opts, :cd)
    success_exit_code = Keyword.get(opts, :success_exit_code)
    winsz = Keyword.get(opts, :winsz)
    pty = Keyword.get(opts, :pty)
    pty_echo = Keyword.get(opts, :pty_echo)
    env = Keyword.get(opts, :env, [])

    # Sets the Linux scheduling priority (nice value) for the command.
    # Defaults to 0 (normal priority). Negative values increase priority,
    # positive values decrease it.
    nice = Keyword.get(opts, :nice, 0)

    kill = opts[:kill] || @default_kill_command
    kill_timeout = to_nearest_second(opts[:kill_timeout] || :timer.seconds(5))

    # `:user` and `:capabilities` are command options erlexec validates itself:
    # it rejects a user outside the server's configured `limit_users`, and
    # prohibits "root" outright. The check below is kept anyway so the refusal
    # names the reason here, at the call, rather than as a port error.
    user = Keyword.get(opts, :user)
    capabilities = Keyword.get(opts, :capabilities)

    if is_binary(user) and String.downcase(String.trim(user)) === "root" do
      raise "Running commands as root is not allowed. Use a non-root user."
    end

    proplist = []

    proplist = if stdin?, do: [:stdin | proplist], else: proplist
    proplist = if stdout?, do: [:stdout | proplist], else: proplist
    proplist = if stderr?, do: [:stderr | proplist], else: proplist
    proplist = if sync?, do: [:sync | proplist], else: proplist
    proplist = if monitor?, do: [:monitor | proplist], else: proplist
    proplist = if debug?, do: [:debug | proplist], else: proplist

    # :link is what makes erlexec reap the program when this process dies; see
    # the module comment above.
    proplist = proplist ++ [:link]

    # {:group, 0} puts the program in a new process group of its own.
    proplist = proplist ++ [{:group, 0}]

    # :kill_group makes erlexec signal the whole process group rather than the
    # single pid it tracked.
    proplist = proplist ++ [:kill_group]

    other = []

    # Impersonating a user needs the server started with `root: true` and the
    # name present in its `limit_users`; erlexec throws
    # "User <name> is not allowed to run commands!" otherwise.
    other =
      if user !== nil do
        Keyword.put(other, :user, user)
      else
        other
      end

    other =
      if capabilities !== nil do
        Keyword.put(other, :capabilities, capabilities)
      else
        other
      end

    other =
      if cd !== nil do
        Keyword.put(other, :cd, cd)
      else
        other
      end

    other =
      if success_exit_code !== nil do
        Keyword.put(other, :success_exit_code, success_exit_code)
      else
        other
      end

    other =
      if winsz !== nil do
        Keyword.put(other, :winsz, winsz)
      else
        other
      end

    other =
      if pty !== nil do
        Keyword.put(other, :pty, pty)
      else
        other
      end

    other =
      if pty_echo !== nil do
        Keyword.put(other, :pty_echo, pty_echo)
      else
        other
      end

    other =
      other
      |> Keyword.put(:env, env)
      |> Keyword.put(:kill, kill)
      |> Keyword.put(:kill_timeout, kill_timeout)
      |> Keyword.put(:nice, nice)

    proplist ++ other
  end

  defp to_nearest_second(ms) when is_integer(ms) and ms >= 0 do
    round(ms / 1000)
  end
end
