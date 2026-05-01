defmodule ElixirExec.OutputTest do
  use ExUnit.Case, async: true

  alias ElixirExec.Output

  doctest ElixirExec.Output

  describe "struct defaults" do
    test "stdout and stderr default to empty lists" do
      assert %Output{} === %Output{stdout: [], stderr: []}
      assert %Output{}.stdout === []
      assert %Output{}.stderr === []
    end
  end

  describe "from_proplist/1" do
    test "empty proplist yields empty stdout and stderr" do
      assert Output.from_proplist([]) === %Output{stdout: [], stderr: []}
    end

    test "stdout-only proplist preserves stdout and defaults stderr" do
      assert Output.from_proplist(stdout: ["hi\n"]) === %Output{
               stdout: ["hi\n"],
               stderr: []
             }
    end

    test "stderr-only proplist preserves stderr and defaults stdout" do
      assert Output.from_proplist(stderr: ["err\n"]) === %Output{
               stdout: [],
               stderr: ["err\n"]
             }
    end

    test "both keys present preserves both lists" do
      assert Output.from_proplist(stdout: ["a\n", "b\n"], stderr: ["c\n"]) ===
               %Output{stdout: ["a\n", "b\n"], stderr: ["c\n"]}
    end

    test "key order in the proplist does not matter" do
      stderr_first = Output.from_proplist(stderr: ["c\n"], stdout: ["a\n", "b\n"])
      stdout_first = Output.from_proplist(stdout: ["a\n", "b\n"], stderr: ["c\n"])

      assert stderr_first === stdout_first
      assert stderr_first === %Output{stdout: ["a\n", "b\n"], stderr: ["c\n"]}
    end
  end
end
