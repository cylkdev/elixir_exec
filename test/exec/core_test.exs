defmodule Exec.CoreTest do
  use ExUnit.Case, async: true

  alias Exec.Core

  # `Core.run/2` always sets `:link`, which is what makes erlexec reap the
  # program when its caller dies. That also means the program's exit reaches
  # the caller as an exit signal, so a direct caller has to trap exits the way
  # `Exec.Program` does. Callers who would rather not are the audience for
  # `Exec.run/2`.
  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # erlexec splits its options in two: server options, read from the `:erlexec`
  # application environment when it boots, and command options, validated per
  # run. `Core` used to read `:user`/`:limit_users` with `compile_env` and
  # append `root:` and `limit_users:` to every command, so configuring a user
  # made every call fail with `{:invalid_option, :root}`. These pin the split.

  describe "run/2 and server-only options" do
    test ":root is dropped rather than forwarded to the command" do
      assert {:ok, _} = Core.run(["/bin/sh", "-c", "exit 0"], sync: true, root: true)
    end

    test ":limit_users is dropped rather than forwarded to the command" do
      assert {:ok, _} = Core.run(["/bin/sh", "-c", "exit 0"], sync: true, limit_users: ["nobody"])
    end

    test "both together still run the command" do
      assert {:ok, _} =
               Core.run(["/bin/sh", "-c", "exit 0"],
                 sync: true,
                 root: true,
                 limit_users: ["nobody"]
               )
    end
  end

  describe "run/2 and :user" do
    test "refuses root by name" do
      assert_raise RuntimeError, ~r/root is not allowed/, fn ->
        Core.run(["/bin/sh", "-c", "exit 0"], sync: true, user: "root")
      end
    end

    test "refuses root regardless of case or surrounding space" do
      assert_raise RuntimeError, ~r/root is not allowed/, fn ->
        Core.run(["/bin/sh", "-c", "exit 0"], sync: true, user: " ROOT ")
      end
    end

    test "a nil user is treated as unset rather than passed through" do
      assert {:ok, _} = Core.run(["/bin/sh", "-c", "exit 0"], sync: true, user: nil)
    end

    test "an unknown user reaches erlexec rather than being silently ignored" do
      # Nothing configures the server's `limit_users`, so no impersonation is
      # permitted and erlexec refuses the name. The point is that it arrives.
      assert {:error, _} =
               Core.run(["/bin/sh", "-c", "exit 0"], sync: true, user: "definitely_not_a_user")
    end
  end
end
