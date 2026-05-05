defmodule ElixirExec.Options do
  @moduledoc false

  # Internal option schemas and Elixir -> Erlang translation for `:erlexec`.
  #
  # Two stages happen here:
  #
  #   1. `validate_command/1` and `validate_exec/1` run a NimbleOptions
  #      schema against the caller-supplied keyword list, then layer
  #      illegal-combination checks on top. They return the validated
  #      keyword list unchanged on success.
  #
  #   2. `to_erl_command_options/1` and `to_erl_exec_options/1` translate
  #      a validated keyword list into the proplist `:erlexec` expects,
  #      converting binaries to charlists, dropping boolean flags that
  #      are `false`, renaming a few keys, and so on.
  #
  # The two stages are intentionally separate: callers compose them, and
  # tests can exercise each translation in isolation.

  # ----------------------------------------------------------------------
  # Schemas
  # ----------------------------------------------------------------------

  @command_schema [
    monitor: [type: :boolean],
    sync: [type: :boolean],
    executable: [type: :string],
    cd: [type: :string],
    env: [type: {:map, :string, :string}],
    kill_command: [type: :string],
    kill_timeout: [type: :non_neg_integer],
    kill_group: [type: :boolean],
    group: [type: :string],
    user: [type: :string],
    success_exit_code: [type: :non_neg_integer],
    nice: [type: {:in, -20..20}],
    stdin: [
      type: {:or, [:boolean, {:in, [:null, :close]}, :string]}
    ],
    stdout: [type: {:custom, __MODULE__, :validate_output_device, [:stdout]}],
    stderr: [type: {:custom, __MODULE__, :validate_output_device, [:stderr]}],
    pty: [type: {:or, [:boolean, :keyword_list]}],
    pty_echo: [type: :boolean],
    winsz: [type: {:tuple, [:pos_integer, :pos_integer]}],
    capabilities: [type: {:or, [{:in, [:all]}, {:list, :atom}]}],
    debug: [type: {:or, [:boolean, :non_neg_integer]}]
  ]

  @exec_schema [
    debug: [type: {:or, [:boolean, :non_neg_integer]}],
    root: [type: :boolean],
    verbose: [type: :boolean],
    args: [type: {:list, :string}],
    alarm: [type: :non_neg_integer],
    user: [type: :string],
    limit_users: [type: {:list, :string}],
    port_path: [type: :string],
    env: [type: {:map, :string, :string}],
    capabilities: [type: {:or, [{:in, [:all]}, {:list, :atom}]}]
  ]

  @command_nimble NimbleOptions.new!(@command_schema)
  @exec_nimble NimbleOptions.new!(@exec_schema)

  # ----------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------

  @spec validate_command(keyword) ::
          {:ok, keyword}
          | {:error, NimbleOptions.ValidationError.t() | {:illegal_combination, atom}}
  def validate_command(opts) when is_list(opts) do
    with {:ok, validated} <- NimbleOptions.validate(opts, @command_nimble),
         :ok <- check_illegal_combinations(validated) do
      {:ok, validated}
    end
  end

  @spec validate_exec(keyword) ::
          {:ok, keyword} | {:error, NimbleOptions.ValidationError.t()}
  def validate_exec(opts) when is_list(opts) do
    NimbleOptions.validate(opts, @exec_nimble)
  end

  @spec to_erl_command(String.t() | [String.t()]) :: charlist | [charlist]
  # String form: shell parses the line, so the shell handles PATH lookup.
  def to_erl_command(command) when is_binary(command), do: to_charlist(command)

  # Pass-through shapes: an absolute, CWD-relative, or parent-relative head
  # is what the caller asked for verbatim -- no PATH lookup.
  def to_erl_command(["/" <> _ | _] = command), do: Enum.map(command, &to_charlist/1)
  def to_erl_command(["./" <> _ | _] = command), do: Enum.map(command, &to_charlist/1)
  def to_erl_command(["../" <> _ | _] = command), do: Enum.map(command, &to_charlist/1)

  # Bare-name head: erlexec calls execve directly, which does not search
  # PATH. Resolve via System.find_executable/1 so list-form callers see
  # the same lookup behaviour as the string form. Falls back to the
  # original head when resolution fails so the caller still sees ENOENT
  # rather than a silent rewrite.
  def to_erl_command([exe | args]) when is_binary(exe) do
    resolved = System.find_executable(exe) || exe
    Enum.map([resolved | args], &to_charlist/1)
  end

  # Empty list (and any other list shape) -- map straight through.
  def to_erl_command(command) when is_list(command) do
    Enum.map(command, &to_charlist/1)
  end

  @spec to_erl_command_options(keyword) :: list
  def to_erl_command_options(opts) when is_list(opts) do
    Enum.flat_map(opts, &command_option_to_erl/1)
  end

  @spec to_erl_exec_options(keyword) :: list
  def to_erl_exec_options(opts) when is_list(opts) do
    Enum.flat_map(opts, &exec_option_to_erl/1)
  end

  # ----------------------------------------------------------------------
  # NimbleOptions custom validator for stdout/stderr shapes.
  # Public only so NimbleOptions can resolve it; not part of the contract.
  # ----------------------------------------------------------------------

  @doc false
  @spec validate_output_device(term, :stdout | :stderr) :: {:ok, term} | {:error, String.t()}
  def validate_output_device(value, device) when device in [:stdout, :stderr] do
    if valid_output_device?(value, device) do
      {:ok, value}
    else
      {:error,
       "invalid #{inspect(device)} value: #{inspect(value)}. " <>
         "Expected one of: true, false, :null, :close, :print, " <>
         "#{cross_atom_for(device)}, :stream (stdout only), " <>
         "a path string, {path, file_opts}, a pid, or a 3-arity function."}
    end
  end

  # ----------------------------------------------------------------------
  # Output device shape predicate
  # ----------------------------------------------------------------------

  defp valid_output_device?(true, _), do: true
  defp valid_output_device?(false, _), do: true
  defp valid_output_device?(:null, _), do: true
  defp valid_output_device?(:close, _), do: true
  defp valid_output_device?(:print, _), do: true
  defp valid_output_device?(:stream, :stdout), do: true
  defp valid_output_device?(:stderr, :stdout), do: true
  defp valid_output_device?(:stdout, :stderr), do: true
  defp valid_output_device?(value, _) when is_binary(value), do: true
  defp valid_output_device?(value, _) when is_pid(value), do: true
  defp valid_output_device?(value, _) when is_function(value, 3), do: true

  defp valid_output_device?({path, file_opts}, _)
       when is_binary(path) and is_list(file_opts) do
    Enum.all?(file_opts, &valid_file_opt?/1)
  end

  defp valid_output_device?(_, _), do: false

  defp valid_file_opt?({:append, value}) when is_boolean(value), do: true
  defp valid_file_opt?({:mode, value}) when is_integer(value) and value >= 0, do: true
  defp valid_file_opt?(_), do: false

  defp cross_atom_for(:stdout), do: ":stderr"
  defp cross_atom_for(:stderr), do: ":stdout"

  # ----------------------------------------------------------------------
  # Illegal combination checks
  # ----------------------------------------------------------------------

  defp check_illegal_combinations(opts) do
    if Keyword.get(opts, :sync) === true and Keyword.get(opts, :stdout) === :stream do
      {:error, {:illegal_combination, :sync_with_stream}}
    else
      :ok
    end
  end

  # ----------------------------------------------------------------------
  # Command option translation
  # ----------------------------------------------------------------------

  # Bare-atom flags: emit the atom only when true; drop entirely when false.
  defp command_option_to_erl({:monitor, true}), do: [:monitor]
  defp command_option_to_erl({:monitor, false}), do: []
  defp command_option_to_erl({:sync, true}), do: [:sync]
  defp command_option_to_erl({:sync, false}), do: []
  defp command_option_to_erl({:kill_group, true}), do: [:kill_group]
  defp command_option_to_erl({:kill_group, false}), do: []
  defp command_option_to_erl({:pty_echo, true}), do: [:pty_echo]
  defp command_option_to_erl({:pty_echo, false}), do: []

  # String options that pass straight through under the same key.
  defp command_option_to_erl({:executable, value}), do: [{:executable, to_charlist(value)}]
  defp command_option_to_erl({:cd, value}), do: [{:cd, to_charlist(value)}]
  defp command_option_to_erl({:group, value}), do: [{:group, to_charlist(value)}]
  defp command_option_to_erl({:user, value}), do: [{:user, to_charlist(value)}]

  # Renamed: kill_command -> :kill in the erlexec proplist.
  defp command_option_to_erl({:kill_command, value}), do: [{:kill, to_charlist(value)}]

  # Integer options pass through as-is.
  defp command_option_to_erl({:kill_timeout, value}), do: [{:kill_timeout, value}]
  defp command_option_to_erl({:success_exit_code, value}), do: [{:success_exit_code, value}]
  defp command_option_to_erl({:nice, value}), do: [{:nice, value}]

  # Env: map -> charlist proplist.
  defp command_option_to_erl({:env, value}), do: [{:env, env_to_erl(value)}]

  # Stdin: each shape is its own form.
  defp command_option_to_erl({:stdin, true}), do: [:stdin]
  defp command_option_to_erl({:stdin, false}), do: []
  defp command_option_to_erl({:stdin, :null}), do: [{:stdin, :null}]
  defp command_option_to_erl({:stdin, :close}), do: [{:stdin, :close}]

  defp command_option_to_erl({:stdin, value}) when is_binary(value) do
    [{:stdin, to_charlist(value)}]
  end

  # Stdout / stderr: full output device decoder.
  defp command_option_to_erl({:stdout, value}), do: output_device_to_erl(:stdout, value)
  defp command_option_to_erl({:stderr, value}), do: output_device_to_erl(:stderr, value)

  # Pty: bare atom when true, {:pty, opts} when keyword list, drop when false.
  defp command_option_to_erl({:pty, true}), do: [:pty]
  defp command_option_to_erl({:pty, false}), do: []
  defp command_option_to_erl({:pty, opts}) when is_list(opts), do: [{:pty, opts}]

  # Winsz: pass the {rows, cols} tuple through.
  defp command_option_to_erl({:winsz, {_rows, _cols} = value}), do: [{:winsz, value}]

  # Capabilities: either :all or a list of atoms — unchanged.
  defp command_option_to_erl({:capabilities, value}), do: [{:capabilities, value}]

  # Debug: boolean -> bare atom; integer -> {:debug, n}; false dropped.
  defp command_option_to_erl({:debug, true}), do: [:debug]
  defp command_option_to_erl({:debug, false}), do: []
  defp command_option_to_erl({:debug, value}) when is_integer(value), do: [{:debug, value}]

  # ----------------------------------------------------------------------
  # Output device translation (stdout / stderr)
  # ----------------------------------------------------------------------

  defp output_device_to_erl(device, true), do: [device]
  defp output_device_to_erl(_device, false), do: []
  defp output_device_to_erl(device, :null), do: [{device, :null}]
  defp output_device_to_erl(device, :close), do: [{device, :close}]
  defp output_device_to_erl(device, :print), do: [{device, :print}]
  defp output_device_to_erl(:stdout, :stream), do: [{:stdout, :stream}]
  defp output_device_to_erl(:stdout, :stderr), do: [{:stdout, :stderr}]
  defp output_device_to_erl(:stderr, :stdout), do: [{:stderr, :stdout}]

  defp output_device_to_erl(device, value) when is_binary(value) do
    [{device, to_charlist(value)}]
  end

  defp output_device_to_erl(device, value) when is_pid(value), do: [{device, value}]

  defp output_device_to_erl(device, value) when is_function(value, 3) do
    [{device, value}]
  end

  defp output_device_to_erl(device, {path, file_opts})
       when is_binary(path) and is_list(file_opts) do
    [{device, to_charlist(path), file_opts_to_erl(file_opts)}]
  end

  defp file_opts_to_erl(file_opts) do
    Enum.flat_map(file_opts, fn
      {:append, true} -> [:append]
      {:append, false} -> []
      {:mode, mode} -> [{:mode, mode}]
    end)
  end

  # ----------------------------------------------------------------------
  # Exec start option translation
  # ----------------------------------------------------------------------

  defp exec_option_to_erl({:debug, true}), do: [:debug]
  defp exec_option_to_erl({:debug, false}), do: []
  defp exec_option_to_erl({:debug, value}) when is_integer(value), do: [{:debug, value}]
  defp exec_option_to_erl({:root, value}), do: [{:root, value}]
  defp exec_option_to_erl({:verbose, true}), do: [:verbose]
  defp exec_option_to_erl({:verbose, false}), do: []
  defp exec_option_to_erl({:alarm, value}), do: [{:alarm, value}]
  defp exec_option_to_erl({:user, value}), do: [{:user, to_charlist(value)}]

  defp exec_option_to_erl({:args, value}) do
    [{:args, Enum.map(value, &to_charlist/1)}]
  end

  defp exec_option_to_erl({:limit_users, value}) do
    [{:limit_users, Enum.map(value, &to_charlist/1)}]
  end

  defp exec_option_to_erl({:port_path, value}), do: [{:portexe, to_charlist(value)}]
  defp exec_option_to_erl({:env, value}), do: [{:env, env_to_erl(value)}]
  defp exec_option_to_erl({:capabilities, value}), do: [{:capabilities, value}]

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  defp env_to_erl(map) when is_map(map) do
    for {key, value} <- map, do: {to_charlist(key), to_charlist(value)}
  end
end
