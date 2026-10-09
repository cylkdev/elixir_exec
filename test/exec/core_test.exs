defmodule Exec.CoreTest do
  use ExUnit.Case, async: true

  alias Exec.Core

  # `Core.run/2` links the program to its caller, so the program's exit reaches
  # the caller as an exit signal; these tests trap exits the way `Exec.Program`
  # does.
  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "run/2" do
    test "runs the command and returns its output" do
      assert {:ok, [stdout: ["hi\n"]]} = Core.run(["/bin/sh", "-c", "echo hi"], sync: true)
    end

    test "runs the command when given the server's :root and :limit_users options" do
      assert {:ok, []} =
               Core.run(["/bin/sh", "-c", "exit 0"],
                 sync: true,
                 root: true,
                 limit_users: ["nobody"]
               )
    end

    test "raises for the user root, in any case and with surrounding space" do
      assert_raise RuntimeError,
                   ~s(Exec runs commands as a non-root user, and was given "root".),
                   fn -> Core.run(["/bin/sh", "-c", "exit 0"], sync: true, user: "root") end

      assert_raise RuntimeError,
                   ~s(Exec runs commands as a non-root user, and was given " ROOT ".),
                   fn -> Core.run(["/bin/sh", "-c", "exit 0"], sync: true, user: " ROOT ") end
    end

    test "returns erlexec's answer for a user outside the server's :limit_users" do
      assert {:error, ~c"User definitely_not_a_user is not allowed to run commands!"} =
               Core.run(["/bin/sh", "-c", "exit 0"], sync: true, user: "definitely_not_a_user")
    end
  end
end
