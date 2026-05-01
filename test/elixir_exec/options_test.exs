defmodule ElixirExec.OptionsTest do
  use ExUnit.Case, async: true

  alias ElixirExec.Options

  # ----------------------------------------------------------------------
  # to_erl_command/1
  # ----------------------------------------------------------------------

  describe "to_erl_command/1" do
    test "converts a binary command to a charlist" do
      assert Options.to_erl_command("echo hi") === ~c"echo hi"
    end

    test "converts a list of binaries to a list of charlists" do
      assert Options.to_erl_command(["bash", "-c", "ls"]) ===
               [~c"bash", ~c"-c", ~c"ls"]
    end

    test "preserves an empty list" do
      assert Options.to_erl_command([]) === []
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — boolean flags
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 boolean flags" do
    test "monitor: true emits the bare :monitor atom" do
      assert Options.to_erl_command_options(monitor: true) === [:monitor]
    end

    test "monitor: false omits :monitor entirely" do
      assert Options.to_erl_command_options(monitor: false) === []
    end

    test "sync: true emits the bare :sync atom" do
      assert Options.to_erl_command_options(sync: true) === [:sync]
    end

    test "sync: false omits :sync" do
      assert Options.to_erl_command_options(sync: false) === []
    end

    test "kill_group: true emits :kill_group" do
      assert Options.to_erl_command_options(kill_group: true) === [:kill_group]
    end

    test "kill_group: false omits :kill_group" do
      assert Options.to_erl_command_options(kill_group: false) === []
    end

    test "pty_echo: true emits :pty_echo" do
      assert Options.to_erl_command_options(pty_echo: true) === [:pty_echo]
    end

    test "pty_echo: false omits :pty_echo" do
      assert Options.to_erl_command_options(pty_echo: false) === []
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — string options become charlists
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 string options" do
    test "executable string converts to charlist" do
      assert Options.to_erl_command_options(executable: "/bin/sh") ===
               [{:executable, ~c"/bin/sh"}]
    end

    test "cd string converts to charlist" do
      assert Options.to_erl_command_options(cd: "/tmp") === [{:cd, ~c"/tmp"}]
    end

    test "kill_command renames to :kill and converts to charlist" do
      assert Options.to_erl_command_options(kill_command: "kill -9") ===
               [{:kill, ~c"kill -9"}]
    end

    test "group string converts to charlist" do
      assert Options.to_erl_command_options(group: "wheel") ===
               [{:group, ~c"wheel"}]
    end

    test "user string converts to charlist" do
      assert Options.to_erl_command_options(user: "nobody") ===
               [{:user, ~c"nobody"}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — integer options
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 integer options" do
    test "kill_timeout passed through" do
      assert Options.to_erl_command_options(kill_timeout: 5) ===
               [{:kill_timeout, 5}]
    end

    test "success_exit_code passed through" do
      assert Options.to_erl_command_options(success_exit_code: 0) ===
               [{:success_exit_code, 0}]
    end

    test "nice passed through" do
      assert Options.to_erl_command_options(nice: 10) === [{:nice, 10}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — env map
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 env map" do
    test "env map round-trips to charlist proplist" do
      assert [{:env, env}] =
               Options.to_erl_command_options(env: %{"FOO" => "bar", "BAZ" => "qux"})

      assert Enum.sort(env) ===
               Enum.sort([{~c"FOO", ~c"bar"}, {~c"BAZ", ~c"qux"}])
    end

    test "empty env produces empty proplist" do
      assert Options.to_erl_command_options(env: %{}) === [{:env, []}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — stdin
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 stdin" do
    test "stdin: true emits bare :stdin" do
      assert Options.to_erl_command_options(stdin: true) === [:stdin]
    end

    test "stdin: false omits :stdin" do
      assert Options.to_erl_command_options(stdin: false) === []
    end

    test "stdin: :null emits {:stdin, :null}" do
      assert Options.to_erl_command_options(stdin: :null) ===
               [{:stdin, :null}]
    end

    test "stdin: :close emits {:stdin, :close}" do
      assert Options.to_erl_command_options(stdin: :close) ===
               [{:stdin, :close}]
    end

    test "stdin: path string emits {:stdin, charlist}" do
      assert Options.to_erl_command_options(stdin: "/tmp/in") ===
               [{:stdin, ~c"/tmp/in"}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — stdout / stderr output devices
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 stdout" do
    test "stdout: true emits bare :stdout" do
      assert Options.to_erl_command_options(stdout: true) === [:stdout]
    end

    test "stdout: false omits :stdout" do
      assert Options.to_erl_command_options(stdout: false) === []
    end

    test "stdout: :null emits {:stdout, :null}" do
      assert Options.to_erl_command_options(stdout: :null) ===
               [{:stdout, :null}]
    end

    test "stdout: :close emits {:stdout, :close}" do
      assert Options.to_erl_command_options(stdout: :close) ===
               [{:stdout, :close}]
    end

    test "stdout: :print emits {:stdout, :print}" do
      assert Options.to_erl_command_options(stdout: :print) ===
               [{:stdout, :print}]
    end

    test "stdout: :stream is passed through unchanged" do
      assert Options.to_erl_command_options(stdout: :stream) ===
               [{:stdout, :stream}]
    end

    test "stdout: :stderr merges stdout into stderr" do
      assert Options.to_erl_command_options(stdout: :stderr) ===
               [{:stdout, :stderr}]
    end

    test "stdout path string converts to charlist" do
      assert Options.to_erl_command_options(stdout: "/tmp/out.log") ===
               [{:stdout, ~c"/tmp/out.log"}]
    end

    test "stdout {path, [append: true, mode: 0o644]} expands to triple" do
      assert Options.to_erl_command_options(stdout: {"/tmp/out.log", [append: true, mode: 0o644]}) ===
               [{:stdout, ~c"/tmp/out.log", [:append, {:mode, 0o644}]}]
    end

    test "stdout {path, [append: false, mode: 0o600]} drops append: false" do
      assert Options.to_erl_command_options(
               stdout: {"/tmp/out.log", [append: false, mode: 0o600]}
             ) ===
               [{:stdout, ~c"/tmp/out.log", [{:mode, 0o600}]}]
    end

    test "stdout pid is passed through" do
      pid = self()
      assert Options.to_erl_command_options(stdout: pid) === [{:stdout, pid}]
    end

    test "stdout 3-arity function is passed through" do
      fun = fn _device, _os_pid, _data -> :ok end
      assert Options.to_erl_command_options(stdout: fun) === [{:stdout, fun}]
    end
  end

  describe "to_erl_command_options/1 stderr" do
    test "stderr: true emits bare :stderr" do
      assert Options.to_erl_command_options(stderr: true) === [:stderr]
    end

    test "stderr: false omits :stderr" do
      assert Options.to_erl_command_options(stderr: false) === []
    end

    test "stderr: :null emits {:stderr, :null}" do
      assert Options.to_erl_command_options(stderr: :null) ===
               [{:stderr, :null}]
    end

    test "stderr: :stdout cross-merges into stdout" do
      assert Options.to_erl_command_options(stderr: :stdout) ===
               [{:stderr, :stdout}]
    end

    test "stderr path string converts to charlist" do
      assert Options.to_erl_command_options(stderr: "/tmp/err.log") ===
               [{:stderr, ~c"/tmp/err.log"}]
    end

    test "stderr {path, [append: true]} expands to triple" do
      assert Options.to_erl_command_options(stderr: {"/tmp/err.log", [append: true]}) ===
               [{:stderr, ~c"/tmp/err.log", [:append]}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — pty
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 pty" do
    test "pty: true emits bare :pty" do
      assert Options.to_erl_command_options(pty: true) === [:pty]
    end

    test "pty: false omits :pty" do
      assert Options.to_erl_command_options(pty: false) === []
    end

    test "pty with keyword list emits {:pty, opts}" do
      opts = [echo: true]
      assert Options.to_erl_command_options(pty: opts) === [{:pty, opts}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — winsz
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 winsz" do
    test "winsz tuple is passed through" do
      assert Options.to_erl_command_options(winsz: {24, 80}) ===
               [{:winsz, {24, 80}}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — capabilities
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 capabilities" do
    test "capabilities: :all is passed through" do
      assert Options.to_erl_command_options(capabilities: :all) ===
               [{:capabilities, :all}]
    end

    test "capabilities list of atoms is passed through" do
      assert Options.to_erl_command_options(capabilities: [:cap_chown, :cap_kill]) ===
               [{:capabilities, [:cap_chown, :cap_kill]}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — debug
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 debug" do
    test "debug: true emits :debug" do
      assert Options.to_erl_command_options(debug: true) === [:debug]
    end

    test "debug: false omits :debug" do
      assert Options.to_erl_command_options(debug: false) === []
    end

    test "debug: integer emits {:debug, n}" do
      assert Options.to_erl_command_options(debug: 3) === [{:debug, 3}]
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_command_options/1 — composition
  # ----------------------------------------------------------------------

  describe "to_erl_command_options/1 composition" do
    test "preserves ordering and combines multiple options" do
      result =
        Options.to_erl_command_options(
          monitor: true,
          cd: "/tmp",
          kill_timeout: 3
        )

      assert result === [:monitor, {:cd, ~c"/tmp"}, {:kill_timeout, 3}]
    end

    test "empty option list yields empty proplist" do
      assert Options.to_erl_command_options([]) === []
    end
  end

  # ----------------------------------------------------------------------
  # to_erl_exec_options/1
  # ----------------------------------------------------------------------

  describe "to_erl_exec_options/1" do
    test "debug: true emits :debug" do
      assert Options.to_erl_exec_options(debug: true) === [:debug]
    end

    test "debug: false omits :debug" do
      assert Options.to_erl_exec_options(debug: false) === []
    end

    test "debug: integer emits {:debug, n}" do
      assert Options.to_erl_exec_options(debug: 4) === [{:debug, 4}]
    end

    test "root: boolean is passed through" do
      assert Options.to_erl_exec_options(root: true) === [{:root, true}]
      assert Options.to_erl_exec_options(root: false) === [{:root, false}]
    end

    test "verbose: true emits bare :verbose" do
      assert Options.to_erl_exec_options(verbose: true) === [:verbose]
    end

    test "verbose: false omits :verbose" do
      assert Options.to_erl_exec_options(verbose: false) === []
    end

    test "args list of binaries converts to list of charlists" do
      assert Options.to_erl_exec_options(args: ["--foo", "bar"]) ===
               [{:args, [~c"--foo", ~c"bar"]}]
    end

    test "alarm passed through" do
      assert Options.to_erl_exec_options(alarm: 30) === [{:alarm, 30}]
    end

    test "user converts to charlist" do
      assert Options.to_erl_exec_options(user: "root") ===
               [{:user, ~c"root"}]
    end

    test "limit_users converts each entry to a charlist" do
      assert Options.to_erl_exec_options(limit_users: ["alice", "bob"]) ===
               [{:limit_users, [~c"alice", ~c"bob"]}]
    end

    test "port_path renames to :portexe and converts to charlist" do
      assert Options.to_erl_exec_options(port_path: "/usr/local/bin/exec-port") ===
               [{:portexe, ~c"/usr/local/bin/exec-port"}]
    end

    test "env map converts to charlist proplist" do
      assert [{:env, env}] = Options.to_erl_exec_options(env: %{"FOO" => "bar"})
      assert env === [{~c"FOO", ~c"bar"}]
    end

    test "capabilities: :all is passed through" do
      assert Options.to_erl_exec_options(capabilities: :all) ===
               [{:capabilities, :all}]
    end

    test "capabilities list of atoms is passed through" do
      assert Options.to_erl_exec_options(capabilities: [:cap_net_admin]) ===
               [{:capabilities, [:cap_net_admin]}]
    end

    test "empty option list yields empty proplist" do
      assert Options.to_erl_exec_options([]) === []
    end
  end

  # ----------------------------------------------------------------------
  # validate_command/1
  # ----------------------------------------------------------------------

  describe "validate_command/1" do
    test "returns {:ok, opts} for valid options" do
      opts = [monitor: true, cd: "/tmp", env: %{"FOO" => "bar"}]
      assert {:ok, ^opts} = Options.validate_command(opts)
    end

    test "returns {:ok, []} for empty options" do
      assert {:ok, []} = Options.validate_command([])
    end

    test "rejects unknown keys with NimbleOptions.ValidationError" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_command(bogus_key: 1)
    end

    test "rejects wrong type for monitor" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_command(monitor: "yes")
    end

    test "rejects nice values out of -20..20 range" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_command(nice: 21)

      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_command(nice: -21)
    end

    test "accepts valid nice values within -20..20" do
      assert {:ok, _} = Options.validate_command(nice: -20)
      assert {:ok, _} = Options.validate_command(nice: 0)
      assert {:ok, _} = Options.validate_command(nice: 20)
    end

    test "rejects sync: true with stdout: :stream" do
      assert {:error, {:illegal_combination, :sync_with_stream}} =
               Options.validate_command(sync: true, stdout: :stream)
    end

    test "allows sync: true with stdout: true" do
      assert {:ok, _} = Options.validate_command(sync: true, stdout: true)
    end

    test "allows sync: false with stdout: :stream" do
      assert {:ok, _} = Options.validate_command(sync: false, stdout: :stream)
    end

    test "rejects unknown stdout shape" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_command(stdout: :bogus)
    end

    test "accepts valid stdout shapes" do
      assert {:ok, _} = Options.validate_command(stdout: true)
      assert {:ok, _} = Options.validate_command(stdout: false)
      assert {:ok, _} = Options.validate_command(stdout: :null)
      assert {:ok, _} = Options.validate_command(stdout: :close)
      assert {:ok, _} = Options.validate_command(stdout: :print)
      assert {:ok, _} = Options.validate_command(stdout: :stream)
      assert {:ok, _} = Options.validate_command(stdout: :stderr)
      assert {:ok, _} = Options.validate_command(stdout: "/tmp/out")
      assert {:ok, _} = Options.validate_command(stdout: {"/tmp/out", [append: true]})
      assert {:ok, _} = Options.validate_command(stdout: self())
      assert {:ok, _} = Options.validate_command(stdout: fn _, _, _ -> :ok end)
    end

    test "stderr: :stream is rejected as an unknown shape" do
      # :stream is only valid for :stdout; stderr cannot be streamed via this option
      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_command(stderr: :stream)
    end
  end

  # ----------------------------------------------------------------------
  # validate_exec/1
  # ----------------------------------------------------------------------

  describe "validate_exec/1" do
    test "returns {:ok, opts} for valid options" do
      opts = [verbose: true, alarm: 5, user: "nobody"]
      assert {:ok, ^opts} = Options.validate_exec(opts)
    end

    test "returns {:ok, []} for empty options" do
      assert {:ok, []} = Options.validate_exec([])
    end

    test "rejects unknown keys with NimbleOptions.ValidationError" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_exec(bogus_key: 1)
    end

    test "rejects wrong type for alarm" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_exec(alarm: -1)
    end

    test "rejects wrong type for verbose" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               Options.validate_exec(verbose: "yes")
    end

    test "accepts capabilities as :all" do
      assert {:ok, _} = Options.validate_exec(capabilities: :all)
    end

    test "accepts capabilities as list of atoms" do
      assert {:ok, _} = Options.validate_exec(capabilities: [:cap_chown])
    end
  end
end
