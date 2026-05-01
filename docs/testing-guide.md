# Testing Guide

`elixir_exec` is tested with ExUnit. The suite is intentionally an integration test suite for the public API — most cases spawn real OS processes (`echo`, `sleep`, `cat`, `bash -c "..."`) rather than mocking `:erlexec`. Pure modules (`Options`, `Output`, `OSProcess`, `Stream.Buffer`) are tested with fast `async: true` unit tests.

## Layout

| Test file | Module under test | Style |
|---|---|---|
| `test/elixir_exec_test.exs` | `ElixirExec` (public API) | `async: false` integration; spawns real processes; uses `doctest ElixirExec`. |
| `test/elixir_exec/runner_test.exs` | `ElixirExec.Runner` | `async: false`; exercises validation, dispatch, and stream-worker lifecycle end-to-end. |
| `test/elixir_exec/options_test.exs` | `ElixirExec.Options` | `async: true`; pure schema and translation. |
| `test/elixir_exec/output_test.exs` | `ElixirExec.Output` | `async: true`; uses `doctest`. |
| `test/elixir_exec/process_test.exs` | `ElixirExec.OSProcess` | `async: true`. |
| `test/elixir_exec/stream_test.exs` | `ElixirExec.Stream` | GenServer-level; uses dummy port pids to drive the worker. |
| `test/elixir_exec/stream/buffer_test.exs` | `ElixirExec.Stream.Buffer` | `async: true`; uses `doctest`. |
| `test/elixir_exec/stream_supervisor_test.exs` | `ElixirExec.StreamSupervisor` | DynamicSupervisor child management. |
| `test/elixir_exec/application_test.exs` | `ElixirExec.Application` | Verifies the supervision tree boots. |

`test/test_helper.exs` is a single line: `ExUnit.start()`. The application is started by Mix's normal lifecycle — there is no special harness.

## Running tests

Layer test execution narrow → broad (per `RULES.md`).

| Goal | Command |
|---|---|
| One test by line | `mix test test/elixir_exec/runner_test.exs:42` |
| One file | `mix test test/elixir_exec/runner_test.exs` |
| One module's tests + dependents | `mix test --include …` (none used currently — fall back to running matching files) |
| Whole suite | `mix test` |
| Coverage summary (CLI) | `mix coveralls` |
| Coverage HTML report | `mix coveralls.html` (writes `cover/excoveralls.html`) |
| Coverage LCOV (for CI) | `mix coveralls.lcov` |

`preferred_cli_env` in `mix.exs` makes `mix coveralls`, `mix coveralls.html`, and `mix dialyzer` automatically run under the `:test` environment.

## Async strategy

| Test file kind | `use ExUnit.Case` flag | Why |
|---|---|---|
| Integration tests that spawn OS processes | `async: false` | The test mailbox receives `{:stdout, _, _}` and `{:DOWN, _, _, _, _}` from `:erlexec`. Multiple integration cases running concurrently would race for those messages. |
| Pure-module unit tests | `async: true` | No shared state, no mailbox dependence. |

`BlitzCredoChecks.NoAsyncFalse` is enabled. Use `async: false` only when you have a real reason — and the integration suite is the legitimate case.

## Patterns

### Integration test pattern (real OS process)

From `test/elixir_exec_test.exs`:

```elixir
defmodule ElixirExecTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  doctest ElixirExec

  describe "kill/2" do
    test "kill via os_pid sends DOWN with exit_status 9" do
      {:ok, %ElixirExec.OSProcess{controller: pid, os_pid: os_pid}} =
        ElixirExec.run("sleep 10", monitor: true)

      assert :ok === ElixirExec.kill(os_pid, 9)

      assert_receive {:DOWN, ^os_pid, :process, ^pid, {:exit_status, 9}}, 1_000
    end
  end
end
```

Three things to notice:

- `assert_receive` always passes a timeout (commonly `1_000` ms); `assert_receive` with no timeout uses ExUnit's default 100 ms which is too short for fork/exec.
- Strict equality (`===`) is mandatory — Credo enforces this.
- The pinned variables (`^pid`, `^os_pid`) make sure messages from any concurrent test in the same node would not match.

### Streaming test pattern (dummy port pid)

From `test/elixir_exec/stream_test.exs`:

```elixir
setup do
  Process.flag(:trap_exit, true)
  :ok
end

describe ":chunks mode" do
  test "emits stdout chunks exactly as received" do
    {:ok, server, stream} = ElixirExec.Stream.start_link(:chunks)
    port_pid = spawn_dummy_port(server)

    send_stdout(server, "alpha")
    send_stdout(server, "beta")
    send(port_pid, :exit)

    assert Enum.to_list(stream) === ["alpha", "beta"]
    assert_down(server)
  end
end
```

The pattern: spawn a fake port pid the worker can monitor, feed it `:stdout`/`:stderr` messages directly, then trigger `:exit` to drive the worker through its `:DOWN` codepath without launching a real OS process. This makes streaming logic deterministic and fast.

### Pure-module unit test pattern

From `test/elixir_exec/options_test.exs`:

```elixir
defmodule ElixirExec.OptionsTest do
  use ExUnit.Case, async: true

  alias ElixirExec.Options

  describe "to_erl_command/1" do
    test "converts a binary command to a charlist" do
      assert Options.to_erl_command("echo hi") === ~c"echo hi"
    end

    test "converts a list of binaries to a list of charlists" do
      assert Options.to_erl_command(["bash", "-c", "ls"]) ===
               [~c"bash", ~c"-c", ~c"ls"]
    end
  end
end
```

One scenario per `test`. Use `describe` to group by function-under-test.

### Trap exits when linking

When testing `run_link/2` or any code that links the test process, set `Process.flag(:trap_exit, true)` in `setup` so an unexpected exit becomes a message instead of a crash.

## Doctest policy

Doctests are used in:

- `ElixirExec` (top-level public API) — every example in `@doc` blocks runs.
- `ElixirExec.Output`
- `ElixirExec.Stream.Buffer`

`BlitzCredoChecks.DoctestIndent` enforces consistent indentation. When a function's example needs side effects (mailbox, `Process.flag(:trap_exit, ...)`), don't doctest it — write a regular test.

## Coverage

Coverage tooling is configured but not gated:

- `coveralls.json` — `minimum_coverage: 0` (no enforced floor).
- `codecov.yml` — `project.target: 10%`, `patch.target: 10%`. CI failures are marked as errors.
- HTML reports filter out fully-covered files (`html_filter_full_covered: true`).
- `defdelegate` is in `custom_stop_words`, so trivial passthroughs aren't flagged as uncovered.

Treat coverage as informational unless someone wires the gates into a CI pipeline. The integration suite already exercises the full public API surface.

## Quality checks after a change

Per `RULES.md`, every code change runs through:

1. **Tests** — narrow → broad. `mix test path:line` first.
2. **Credo** — `mix credo --strict`. Strict mode is on; the BlitzCredoChecks pack is loaded.
3. **Dialyzer** — `mix dialyzer`. PLTs are cached in `dialyzer/` (committed); first run on a fresh checkout is fast.
4. **Format** — `mix format --check-formatted` before commit.

The `claude-copilot:elixir-run-checks` skill orchestrates these in order if you're using Claude Code.

## See also

- [`code-standards.md`](code-standards.md) — strict equality, `@doc`/`@spec` ordering, naming.
- [`system-architecture.md`](system-architecture.md) — what the supervision-tree and streaming tests are exercising.
- [`api-reference.md`](api-reference.md) — the contract the integration suite is verifying.
