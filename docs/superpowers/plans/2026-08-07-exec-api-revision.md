# Exec API Revision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `ElixirExec` to `Exec`, give its public functions idiomatic Elixir names, seal four abstraction leaks, and rewrite every doc in stdlib voice.

**Architecture:** The library is a thin wrapper over the `:erlexec` Hex package. `Exec` is a stateless façade; each running program is one `Exec.Program` GenServer started under a `DynamicSupervisor`. No process or supervision-tree changes are made by this plan — every task is a rename, a return-shape change, or documentation. Behaviour that is not explicitly listed as changing must not change.

**Tech Stack:** Elixir `~> 1.18`, ExUnit, `:erlexec ~> 2.3`, Credo (`blitz_credo_checks`), Dialyxir, ExCoveralls, ExDoc.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-07-exec-api-revision-design.md`. Read it before Task 1.
- The OTP application name and Hex package name stay `:elixir_exec`. Only Elixir module names change.
- The Mix task stays `mix elixir_exec.setup_user` (module `Mix.Tasks.ElixirExec.SetupUser`). Do not rename it.
- `mix format` must pass. Run `mix format` before every commit.
- `mix credo --strict` and `mix dialyzer` must pass at the end of every task.
- No `@doc` or `@moduledoc` may address the reader in the second person ("you", "your", "yours").
- Elixir uses `===` for strict equality in this codebase's tests. Match the existing style.
- Doctests are already enabled via `doctest ElixirExec` in the test file; it becomes `doctest Exec`.
- Commit after every task. Do not squash tasks into one commit.

---

## File Structure

| Path | Fate | Responsibility |
|---|---|---|
| `lib/elixir_exec.ex` | → `lib/exec.ex` | Public façade: `run/2`, `stream!/2`, `open/2`, `read/2`, `write/2`, `stop/1`, `signal/2`; command normalization; option validation |
| `lib/elixir_exec/connection.ex` | → `lib/exec/program.ex` | One GenServer per running program; owns `:exec.run`, the event queue, the owner monitor |
| `lib/elixir_exec/connection_supervisor.ex` | → `lib/exec/program_supervisor.ex` | DynamicSupervisor owning program processes |
| `lib/elixir_exec/output.ex` | → `lib/exec/result.ex` | `Exec.Result` struct — data only |
| `lib/elixir_exec/application.ex` | → `lib/exec/application.ex` | Starts the program supervisor |
| `lib/mix/tasks/elixir_exec.setup_user.ex` | unchanged path | Deploy-host tooling |
| `test/elixir_exec_test.exs` | → `test/exec_test.exs` | Whole-library test suite |
| `mix.exs` | modify | `mod:`, `docs: main:` |
| `README.md` | rewrite | Task 9 |
| `LICENSE` | create | Task 9 |

---

### Task 1: Rename every module from `ElixirExec` to `Exec`

Mechanical rename only. No function names, return shapes, or documentation wording change in this task. `Connection` → `Program` and `ConnectionSupervisor` → `ProgramSupervisor` happen here because they are part of the same mechanical sweep.

**Files:**
- Move: `lib/elixir_exec.ex` → `lib/exec.ex`
- Move: `lib/elixir_exec/connection.ex` → `lib/exec/program.ex`
- Move: `lib/elixir_exec/connection_supervisor.ex` → `lib/exec/program_supervisor.ex`
- Move: `lib/elixir_exec/output.ex` → `lib/exec/output.ex`
- Move: `lib/elixir_exec/application.ex` → `lib/exec/application.ex`
- Move: `test/elixir_exec_test.exs` → `test/exec_test.exs`
- Modify: `mix.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: modules `Exec`, `Exec.Program`, `Exec.ProgramSupervisor`, `Exec.Output`, `Exec.Application`. `Exec.ProgramSupervisor.start_program/3` replaces `ElixirExec.ConnectionSupervisor.start_supervised_connection/3`. Public function names are still `run/2` (handle), `capture/2`, `stream/2`, `read/2`, `write/2`, `stop/1`, `kill/2`.

**Naming note:** the DynamicSupervisor becomes `Exec.ProgramSupervisor`, *not* `Exec.Supervisor`. `ElixirExec.Supervisor` is already the registered name of the root supervisor in `application.ex:13`, and that root supervisor becomes `Exec.Supervisor`.

- [ ] **Step 1: Move the files with git so history follows**

```bash
git mv lib/elixir_exec.ex lib/exec.ex
git mv lib/elixir_exec lib/exec
git mv lib/exec/connection.ex lib/exec/program.ex
git mv lib/exec/connection_supervisor.ex lib/exec/program_supervisor.ex
git mv test/elixir_exec_test.exs test/exec_test.exs
```

- [ ] **Step 2: Rewrite the module names**

Apply these substitutions across `lib/**/*.ex`, `test/**/*.exs` and `mix.exs`. Order matters — the longest names must be replaced first, or `ElixirExec` will corrupt them.

```bash
FILES=$(git ls-files 'lib/*.ex' 'lib/**/*.ex' 'test/*.exs' mix.exs)
# Longest first.
sed -i '' \
  -e 's/ElixirExec\.ConnectionSupervisor/Exec.ProgramSupervisor/g' \
  -e 's/ElixirExec\.Connection/Exec.Program/g' \
  -e 's/start_supervised_connection/start_program/g' \
  -e 's/ElixirExec\.Application/Exec.Application/g' \
  -e 's/ElixirExec\.Supervisor/Exec.Supervisor/g' \
  -e 's/ElixirExec\.Output/Exec.Output/g' \
  -e 's/ElixirExecTest/ExecTest/g' \
  -e 's/ElixirExec\./Exec./g' \
  -e 's/\bElixirExec\b/Exec/g' \
  $FILES
```

Then hand-check the two places `sed` must NOT have touched:

- `mix.exs` must still read `app: :elixir_exec`. If the sweep changed it, restore it.
- `lib/mix/tasks/elixir_exec.setup_user.ex` is not in `$FILES` and must remain `Mix.Tasks.ElixirExec.SetupUser`. Confirm with `grep -n ElixirExec lib/mix/tasks/elixir_exec.setup_user.ex`.

- [ ] **Step 3: Fix the two aliases sed cannot handle**

In `lib/exec.ex`, the alias line is currently a multi-alias that now reads awkwardly. Replace it:

```elixir
  alias Exec.{Output, Program, ProgramSupervisor}
```

In `lib/exec/program_supervisor.ex`, replace `alias Exec.Program` — it is now aliasing a module in its own namespace, which Credo's consistency checks accept, but the `Connection` references in the body must all read `Program`:

```elixir
defmodule Exec.ProgramSupervisor do
  @moduledoc false

  # Every running program hangs off here, one child per program. Children are
  # `:temporary` -- a program that ends has ended, and restarting it would run
  # the command a second time -- so this supervisor exists to own them and take
  # them down with the VM, not to bring them back.

  use DynamicSupervisor

  alias Exec.Program

  # :temporary: a restarted worker would re-run the command, and its program is
  # already gone.
  def start_program(command, owner, opts) do
    DynamicSupervisor.start_child(__MODULE__, %{
      id: Program,
      start: {Program, :start_link, [command, owner, opts]},
      restart: :temporary
    })
  end

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
```

- [ ] **Step 4: Update `mix.exs`**

Two keys change; `app:` does not.

```elixir
      mod: {Exec.Application, []}
```

```elixir
      main: "Exec",
```

Also update the comment above `mod:` so it names the right modules:

```elixir
    # `mod:` exists only to supervise Exec.ProgramSupervisor, which owns one
    # process per running program. `:erlexec` remains an ordinary started
    # dependency that supervises its own `exec` gen_server -- we do not start,
    # configure or wrap it.
```

- [ ] **Step 5: Confirm no stale references remain**

```bash
grep -rn 'ElixirExec' lib test mix.exs
```

Expected: matches only in `lib/mix/tasks/elixir_exec.setup_user.ex` (the task module name, deliberately unchanged) and `mix.exs`'s `app: :elixir_exec`.

- [ ] **Step 6: Compile and run the suite**

```bash
mix format && mix compile --warnings-as-errors && mix test
```

Expected: PASS. This task changes no behaviour, so every existing test must still pass unmodified apart from its module references.

- [ ] **Step 7: Commit**

```bash
git add -A lib test mix.exs
git commit -m "refactor: rename ElixirExec to Exec

Connection becomes Program and ConnectionSupervisor becomes
ProgramSupervisor. The OTP application and Hex package stay :elixir_exec.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Rename the public functions

`capture/2` → `run/2`, the old `run/2` → `open/2`, `stream/2` → `stream!/2`, `kill/2` → `signal/2`. Return shapes are unchanged in this task — `Exec.Output` still holds lists, `stream!/2` still emits `{:exit_status, s}`.

**Files:**
- Modify: `lib/exec.ex`
- Test: `test/exec_test.exs`

**Interfaces:**
- Consumes: `Exec.ProgramSupervisor.start_program/3` from Task 1.
- Produces: `Exec.run/2` returning `{:ok, %Exec.Output{}} | {:error, term}`; `Exec.open/2` returning `{:ok, pid} | {:error, term}`; `Exec.stream!/2` returning `Enumerable.t()`; `Exec.signal/2` returning `:ok | {:error, term}`. `read/2`, `write/2`, `stop/1` unchanged.

Do the rename in a single pass, because `run` collides with itself: the old `run` must become `open` **before** `capture` becomes `run`.

- [ ] **Step 1: Update the tests first, so they fail**

In `test/exec_test.exs`:

- Rename `describe "run/2, read/2, write/2"` to `describe "open/2, read/2, write/2"`, and inside it change every `Exec.run(` to `Exec.open(`, and every `conn` binding to `program` (the variable name should stop echoing the removed `conn` type).
- In `describe "stop/1 and kill/2"` → `describe "stop/1 and signal/2"`; change `Exec.run(` to `Exec.open(` and `Exec.kill(conn, 9)` to `Exec.signal(program, 9)`.
- Rename `describe "capture/2"` to `describe "run/2"` and change every `Exec.capture(` to `Exec.run(`.
- In `describe "stream/2"` → `describe "stream!/2"`, change every `Exec.stream(` to `Exec.stream!(`.
- In `describe "lifetime"`, change `Exec.run(` to `Exec.open(` and `Process.whereis(Exec.ConnectionSupervisor)` to `Process.whereis(Exec.ProgramSupervisor)` if Task 1's sweep missed it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test`
Expected: FAIL with `function Exec.open/1 is undefined or private` and similar for `stream!/1` and `signal/2`.

- [ ] **Step 3: Rename in `lib/exec.ex`**

Rename the old `run/2` to `open/2` — the `@doc`, both `@spec` lines, and the `def`:

```elixir
  @spec open(binary() | [binary()]) :: {:ok, t()} | {:error, term()}
  @spec open(binary() | [binary()], options()) :: {:ok, t()} | {:error, term()}
  def open(command, options \\ []) do
    {owner, options} = Keyword.pop(options, :owner, self())
    command = command |> normalize_command() |> resolve_command()
    ProgramSupervisor.start_program(command, owner, options)
  end
```

Rename `capture/2` to `run/2`:

```elixir
  @spec run(binary() | [binary()]) :: {:ok, Output.t()} | {:error, term()}
  @spec run(binary() | [binary()], options()) ::
          {:ok, Output.t()} | {:error, :timeout} | {:error, term()}
  def run(command, options \\ []) do
    with {:ok, program} <- open(command, options) do
      collect(program, [], [], deadline(options[:timeout] || :infinity))
    end
  end
```

Rename `stream/2` to `stream!/2`, updating its two `@spec`s and its internal `run(` call to `open(`:

```elixir
  @spec stream!(binary() | [binary()]) :: Enumerable.t()
  @spec stream!(binary() | [binary()], options()) :: Enumerable.t()
  def stream!(command, options \\ []) do
    Stream.resource(
      fn ->
        case open(command, options) do
          {:ok, program} -> {program, "", ""}
          {:error, reason} -> raise "could not start the command: #{inspect(reason)}"
        end
      end,
      &stream_next/1,
      &stream_teardown/1
    )
  end
```

Rename `kill/2` to `signal/2`:

```elixir
  @spec signal(t(), atom() | integer()) :: :ok | {:error, term()}
  def signal(program, signal), do: Program.kill(program, signal)
```

Rename the opaque type `conn` to `t` and update every `conn()` occurrence in the `@spec`s of `read/2`, `write/2`, `stop/1` and `signal/2`:

```elixir
  @typedoc "A running program. Pass it back to `read/2`, `write/2`, `stop/1` and `signal/2`."
  @opaque t :: pid()
```

Rename the `conn` parameter to `program` throughout `lib/exec.ex`, including inside `collect/4`, `stream_next/1` and `stream_teardown/1`.

Cross-references inside `@doc` strings that still say `capture/2`, `stream/2`, `run/2`-as-handle or `kill/2` must be updated to the new names. Task 8 rewrites the prose; this step only keeps the references from dangling.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
mix format && mix test
```
Expected: PASS.

- [ ] **Step 5: Verify no old names survive**

```bash
grep -rn '\bExec\.capture\|\bExec\.kill\|def capture\|def kill(\|conn()' lib test
```
Expected: no matches. (`Exec.Program.kill/2` is a private-module function and keeps its name; the grep above will not match it because it is written `Program.kill`.)

- [ ] **Step 6: Commit**

```bash
mix credo --strict && mix dialyzer
git add lib/exec.ex test/exec_test.exs
git commit -m "refactor!: rename public functions to idiomatic names

capture/2 -> run/2, run/2 -> open/2, stream/2 -> stream!/2,
kill/2 -> signal/2. The opaque conn type becomes t.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Unify the exit event tag

`stream!/2` emits `{:exit_status, status}` as its final element while `read/2` emits `{:exit, status}` for the same event. Unify on `{:exit, status}`.

**Files:**
- Modify: `lib/exec.ex`
- Test: `test/exec_test.exs`

**Interfaces:**
- Consumes: `Exec.stream!/2` from Task 2.
- Produces: `stream!/2` elements are `{:stdout, binary} | {:stderr, binary} | {:exit, exit_status}`, identical to the `event()` type.

- [ ] **Step 1: Update the failing tests**

In `test/exec_test.exs`, inside `describe "stream!/2"`, replace all three `{:exit_status, 0}` with `{:exit, 0}`:

```elixir
    test "yields stdout lines with the delimiter retained, then the exit status" do
      assert ~S(printf 'a\nb\n') |> Exec.stream!() |> Enum.to_list() ===
               [{:stdout, "a\n"}, {:stdout, "b\n"}, {:exit, 0}]
    end

    test "yields stderr lines the same way" do
      assert ~S(printf 'e\n' 1>&2) |> Exec.stream!() |> Enum.to_list() ===
               [{:stderr, "e\n"}, {:exit, 0}]
    end

    test "flushes a trailing partial line that has no delimiter" do
      assert ~S(printf 'a\nb') |> Exec.stream!() |> Enum.to_list() ===
               [{:stdout, "a\n"}, {:stdout, "b"}, {:exit, 0}]
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/exec_test.exs`
Expected: FAIL — the assertions get `{:exit_status, 0}` where they expect `{:exit, 0}`.

- [ ] **Step 3: Change the one line that emits it**

In `lib/exec.ex`, inside `stream_next/1`:

```elixir
      {:ok, {:exit, status}} ->
        {flush(:stdout, out) ++ flush(:stderr, err) ++ [{:exit, status}], :done}
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format && mix credo --strict
git add lib/exec.ex test/exec_test.exs
git commit -m "fix!: emit {:exit, status} from stream!/2

read/2 and stream!/2 described the same event with two different tags.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `Exec.Output` becomes `Exec.Result` with binary fields

Chunk boundaries in `stdout`/`stderr` are an OS pipe artifact. Join them into a binary, as `System.cmd/3` returns, and rename the struct.

**Files:**
- Move: `lib/exec/output.ex` → `lib/exec/result.ex`
- Modify: `lib/exec/result.ex`, `lib/exec.ex`
- Test: `test/exec_test.exs`

**Interfaces:**
- Consumes: `Exec.run/2` from Task 2.
- Produces: `%Exec.Result{stdout: binary(), stderr: binary(), exit_status: Exec.exit_status()}`. `Exec.Output` no longer exists. `@type Exec.exit_status :: non_neg_integer() | {:signal, atom() | pos_integer()}` is defined in `Exec` and referenced by `Exec.Result`.

- [ ] **Step 1: Update the failing tests**

In `test/exec_test.exs`, change `alias Exec.Output` to `alias Exec.Result`, and rewrite the `describe "run/2"` assertions to expect binaries:

```elixir
    test "returns stdout, stderr and the exit status" do
      assert Exec.run("echo out; echo err 1>&2") ===
               {:ok, %Result{stdout: "out\n", stderr: "err\n", exit_status: 0}}
    end

    test "reports a non-zero exit as success, with the shell's code" do
      assert Exec.run("echo partial; exit 3") ===
               {:ok, %Result{stdout: "partial\n", stderr: "", exit_status: 3}}
    end
```

Add a test proving chunks are joined rather than listed:

```elixir
    test "joins output written in separate chunks into one binary" do
      assert {:ok, %Result{stdout: "abc"}} = Exec.run("printf a; sleep 0.2; printf bc")
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/exec_test.exs`
Expected: FAIL — `Exec.Result.__struct__/1 is undefined`.

- [ ] **Step 3: Write `lib/exec/result.ex`**

```bash
git mv lib/exec/output.ex lib/exec/result.ex
```

Replace the whole file. The moduledoc here is already in final voice — Task 8 will not revisit it.

```elixir
defmodule Exec.Result do
  @moduledoc """
  The output and exit status of a command run to completion.

  Returned by `Exec.run/2`.

  ## Fields

    * `:stdout` — everything the command wrote on standard output, as a single
      binary. Empty when the command wrote nothing, or when it was started with
      `stdout: false`.

    * `:stderr` — the same, for standard error.

    * `:exit_status` — the code the command exited with, as a shell reports it:
      `0` for success, `3` for `exit 3`. A command killed by a signal reports
      `{:signal, name}`, such as `{:signal, :sigterm}`, or `{:signal, number}`
      for a signal `:exec.signal/1` does not name, such as a real-time signal.
  """

  defstruct [:stdout, :stderr, :exit_status]

  @type t :: %__MODULE__{
          stdout: binary(),
          stderr: binary(),
          exit_status: Exec.exit_status()
        }
end
```

- [ ] **Step 4: Define `exit_status` in `Exec` and join the chunks**

In `lib/exec.ex`, add the type next to `event`, and express `event` in terms of it:

```elixir
  @typedoc "How a command ended: a shell exit code, or `{:signal, name}` if a signal killed it."
  @type exit_status :: non_neg_integer() | {:signal, atom() | pos_integer()}

  @typedoc "One thing a program produced."
  @type event :: {:stdout, binary()} | {:stderr, binary()} | {:exit, exit_status()}
```

Change the alias to `alias Exec.{Program, ProgramSupervisor, Result}` and convert the accumulators once, at exit, in `collect/4`:

```elixir
      {:ok, {:exit, status}} ->
        {:ok,
         %Result{
           stdout: out |> Enum.reverse() |> IO.iodata_to_binary(),
           stderr: err |> Enum.reverse() |> IO.iodata_to_binary(),
           exit_status: status
         }}
```

Update `run/2`'s two `@spec`s from `Output.t()` to `Result.t()`.

- [ ] **Step 5: Run to verify they pass**

Run: `mix test`
Expected: PASS. The doctest in `run/2`'s `@doc` still shows `%ElixirExec.Output{stdout: ["hi\n"], ...}` and will fail — fix it now to `{:ok, %Exec.Result{stdout: "hi\n", stderr: "", exit_status: 0}}`.

- [ ] **Step 6: Commit**

```bash
mix format && mix credo --strict && mix dialyzer
git add -A lib test
git commit -m "refactor!: Exec.Output becomes Exec.Result with binary fields

Chunk boundaries in stdout/stderr are an OS pipe artifact, not something
the caller asked about. Result now matches what System.cmd/3 returns.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Validate options instead of silently dropping them

`Keyword.take/2` currently discards any key it does not recognise, so a typo is invisible. Raise `ArgumentError` instead, and raise for erlexec's `{:invalid_option, _}` too — matching `System.cmd/3`, which raises on bad options.

**Files:**
- Modify: `lib/exec.ex`, `lib/exec/program.ex`
- Test: `test/exec_test.exs`

**Interfaces:**
- Consumes: `Exec.open/2` from Task 2.
- Produces: `Exec.open/2`, `Exec.run/2` and `Exec.stream!/2` raise `ArgumentError` on an unrecognised option key or an option value erlexec rejects. `Exec.Program.build_exec_options/1` no longer filters unknown keys — `Exec` has already rejected them.

Option groups, from the spec:

- Handled by `Exec` itself: `:timeout` (`run/2` only), `:owner`, `:stdin`, `:stdout`, `:stderr`.
- Forwarded to `:exec.run/2`: `:executable`, `:cd`, `:env`, `:kill`, `:kill_timeout`, `:group`, `:user`, `:nice`, `:success_exit_code`, `:winsz`, `:pty`, `:capabilities`, `:debug`.

- [ ] **Step 1: Write the failing tests**

In `test/exec_test.exs`, replace the existing test `"an option the runner does not take is ignored"` with:

```elixir
    test "an unrecognised option raises" do
      assert_raise ArgumentError, ~r/unknown option :definitely_not_an_option/, fn ->
        Exec.open("echo hi", definitely_not_an_option: 1)
      end
    end

    test "an option value the runner rejects raises" do
      assert_raise ArgumentError, ~r/invalid value for :cd/, fn ->
        Exec.open("echo hi", cd: 12_345)
      end
    end

    test ":timeout is accepted without being forwarded to the runner" do
      {:ok, program} = Exec.open("echo hi", timeout: 5_000)

      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
    end
```

And in `describe "run/2"`:

```elixir
    test "an unrecognised option raises" do
      assert_raise ArgumentError, ~r/unknown option :nope/, fn -> Exec.run("echo hi", nope: 1) end
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/exec_test.exs`
Expected: FAIL — no `ArgumentError` is raised; `Exec.open/2` succeeds.

- [ ] **Step 3: Validate in `Exec.open/2`**

In `lib/exec.ex`, add the two option lists as module attributes near the top, after the `alias`:

```elixir
  # Read by this module, never forwarded to :exec.run/2.
  @own_options [:timeout, :owner, :stdin, :stdout, :stderr]

  # Passed to :exec.run/2 unchanged. Documented in this module's own terms; see
  # the `options` typedoc.
  @forwarded_options [
    :executable,
    :cd,
    :env,
    :kill,
    :kill_timeout,
    :group,
    :user,
    :nice,
    :success_exit_code,
    :winsz,
    :pty,
    :capabilities,
    :debug
  ]
```

Rewrite `open/2` to validate before starting:

```elixir
  def open(command, options \\ []) do
    validate_options!(options)
    {owner, options} = Keyword.pop(options, :owner, self())
    command = command |> normalize_command() |> resolve_command()
    ProgramSupervisor.start_program(command, owner, options)
  end

  # A dropped option is an invisible bug: the command runs, quietly ignoring the
  # `cd:` that was meant to place it. System.cmd/3 raises here too.
  defp validate_options!(options) do
    known = @own_options ++ @forwarded_options

    case Enum.find(Keyword.keys(options), &(&1 not in known)) do
      nil -> :ok
      key -> raise ArgumentError, "unknown option #{inspect(key)}"
    end
  end
```

- [ ] **Step 4: Turn erlexec's `{:invalid_option, _}` into an `ArgumentError`**

An invalid *value* is only detectable by erlexec, and it surfaces as a start failure from `:exec.run/2`, which `Exec.Program.init/1` turns into `{:stop, reason}`. Convert it in `open/2` where the supervisor's result is returned:

```elixir
  def open(command, options \\ []) do
    validate_options!(options)
    {owner, options} = Keyword.pop(options, :owner, self())
    command = command |> normalize_command() |> resolve_command()

    case ProgramSupervisor.start_program(command, owner, options) do
      {:ok, program} -> {:ok, program}
      {:error, {:invalid_option, {key, value}}} -> raise ArgumentError, invalid_value(key, value)
      {:error, reason} -> {:error, reason}
    end
  end

  defp invalid_value(key, value) do
    "invalid value for #{inspect(key)}: #{inspect(value)}"
  end
```

- [ ] **Step 5: Stop double-filtering in `Exec.Program`**

`build_exec_options/1` is still named `exec_run_options/1` at this point — Task 7 renames it. Replace its `Keyword.take/2` call with a drop of the options this module consumes itself, so a forwarded key can never be silently lost in two places:

```elixir
    run_opts = Keyword.drop(opts, [:timeout, :owner, :stdin, :stdout, :stderr])

    proplist ++ run_opts
```

- [ ] **Step 6: Run to verify they pass**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
mix format && mix credo --strict && mix dialyzer
git add lib test
git commit -m "feat!: raise ArgumentError on unknown or invalid options

A silently dropped option is an invisible bug: the command runs, quietly
ignoring the cd: that was meant to place it. Matches System.cmd/3.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Normalize start-failure reasons

`{:error, ~c"empty command provided"}` leaks an erlexec charlist. Only two start failures are reachable in the asynchronous mode this library uses, and Task 5 already converted one of them into an `ArgumentError`.

**Files:**
- Modify: `lib/exec.ex`
- Test: `test/exec_test.exs`

**Interfaces:**
- Consumes: `Exec.open/2` from Task 5.
- Produces: `Exec.open/2` and `Exec.run/2` return `{:error, :empty_command}` for an empty command and `{:error, {:exec, binary}}` for any other erlexec start failure. `Exec.stream!/2` raises `Exec.Error` with the same reason in its message.

**Verified erlexec behaviour** (probed against erlexec 2.3 — do not re-derive):

```
:exec.run("", [...])                       #=> {:error, ~c"empty command provided"}
:exec.run("echo hi", [{:cd, 12345}, ...])  #=> {:error, {:invalid_option, {:cd, 12345}}}
:exec.run(["/nonexistent/nope"], [...])    #=> {:ok, pid, ospid}, then stderr + exit 1
```

A missing executable, a permission failure and an unreachable `:cd` are **not** start errors. They start, write a diagnostic to stderr, and exit `1`. There are no POSIX reasons to normalize.

- [ ] **Step 1: Write the failing tests**

Replace the two existing empty-command tests. In `describe "open/2, read/2, write/2"`:

```elixir
    test "an empty command is an error" do
      assert Exec.open("") === {:error, :empty_command}
    end
```

In `describe "run/2"`:

```elixir
    test "an empty command is an error, not an exit status" do
      assert Exec.run("") === {:error, :empty_command}
    end
```

And add a test pinning the finding that a missing executable is an exit, not an error — this is the behaviour the documentation will claim, so it needs a test:

```elixir
    test "a missing executable exits non-zero with a diagnostic, rather than erroring" do
      assert {:ok, result} = Exec.run(["/nonexistent/nope"])

      assert result.exit_status === 1
      assert result.stderr =~ "No such file or directory"
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/exec_test.exs`
Expected: FAIL — the empty-command tests get `{:error, ~c"empty command provided"}`.

- [ ] **Step 3: Normalize in `open/2`**

In `lib/exec.ex`, extend the `case` added in Task 5:

```elixir
    case ProgramSupervisor.start_program(command, owner, options) do
      {:ok, program} -> {:ok, program}
      {:error, {:invalid_option, {key, value}}} -> raise ArgumentError, invalid_value(key, value)
      {:error, reason} -> {:error, normalize_start_error(reason)}
    end
```

```elixir
  # The runner reports start failures as charlist messages. Only the empty
  # command is reachable through this module's own argument checks; anything
  # else is tagged rather than guessed at, so it stays matchable.
  defp normalize_start_error(~c"empty command provided"), do: :empty_command
  defp normalize_start_error(reason) when is_list(reason), do: {:exec, to_string(reason)}
  defp normalize_start_error(reason), do: {:exec, reason}
```

- [ ] **Step 4: Give `stream!/2` a real exception**

The current `raise "could not start the command: ..."` produces a `RuntimeError`, which callers cannot distinguish from any other. Create `lib/exec/error.ex`:

```elixir
defmodule Exec.Error do
  @moduledoc """
  Raised by `Exec.stream!/2` when a command cannot be started.

  The `:reason` field carries the same value `Exec.open/2` would have returned
  in `{:error, reason}`.
  """

  defexception [:reason]

  @impl Exception
  def message(%__MODULE__{reason: reason}) do
    "could not start the command: #{inspect(reason)}"
  end
end
```

And raise it in `stream!/2`:

```elixir
          {:error, reason} -> raise Exec.Error, reason: reason
```

Update the `stream!/2` failure test:

```elixir
    test "a command that cannot be started raises" do
      stream = Exec.stream!("")

      assert_raise Exec.Error, "could not start the command: :empty_command", fn ->
        Enum.to_list(stream)
      end
    end
```

- [ ] **Step 5: Run to verify they pass**

Run: `mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format && mix credo --strict && mix dialyzer
git add -A lib test
git commit -m "feat!: normalize start-failure reasons

Empty commands return {:error, :empty_command} rather than an erlexec
charlist; stream!/2 raises Exec.Error rather than a bare RuntimeError.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Rename the private functions

Pure rename. No test changes — if a test needs editing, something behavioural was changed by mistake.

**Files:**
- Modify: `lib/exec.ex`, `lib/exec/program.ex`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: no public change.

| In `lib/exec.ex` | New name |
|---|---|
| `collect/4` | `read_until_exit/4` |
| `deadline/1` | `deadline_after/1` |
| `time_left/1` | `remaining_timeout/1` |
| `stream_next/1` | `emit_lines/1` |
| `stream_teardown/1` | `stop_unless_exited/1` |
| `split_lines/1` | `split_complete_lines/1` |
| `flush/2` | `trailing_line/2` |
| `normalize_command/1` | `command_to_binaries/1` |
| `resolve_command/1` | `resolve_executable_path/1` |

| In `lib/exec/program.ex` | New name |
|---|---|
| `record/2` | `deliver_or_queue/2` |
| `read_timer/1` | `start_read_timer/1` |
| `exec_run_options/1` | `build_exec_options/1` |
| `exit_status/1` | `decode_exit_reason/1` |

`cancel_read_timer/1` is already accurate and does not change.

- [ ] **Step 1: Rename in `lib/exec.ex`**

```bash
sed -i '' \
  -e 's/\bcollect\b/read_until_exit/g' \
  -e 's/\bstream_next\b/emit_lines/g' \
  -e 's/\bstream_teardown\b/stop_unless_exited/g' \
  -e 's/\bsplit_lines\b/split_complete_lines/g' \
  -e 's/\bnormalize_command\b/command_to_binaries/g' \
  -e 's/\bresolve_command\b/resolve_executable_path/g' \
  -e 's/\btime_left\b/remaining_timeout/g' \
  lib/exec.ex
```

`deadline/1` and `flush/2` cannot be renamed by word-boundary `sed`: `deadline` is also the name of the *variable* threaded through `read_until_exit/4`, and `flush` is short enough to appear in prose. Rename those two by hand:

- The two `defp deadline(...)` clauses become `defp deadline_after(...)`, and the single call site inside `run/2` becomes `deadline_after(options[:timeout] || :infinity)`. Leave every `deadline` *variable* alone.
- The two `defp flush(...)` clauses become `defp trailing_line(...)`, and the two call sites inside `emit_lines/1` become `trailing_line(:stdout, out) ++ trailing_line(:stderr, err)`.

- [ ] **Step 2: Rename in `lib/exec/program.ex`**

```bash
sed -i '' \
  -e 's/\brecord\b/deliver_or_queue/g' \
  -e 's/\bread_timer\b/start_read_timer/g' \
  -e 's/\bexec_run_options\b/build_exec_options/g' \
  lib/exec/program.ex
```

`cancel_read_timer` is safe from that sweep: `_` is a word character, so there is no `\b` between `cancel_` and `read_timer` and `\bread_timer\b` cannot match inside it. Confirm rather than assume:

```bash
grep -n 'read_timer' lib/exec/program.ex
```
Expected: `start_read_timer` (two definitions, one call site) and `cancel_read_timer` (two definitions, two call sites) — and no `cancel_start_read_timer`.

Rename `exit_status/1` to `decode_exit_reason/1` by hand — `exit_status` also appears as an erlexec message tag (`{:exit_status, raw}`) inside the function body, and as `Result`'s field name:

```elixir
  # The runner reports the exit as a wait(2) status word: the low byte is the
  # signal that killed it, the high byte the code it exited with.
  defp decode_exit_reason(status) do
    case status do
      :normal -> 0
      {:exit_status, raw} when Bitwise.band(raw, 0xFF) === 0 -> Bitwise.bsr(raw, 8)
      {:exit_status, raw} -> {:signal, :exec.signal(Bitwise.band(raw, 0x7F))}
      other -> other
    end
  end
```

And its one call site in `handle_info({:EXIT, _controller, reason}, state)`:

```elixir
    deliver_or_queue(state, {:exit, decode_exit_reason(reason)})
```

- [ ] **Step 3: Run the suite unchanged**

```bash
mix format && mix compile --warnings-as-errors && mix test
```
Expected: PASS, with `test/exec_test.exs` untouched by this task. If a test needed editing, revert and find what behaviour changed.

- [ ] **Step 4: Verify no old names survive**

```bash
grep -rn 'defp collect\|defp deadline(\|defp time_left\|defp stream_next\|defp stream_teardown\|defp split_lines\|defp flush\|defp normalize_command\|defp resolve_command\|defp record(\|defp read_timer\|defp exec_run_options\|defp exit_status' lib
```
Expected: no matches.

- [ ] **Step 5: Commit**

```bash
mix credo --strict && mix dialyzer
git add lib
git commit -m "refactor: name private functions for what they do

collect -> read_until_exit, record -> deliver_or_queue, flush ->
trailing_line, exit_status -> decode_exit_reason, and so on.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Rewrite the module and function documentation

Third-person indicative throughout. Sections in `System`'s order. Rationale moves to code comments.

**Files:**
- Modify: `lib/exec.ex` (`@moduledoc`, every `@doc`, both `@typedoc`s)
- Test: `test/exec_test.exs` (doctests run from `doctest Exec`)

**Interfaces:**
- Consumes: the final API from Tasks 1–7.
- Produces: no code change. Documentation only.

Write the documentation exactly as below.

- [ ] **Step 1: Replace the `@moduledoc`**

```elixir
  @moduledoc """
  Runs and controls operating system processes.

  Three entry points, in increasing order of control:

    * `run/2` runs a command to completion and returns its output.
    * `stream!/2` runs a command and yields its output lazily, line by line.
    * `open/2` starts a command and returns a handle for `read/2`, `write/2`,
      `stop/1` and `signal/2`.

  `run/2` and `stream!/2` are both written in terms of `open/2` and `read/2`.

      iex> {:ok, result} = Exec.run("echo hello")
      iex> result.stdout
      "hello\\n"

  ## Command forms

  A command is either a binary, which a shell parses, or a list of binaries,
  which is passed to `execve` directly with no shell involved:

      Exec.run("ls -l | wc -l")   # a shell handles PATH, pipes and redirection
      Exec.run(["echo", "hi"])    # no shell, no expansion, no interpolation

  In list form a bare executable name is resolved against `PATH` first, so
  `["echo", "hi"]` behaves as `"echo hi"` does. A name containing `/` is used
  exactly as given.

  > #### Watch out {: .warning}
  >
  > The binary form is parsed by a shell, so never pass untrusted input to it.
  > `Exec.run("cat \#{user_input}")` runs whatever the input says. Use the list
  > form, which does not involve a shell, whenever any part of the command comes
  > from outside the application.

  ## Lifetime

  A program never outlives the process that started it. If that process dies,
  including under `Process.exit(pid, :kill)`, the program is stopped. This holds
  for `run/2`, `stream!/2` and `open/2` alike, and does not survive the VM
  itself going down.

  The reverse does not hold: a program that fails or exits non-zero does not
  disturb the process that started it.

  Pass `owner: pid` to tie a program's lifetime to a process other than the
  caller.

  ## Failure to launch

  A missing executable, a permission failure and an unreachable `:cd` are
  reported as a non-zero exit status with a diagnostic on standard error, not as
  `{:error, reason}`:

      iex> {:ok, result} = Exec.run(["/nonexistent/nope"])
      iex> result.exit_status
      1

  `{:error, reason}` means the command could not be handed to the operating
  system at all.
  """
```

- [ ] **Step 2: Replace the `@typedoc`s**

```elixir
  @typedoc """
  Options for a command, as a keyword list.

  Read by this module:

    * `:timeout` - milliseconds bounding a whole `run/2` call. Defaults to
      `:infinity`. Ignored by `stream!/2` and `open/2`, which have no total
      duration to bound.
    * `:owner` - the process whose death stops the program. Defaults to the
      calling process.
    * `:stdin`, `:stdout`, `:stderr` - whether to connect that stream to the
      program. Each defaults to `true`. A program started with `stdout: false`
      produces no `{:stdout, _}` events at all.

  Forwarded to the underlying runner unchanged: `:executable`, `:cd`, `:env`,
  `:kill`, `:kill_timeout`, `:group`, `:user`, `:nice`, `:success_exit_code`,
  `:winsz`, `:pty`, `:capabilities` and `:debug`. See
  [erlexec](https://hexdocs.pm/erlexec/exec.html) for their meanings.

  Any other key raises `ArgumentError`, as does a value the runner rejects.
  """
  @type options :: keyword()

  @typedoc "A running program, as returned by `open/2`."
  @opaque t :: pid()

  @typedoc "How a command ended: a shell exit code, or `{:signal, name}` if a signal killed it."
  @type exit_status :: non_neg_integer() | {:signal, atom() | pos_integer()}

  @typedoc "One thing a program produced, as returned by `read/2`."
  @type event :: {:stdout, binary()} | {:stderr, binary()} | {:exit, exit_status()}
```

- [ ] **Step 3: Replace the `@doc` for `run/2`**

```elixir
  @doc """
  Runs `command` to completion and returns its output.

  Returns `{:ok, %Exec.Result{}}` whenever the command ran, including when it
  exited non-zero. A non-zero exit is an outcome, not an error — `grep` finding
  nothing exits `1` — so the code is reported in the result rather than as
  `{:error, _}`.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Never pass untrusted input to it; use
  > the list form instead. See the module documentation.

  ## Examples

      iex> Exec.run("echo hi")
      {:ok, %Exec.Result{stdout: "hi\\n", stderr: "", exit_status: 0}}

      iex> {:ok, result} = Exec.run("exit 3")
      iex> result.exit_status
      3

  ## Options

  Accepts every option in `t:options/0`. `:timeout` bounds the whole call rather
  than the gap between two chunks, so a command that prints continuously still
  times out. On expiry the program is stopped:

      iex> Exec.run("sleep 30", timeout: 200)
      {:error, :timeout}

  ## Errors

    * `{:error, :timeout}` - the command outlived `:timeout` and was stopped.
    * `{:error, :empty_command}` - `command` was empty.
    * `{:error, {:exec, message}}` - the runner refused to start the command.

  Raises `ArgumentError` for an unknown option key or a value the runner
  rejects.
  """
```

- [ ] **Step 4: Replace the `@doc` for `stream!/2`**

```elixir
  @doc """
  Runs `command` and returns its output as a lazy stream of lines.

  Nothing runs until enumeration begins, so a stream that is never enumerated
  never starts a program.

  Elements are `{:stdout, line}`, `{:stderr, line}`, and a final
  `{:exit, status}`. Lines keep their delimiter, and a final line without one is
  emitted as it stands. Standard output and standard error are each in order,
  but not ordered relative to each other.

  The `{:exit, status}` element is emitted only when the program ends on its
  own. Halting early — through `Enum.take/2`, a `Enum.reduce_while/3` halt, or
  an exception — stops the program and emits no exit element. That absence
  distinguishes a halted enumeration from a finished program.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Never pass untrusted input to it; use
  > the list form instead. See the module documentation.

  ## Examples

      iex> ~S(printf 'a\\nb\\n') |> Exec.stream!() |> Enum.to_list()
      [stdout: "a\\n", stdout: "b\\n", exit: 0]

      "tail -f /var/log/system.log"
      |> Exec.stream!()
      |> Stream.filter(&match?({:stdout, _}, &1))
      |> Enum.take(5)

  ## Options

  Accepts every option in `t:options/0` except `:timeout`, which a lazy stream
  has no total duration to apply to.

  ## Errors

  Raises `Exec.Error` when the command cannot be started, rather than returning
  `{:error, reason}` as `run/2` and `open/2` do: a lazy stream has no error
  channel. Raises `ArgumentError` for an unknown option key or a value the
  runner rejects.
  """
```

- [ ] **Step 5: Replace the `@doc` for `open/2`**

```elixir
  @doc """
  Starts `command` and returns a handle to it.

  The handle is passed to `read/2`, `write/2`, `stop/1` and `signal/2`. Output
  is held until `read/2` asks for it, so nothing reaches the caller's mailbox
  and nothing is lost between reads.

  Standard input, output and error are connected unless `stdin: false`,
  `stdout: false` or `stderr: false` is given.

  > #### Watch out {: .warning}
  >
  > A binary command is parsed by a shell. Never pass untrusted input to it; use
  > the list form instead. See the module documentation.

  ## Examples

      {:ok, program} = Exec.open("cat")

      Exec.write(program, "hello\\n")
      {:ok, {:stdout, "hello\\n"}} = Exec.read(program)

      Exec.write(program, :eof)
      {:ok, {:exit, 0}} = Exec.read(program)

  ## Options

  Accepts every option in `t:options/0` except `:timeout`, which applies to
  `run/2`. `read/2` takes its own timeout per call.

  ## Errors

    * `{:error, :empty_command}` - `command` was empty.
    * `{:error, {:exec, message}}` - the runner refused to start the command.

  Raises `ArgumentError` for an unknown option key or a value the runner
  rejects.
  """
```

- [ ] **Step 6: Replace the remaining four `@doc`s**

```elixir
  @doc """
  Reads the next event from `program`.

  Blocks until an event arrives or `timeout` milliseconds pass. Events are held
  in order, so none is lost between calls.

  `{:ok, {:exit, status}}` is the last event a program produces. The handle is
  spent once it is read, and reading again exits the calling process.

  ## Examples

      {:ok, {:stdout, "line one\\n"}} = Exec.read(program)
      {:error, :timeout} = Exec.read(program, 0)

  ## Errors

    * `{:error, :timeout}` - no event arrived within `timeout`. The program is
      left running.
  """
```

```elixir
  @doc """
  Writes `data` to the standard input of `program`, or closes it with `:eof`.

  Returns `{:error, reason}` if the program has already exited. A program
  started with `stdin: false` accepts the write and discards it.

  ## Examples

      :ok = Exec.write(program, "hello\\n")
      :ok = Exec.write(program, :eof)
  """
```

```elixir
  @doc """
  Ends `program` gracefully.

  Sends `SIGTERM` and escalates to `SIGKILL` after roughly five seconds, so a
  program that ignores `SIGTERM` can take that long to end. `signal/2` with
  `:sigkill` ends it immediately.

  A program stopped this way reports exit status `0`, not a signal.
  """
```

```elixir
  @doc """
  Sends `signal` to `program`.

  `signal` is an atom such as `:sigterm`, `:sigkill` or `:sighup`, or the
  integer number. Unlike `stop/1` nothing is escalated: exactly one signal is
  sent.

  ## Examples

      :ok = Exec.signal(program, :sigkill)
      :ok = Exec.signal(program, 9)
  """
```

- [ ] **Step 7: Check the voice mechanically**

```bash
grep -nE '\byou\b|\byour\b|\byours\b' lib/exec.ex lib/exec/result.ex lib/exec/error.ex
```
Expected: no matches.

- [ ] **Step 8: Run the doctests**

```bash
mix format && mix test
```
Expected: PASS, including the four new doctests (`run/2` twice, the moduledoc twice, `stream!/2` once).

If the `stream!/2` doctest fails on element formatting, note that Elixir's inspect renders a list of two-tuples with atom keys as a keyword list — `[stdout: "a\n", stdout: "b\n", exit: 0]` — which is why the expected output is written that way. Do not "fix" it to tuple syntax.

- [ ] **Step 9: Commit**

```bash
mix credo --strict && mix dialyzer
git add lib
git commit -m "docs: rewrite in stdlib voice, aimed at usage questions

Third-person indicative throughout, sections in System's order, and a
shell-injection warning the docs never carried. Adds the failure-to-launch
section: a missing executable is an exit status, not an error.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Rewrite the README and add the LICENSE

**Files:**
- Modify: `README.md`
- Create: `LICENSE`

**Interfaces:**
- Consumes: the final API and documentation from Tasks 1–8.
- Produces: nothing code depends on.

- [ ] **Step 1: Add the LICENSE file**

`mix.exs` declares `licenses: ["Apache-2.0"]` and lists `LICENSE` in `:files`, but no such file exists, so `mix hex.build` fails.

```bash
curl -fsSL https://www.apache.org/licenses/LICENSE-2.0.txt -o LICENSE
```

Then append the copyright line to the end of the file:

```
Copyright 2026 Kurt Hogarth

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

- [ ] **Step 2: Verify the package builds**

```bash
mix hex.build
```
Expected: succeeds and reports the file list including `LICENSE`. Delete the resulting `.tar` afterwards.

- [ ] **Step 3: Rewrite `README.md`**

Structure, in order: title and one-line description → Installation → Quick start (the three entry points, one example each) → Command forms and shell safety → Options → Lifetime → Running as a non-root user → Design notes → Development → License.

Rules for the rewrite:

- Third person throughout, matching the module documentation. `grep -nE '\byou\b|\byour\b' README.md` must return nothing when finished.
- Every code example must use the final API: `Exec.run/2`, `Exec.stream!/2`, `Exec.open/2`, `Exec.read/2`, `Exec.write/2`, `Exec.stop/1`, `Exec.signal/2`, `%Exec.Result{}` with binary fields, `{:exit, status}` from `stream!/2`.
- **Delete the "Architecture" section.** It duplicates the code and has already rotted once (commit `3cef06e` fixed it). Replace it with "Design notes", carrying the rationale that Task 8 moved out of the `@doc`s: why the owner is held by a monitor while erlexec's controller is held by a link, why supervised children are `:temporary`, and why `:erlexec` is left to supervise itself.
- **Delete the closing LICENSE warning block** — Step 1 resolved it.
- Keep the Installation, Configuration and non-root-user sections largely as they are; they are accurate. Update the `ElixirExec.capture("whoami", user: "elixir_exec")` example to `Exec.run("whoami", user: "elixir_exec")`.
- Add to the Options section that an unrecognised option raises `ArgumentError` — the previous README stated the opposite ("neither filters nor validates them").
- Add a short "Failure to launch" note under Command forms: a missing executable is a non-zero exit with a stderr diagnostic, not `{:error, _}`.

- [ ] **Step 4: Verify every README example actually runs**

Extract each Elixir example and run it in `iex -S mix`. The `Exec.run("echo hi")` and `stream!` examples must produce exactly what the README claims.

```bash
mix run -e 'IO.inspect(Exec.run("echo hi"))'
mix run -e 'IO.inspect(~S(printf 'a\nb\n') |> Exec.stream!() |> Enum.to_list())'
```
Expected: `{:ok, %Exec.Result{stdout: "hi\n", stderr: "", exit_status: 0}}` and `[stdout: "a\n", stdout: "b\n", exit: 0]`.

- [ ] **Step 5: Build the docs**

```bash
mix docs
```
Expected: no warnings about broken references. `mix docs` warns on `@doc` cross-references to functions that no longer exist, which catches any `capture/2` or `kill/2` reference missed in Task 2.

- [ ] **Step 6: Full verification**

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
```
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add README.md LICENSE
git commit -m "docs: rewrite README for the Exec API, add LICENSE

Replaces the module inventory with design notes; the inventory duplicated
the code and had already rotted once. Adds the Apache-2.0 LICENSE that
mix.exs has always declared.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

Spec coverage check, section by section:

| Spec section | Task |
|---|---|
| Module layout (`Exec`, app name stays) | 1 |
| Public function renames | 2 |
| Types (`t`, `event`, `exit_status`) | 2, 4 |
| `Exec.Result` struct | 4 |
| Out of scope (`run!/2`, `cmd`/`shell` split) | not implemented, by design |
| Private module renames | 1 |
| Private function renames | 7 |
| Leak: chunked output | 4 |
| Leak: two exit tags | 3 |
| Leak: raw error reasons | 6 |
| Leak: option passthrough | 5 |
| Documentation voice and content | 8 |
| Shell-injection warning | 8 |
| Failure-to-launch documentation | 6 (test), 8 (docs), 9 (README) |
| README restructure, LICENSE | 9 |
| Tests | distributed through 3–6, verified in 9 |

Two deviations from the spec as written, both recorded in the spec itself by the corrections committed alongside it:

1. The DynamicSupervisor is `Exec.ProgramSupervisor`, not `Exec.Supervisor` — that name is taken by the root supervisor.
2. Error normalization produces `:empty_command` and `{:exec, binary}`, not POSIX atoms. Probing erlexec 2.3 showed that missing executables and permission failures are exits, not start errors, so there are no POSIX reasons to map.

One addition not in the spec: `Exec.Error` (Task 6, Step 4). `stream!/2` previously raised a bare `RuntimeError`, which is indistinguishable from any other runtime failure. A named exception carrying `:reason` is what the `!` in `stream!/2` implies.
