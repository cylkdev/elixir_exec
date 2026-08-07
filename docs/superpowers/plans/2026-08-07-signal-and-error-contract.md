# Signal and Error Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `signal/2` incapable of destroying the program it signals, give `write/2`, `stop/1` and `signal/2` one documented error instead of erlexec's raw terms, and close the window in which a signal is silently lost.

**Architecture:** `Exec` is a stateless façade over one `Exec.Program` GenServer per running program. This plan moves signal-name resolution into `Exec` so erlexec's incomplete, Linux-only table is never consulted; adds an `exited?` flag to `Exec.Program` so it can answer for a finished program without calling erlexec; and adds a bounded one-shot resend for the four signals erlexec's port program can swallow.

**Tech Stack:** Elixir `~> 1.18`, ExUnit, `:erlexec ~> 2.3`, Credo (`blitz_credo_checks`), Dialyxir, ExCoveralls, ExDoc. Docker is the only test environment.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-07-signal-and-error-contract-design.md`. Read it before Task 1.
- **Docker is the only test environment.** Run everything through `./docker/test` from the repository root: `./docker/test`, `./docker/test mix credo --strict`, `./docker/test mix dialyzer`, `./docker/test mix format --check-formatted`, `./docker/test mix docs`, `./docker/test mix hex.build`. Never run `mix test` on the host. Use 900000 ms timeouts — a source change rebuilds Docker layers.
- **Baseline: 6 doctests, 52 tests, 0 failures**, with all six gates clean. All six must be clean at the end of every task.
- **Tests are written one way.** No `@tag`, no `async: false`, no environment checks, no skip conditions, no helper that behaves differently in the container. Every test is written from the caller's point of view using the public API.
- Tests use `===` for strict equality, except where a partial-struct pattern match uses `=`.
- Anything a test needs must be declared in `docker/Dockerfile`, never assumed present.
- **Never assert a measured value you have not measured.** Where this plan gives a number, it was measured on one machine; re-measure rather than trusting it, and report a difference instead of adjusting the code to fit.
- No `@doc` or `@moduledoc` may address the reader in the second person ("you", "your", "yours").
- Formatting is only *checked* in the container. If `mix format --check-formatted` fails, run `mix format` on the host, where Elixir is installed.
- Commit after every task. Do not squash tasks into one commit.

---

## File Structure

| Path | Change | Responsibility |
|---|---|---|
| `lib/exec.ex` | modify | Public façade. Gains the signal tables and `signal_number!/1`; `write/2`, `stop/1`, `signal/2` documentation |
| `lib/exec/program.ex` | modify | Per-program GenServer. Gains `exited?`, `started_at`, `resent?` state; a `call/2` wrapper that catches `:noproc`; the resend |
| `test/exec_test.exs` | modify | Whole-library suite. New `describe` blocks for signal validation and the error contract; the `pgrep` anchor fix |
| `README.md` | modify | Mirrors the moduledoc's new spawn-window section |

---

### Task 1: Fix the two findings parked from the previous branch

Both were raised by the final whole-branch review of the API revision, judged not merge-blocking, and deferred. They are independent of everything else in this plan and go first because they are small and unblock nothing.

**Files:**
- Modify: `lib/exec/program.ex` (`shutdown/1`)
- Test: `test/exec_test.exs` (`await_os_process/3`)

**Interfaces:**
- Consumes: nothing.
- Produces: no signature changes.

- [ ] **Step 1: Narrow `shutdown/1`'s `catch` to the call that can legitimately exit**

`shutdown/1` currently wraps both statements in one `catch`. If the inner `stop(conn)` ever exits — it is a `GenServer.call` with the default 5-second timeout — the `catch` swallows it and `GenServer.stop/2` never runs, silently reinstating the process leak the previous branch fixed.

In `lib/exec/program.ex`, replace the body of `shutdown/1` (leave the comment block above it unchanged):

```elixir
  def shutdown(conn) do
    # Only the stop is allowed to fail quietly. Wrapping the termination in the
    # same catch would mean a failed stop skips it, which silently restores the
    # leak this function exists to prevent.
    _ =
      try do
        stop(conn)
      catch
        :exit, _reason -> :ok
      end

    try do
      GenServer.stop(conn, :normal)
    catch
      :exit, _reason -> :ok
    end
  end
```

- [ ] **Step 2: Anchor the `pgrep` pattern in the test helper**

`unique_token/0` produces tokens like `300.01`, and `pgrep -f` matches on a substring, so `300.01` also matches another test's `300.011`. The four tests that poll for OS processes can therefore see a different test's program.

In `test/exec_test.exs`, in `await_os_process/3`, change the `pgrep` invocation to anchor at end of line:

```elixir
    {out, _status} = System.cmd("pgrep", ["-f", "sleep #{token}$"], stderr_to_stdout: true)
```

- [ ] **Step 3: Run the full suite**

Run: `./docker/test`
Expected: PASS, 6 doctests, 52 tests, 0 failures. Neither change alters behaviour that any test asserts; both remove a way for a test to observe the wrong thing.

- [ ] **Step 4: Verify the anchor actually discriminates**

```bash
./docker/test mix run -e '
  {:ok, a} = Exec.open(["sleep", "300.01"])
  {:ok, b} = Exec.open(["sleep", "300.011"])
  Process.sleep(400)
  {unanchored, _} = System.cmd("pgrep", ["-f", "sleep 300.01"])
  {anchored, _}   = System.cmd("pgrep", ["-f", "sleep 300.01$"])
  IO.puts("unanchored matched #{length(String.split(unanchored, "\n", trim: true))} process(es)")
  IO.puts("anchored matched   #{length(String.split(anchored, "\n", trim: true))} process(es)")
  Exec.stop(a); Exec.stop(b)'
```

Expected: unanchored matches 2, anchored matches 1. If both match 1, the two programs did not overlap; re-run.

- [ ] **Step 5: Commit**

```bash
./docker/test mix format --check-formatted
./docker/test mix credo --strict
git add lib/exec/program.ex test/exec_test.exs
git commit -m "fix: keep shutdown/1 terminating when its stop fails

A single catch around both statements meant an exit from the stop call
skipped GenServer.stop, silently restoring the process leak shutdown/1
exists to prevent. Also anchors the test helper's pgrep pattern, which
matched token 300.01 against another test's 300.011.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Exec` owns the signal table

Today `Exec.signal/2` hands its argument straight to `:exec.kill/2`, which calls erlexec's `signal_to_int/1`. That function raises `function_clause` on any name it does not know — **inside `Exec.Program`**, whose link to erlexec's controller then kills the running program and exits the caller. A typo destroys the thing it was meant to signal.

Measured, on the current code:

| Call | Result |
|---|---|
| `signal(p, :sigterm)` | `:ok` |
| `signal(p, :not_a_signal)` | program killed, caller exits |
| `signal(p, "sigterm")` | program killed, caller exits |
| `signal(p, :sigusr1)` | program killed, caller exits — erlexec has no entry for it |
| `signal(p, 9999)` | `{:error, :einval}` |
| `signal(p, 0)` | `:ok` |

Resolving names in `Exec` and passing `:exec.kill/2` an integer makes the crash unreachable rather than merely guarded, and fixes two further erlexec problems: its table has no `:sigusr1`/`:sigusr2`, and its numbers are Linux-only, so `:sigchld` on macOS sends signal 17, which is `SIGSTOP` there.

**Files:**
- Modify: `lib/exec.ex`
- Test: `test/exec_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Exec.signal/2` accepts a signal name atom or an integer in `0..64` and raises `ArgumentError` otherwise. `Exec.Program.kill/2` now always receives an integer. Task 4 uses the constants `1`, `2`, `13`, `15` for `SIGHUP`, `SIGINT`, `SIGPIPE`, `SIGTERM`.

- [ ] **Step 1: Verify the signal numbers before writing them down**

The tables below were measured on one Linux container and one macOS host. Verify both yourself and use what you observe. Include **only** entries you have verified on both platforms; drop any you cannot confirm rather than guessing.

Linux, in the container:

```bash
./docker/test sh -c 'kill -l | tr " " "\n" | cat -n' 2>/dev/null | head -40
```

macOS, on the host:

```bash
python3 -c "
import signal
for s in ['SIGHUP','SIGINT','SIGQUIT','SIGILL','SIGTRAP','SIGABRT','SIGFPE','SIGKILL','SIGSEGV','SIGPIPE','SIGALRM','SIGTERM','SIGUSR1','SIGUSR2','SIGCHLD','SIGCONT','SIGSTOP','SIGTSTP','SIGWINCH']:
    print(f'{s:10} {getattr(signal, s).value}')"
```

Expected, from my measurement — confirm or correct:

| Name | Linux | Darwin |
|---|---|---|
| `sighup` … `sigterm` (1–15) | identical | identical |
| `sigusr1` | 10 | 30 |
| `sigusr2` | 12 | 31 |
| `sigchld` | 17 | 20 |
| `sigcont` | 18 | 19 |
| `sigstop` | 19 | 17 |
| `sigtstp` | 20 | 18 |
| `sigwinch` | 28 | 28 |

- [ ] **Step 2: Write the failing tests**

Add a new `describe` block to `test/exec_test.exs`, after `describe "stop/1 and signal/2"`:

```elixir
  describe "signal/2 argument handling" do
    test "sends a signal erlexec's own table does not know" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])

      assert await_os_process(token, :present)
      assert Exec.signal(program, :sigusr1) === :ok
      assert await_os_process(token, :absent)
    end

    test "an unknown signal name raises and leaves the program running" do
      token = unique_token()
      {:ok, program} = Exec.open(["sleep", token])

      assert await_os_process(token, :present)

      assert_raise ArgumentError, ~r/unknown signal :not_a_signal/, fn ->
        Exec.signal(program, :not_a_signal)
      end

      assert await_os_process(token, :present)
      assert Exec.stop(program) === :ok
    end

    test "a signal that is neither a name nor an integer raises" do
      {:ok, program} = Exec.open(["sleep", unique_token()])

      assert_raise ArgumentError, ~r/signal must be/, fn ->
        Exec.signal(program, "sigterm")
      end

      assert Exec.stop(program) === :ok
    end

    test "an integer outside the signal range raises" do
      {:ok, program} = Exec.open(["sleep", unique_token()])

      assert_raise ArgumentError, ~r/signal must be/, fn -> Exec.signal(program, 9999) end
      assert_raise ArgumentError, ~r/signal must be/, fn -> Exec.signal(program, -1) end

      assert Exec.stop(program) === :ok
    end

    test "signal 0 is accepted, since it asks whether the program exists" do
      {:ok, program} = Exec.open(["sleep", unique_token()])

      assert Exec.signal(program, 0) === :ok
      assert Exec.stop(program) === :ok
    end
  end
```

- [ ] **Step 3: Run them and confirm they fail**

Run: `./docker/test mix test test/exec_test.exs`
Expected: FAIL. The `:sigusr1` and `:not_a_signal` tests fail by killing their program and exiting the test process; the range tests fail because `9999` returns `{:error, :einval}` rather than raising.

- [ ] **Step 4: Add the tables and the resolver to `lib/exec.ex`**

Place these module attributes immediately after `@forwarded_options`, and the private functions with the other private functions at the bottom of the file:

```elixir
  # Signal numbers are POSIX-guaranteed only for 1..15. Above that they are
  # platform-assigned: SIGUSR1 is 10 on Linux and 30 on Darwin, SIGCHLD 17 and
  # 20, SIGSTOP 19 and 17.
  #
  # erlexec's own table (exec.erl:811) hardcodes the Linux numbers, so asking it
  # to translate :sigchld on a Mac sends signal 17 -- SIGSTOP there. It also has
  # no entry at all for :sigusr1 or :sigusr2, the two signals conventionally
  # reserved for application use, and raises function_clause on any name it does
  # not know. That raise happens inside Exec.Program, whose link to erlexec's
  # controller then kills the running program: a typo destroys the thing it was
  # meant to signal.
  #
  # Resolving names here and passing :exec.kill/2 an integer means erlexec's
  # table is never consulted and that crash is unreachable.
  @signals_posix %{
    sighup: 1,
    sigint: 2,
    sigquit: 3,
    sigill: 4,
    sigtrap: 5,
    sigabrt: 6,
    sigfpe: 8,
    sigkill: 9,
    sigsegv: 11,
    sigpipe: 13,
    sigalrm: 14,
    sigterm: 15
  }

  @signals_linux %{
    sigusr1: 10,
    sigusr2: 12,
    sigchld: 17,
    sigcont: 18,
    sigstop: 19,
    sigtstp: 20,
    sigwinch: 28
  }

  @signals_darwin %{
    sigusr1: 30,
    sigusr2: 31,
    sigchld: 20,
    sigcont: 19,
    sigstop: 17,
    sigtstp: 18,
    sigwinch: 28
  }
```

```elixir
  defp signal_table do
    case :os.type() do
      {:unix, :darwin} -> Map.merge(@signals_posix, @signals_darwin)
      {:unix, _} -> Map.merge(@signals_posix, @signals_linux)
    end
  end

  defp signal_number!(number) when is_integer(number) and number in 0..64, do: number

  defp signal_number!(name) when is_atom(name) do
    case Map.fetch(signal_table(), name) do
      {:ok, number} ->
        number

      :error ->
        raise ArgumentError, "unknown signal #{inspect(name)}"
    end
  end

  defp signal_number!(other) do
    raise ArgumentError,
          "signal must be a signal name or an integer in 0..64, got: #{inspect(other)}"
  end
```

- [ ] **Step 5: Route `signal/2` through the resolver**

Replace `lib/exec.ex:296-297`:

```elixir
  @spec signal(t(), atom() | non_neg_integer()) :: :ok | {:error, term()}
  def signal(program, signal), do: Program.kill(program, signal_number!(signal))
```

Note the `@spec` narrows from `integer()` to `non_neg_integer()`. Its `{:error, term()}` is replaced in Task 3.

- [ ] **Step 6: Run the tests**

Run: `./docker/test mix test test/exec_test.exs`
Expected: PASS, 6 doctests, 57 tests, 0 failures.

- [ ] **Step 7: Confirm the resolver runs in the caller's process**

The whole point is that a bad argument cannot reach `Exec.Program`. Prove it:

```bash
./docker/test mix run -e '
  {:ok, p} = Exec.open(["sleep", "300.55"])
  Process.sleep(300)
  try do
    Exec.signal(p, :nope)
  rescue
    ArgumentError -> IO.puts("raised in the caller")
  end
  IO.puts("program process alive: #{Process.alive?(p)}")
  IO.puts("read still works: #{inspect(Exec.read(p, 0))}")
  Exec.stop(p)'
```

Expected: `raised in the caller`, `program process alive: true`, and `read still works: {:error, :timeout}` — the program is untouched.

- [ ] **Step 8: Commit**

```bash
./docker/test mix format --check-formatted
./docker/test mix credo --strict
./docker/test mix dialyzer
git add lib/exec.ex test/exec_test.exs
git commit -m "fix!: resolve signal names in Exec instead of erlexec

erlexec's signal_to_int/1 raises function_clause on any name it does not
know, inside Exec.Program, whose link to the controller then kills the
running program -- so Exec.signal(p, :typo) destroyed the program and
exited the caller. Its table also lacks :sigusr1 and :sigusr2 entirely and
hardcodes Linux numbers, so :sigchld on macOS sent SIGSTOP.

Exec now resolves names against a per-platform table and passes
:exec.kill/2 an integer, making the crash unreachable rather than caught.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: One documented error for a program that has ended

Measured on the current code, with the program ended but its exit not yet read — the handle's process is still alive, holding the queued exit event:

| Call | Returns |
|---|---|
| `write/2` | `:ok`, silently discarded |
| `signal/2` | `{:error, ~c"Cannot kill a pid not managed by this application"}` |
| `stop/1` | `{:error, ~c"pid not alive"}` |

And on a spent handle, where the exit has been read and the process has stopped, all three exit the caller with `:noproc`.

All of these become `{:error, :not_running}`. `read/2` keeps exiting the caller on a spent handle: that is how a read loop terminates, and returning instead would make a naive loop spin rather than crash.

**Files:**
- Modify: `lib/exec/program.ex`, `lib/exec.ex`
- Test: `test/exec_test.exs`

**Interfaces:**
- Consumes: `Exec.signal/2` from Task 2.
- Produces: `Exec.write/2`, `Exec.stop/1` and `Exec.signal/2` return `:ok | {:error, :not_running}`. `Exec.Program`'s state map gains `exited?: boolean()`. Task 4 adds `started_at` and `resent?` to the same map.

- [ ] **Step 1: Write the failing tests**

Add to `test/exec_test.exs`, after the `describe "signal/2 argument handling"` block from Task 2:

```elixir
  describe "a program that has ended" do
    test "write/2, stop/1 and signal/2 report it, with the exit still unread" do
      {:ok, program} = Exec.open("echo hi")

      # Wait for the exit to reach the handle without reading it, so the handle
      # is still alive and holding the queued events.
      Process.sleep(500)

      assert Exec.write(program, "x") === {:error, :not_running}
      assert Exec.stop(program) === {:error, :not_running}
      assert Exec.signal(program, :sigterm) === {:error, :not_running}
    end

    test "the queued output is still readable afterwards" do
      {:ok, program} = Exec.open("echo hi")
      Process.sleep(500)

      assert Exec.write(program, "x") === {:error, :not_running}

      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
      assert Exec.read(program) === {:ok, {:exit, 0}}
    end

    test "write/2, stop/1 and signal/2 report it on a spent handle" do
      {:ok, program} = Exec.open("echo hi")
      assert Exec.read(program) === {:ok, {:stdout, "hi\n"}}
      assert Exec.read(program) === {:ok, {:exit, 0}}

      assert Exec.write(program, "x") === {:error, :not_running}
      assert Exec.stop(program) === {:error, :not_running}
      assert Exec.signal(program, :sigterm) === {:error, :not_running}
    end
  end
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `./docker/test mix test test/exec_test.exs`
Expected: FAIL. The first test gets `:ok` from `write/2` and charlist errors from `stop/1` and `signal/2`; the third exits the test process with `:noproc`.

- [ ] **Step 3: Track that the program has ended, in `lib/exec/program.ex`**

Add `exited?: false` to the state map returned by `init/1`:

```elixir
        {:ok,
         %{
           os_pid: os_pid,
           owner_ref: Process.monitor(owner),
           events: :queue.new(),
           reader: nil,
           exited?: false
         }}
```

Set it where the program's exit arrives. Replace the `{:EXIT, ...}` handler's body:

```elixir
  def handle_info({:EXIT, _controller, reason}, state) do
    deliver_or_queue(%{state | exited?: true}, {:exit, decode_exit_reason(reason)})
  end
```

- [ ] **Step 4: Answer from the flag instead of calling erlexec**

Add these three clauses to `lib/exec/program.ex` **immediately before** the existing `handle_call({:write, :eof}, ...)` clause. Order matters: they must precede the clauses they shadow, and they must not match `{:read, _}`, which stays valid after the program ends because the queued events are still there.

```elixir
  # The program has ended, but this process is still alive because its exit has
  # not been read yet. erlexec answers these three with charlist messages of its
  # own ("pid not alive", "Cannot kill a pid not managed by this application"),
  # and :exec.send/2 quietly accepts a write nobody will ever receive. One
  # documented reason is more use than either.
  def handle_call({:write, _data}, _from, %{exited?: true} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:stop, _from, %{exited?: true} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:kill, _signal}, _from, %{exited?: true} = state) do
    {:reply, {:error, :not_running}, state}
  end
```

- [ ] **Step 5: Turn a departed process into the same reason**

A handle whose exit has been read has no process behind it, and `GenServer.call/2` exits the caller with `:noproc` — an implementation detail the caller never asked about.

In `lib/exec/program.ex`, route the three client functions through a wrapper. Replace the existing `write/2`, `stop/1` and `kill/2` definitions:

```elixir
  def write(conn, data), do: call(conn, {:write, data})

  def stop(conn), do: call(conn, :stop)

  def kill(conn, signal), do: call(conn, {:kill, signal})

  # A handle is spent once its exit has been read: this process stops itself on
  # that read, so a later call finds nothing there. GenServer.call exits the
  # caller with :noproc, which says more about how this is built than about what
  # happened. To a caller it means the same as a program that has ended.
  #
  # read/2 deliberately does not go through here. Its exit is how a read loop
  # terminates, and returning a value instead would make a naive loop spin.
  defp call(conn, message) do
    GenServer.call(conn, message)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] -> {:error, :not_running}
  end
```

`read/2` keeps calling `GenServer.call/3` directly, unchanged.

- [ ] **Step 6: Narrow the specs in `lib/exec.ex`**

```elixir
  @spec write(t(), iodata() | :eof) :: :ok | {:error, :not_running}
```

```elixir
  @spec stop(t()) :: :ok | {:error, :not_running}
```

```elixir
  @spec signal(t(), atom() | non_neg_integer()) :: :ok | {:error, :not_running}
```

- [ ] **Step 7: Run the tests**

Run: `./docker/test`
Expected: PASS, 6 doctests, 60 tests, 0 failures.

Note that `shutdown/1` calls `stop/1`, which now returns `{:error, :not_running}` rather than exiting when the process has gone. Its own `try` still handles the exit case; nothing there needs changing.

- [ ] **Step 8: Confirm no charlist can still reach a caller**

```bash
./docker/test mix run -e '
  {:ok, p} = Exec.open("echo hi")
  Process.sleep(500)
  for {label, result} <- [write: Exec.write(p, "x"), stop: Exec.stop(p), signal: Exec.signal(p, :sigterm)] do
    IO.puts("#{label}: #{inspect(result)}")
  end'
```

Expected: all three print `{:error, :not_running}`. Any `~c"..."` in the output means a path was missed.

- [ ] **Step 9: Commit**

```bash
./docker/test mix format --check-formatted
./docker/test mix credo --strict
./docker/test mix dialyzer
git add lib/exec.ex lib/exec/program.ex test/exec_test.exs
git commit -m "feat!: report {:error, :not_running} for a program that has ended

write/2 silently accepted writes nobody would receive; stop/1 and signal/2
returned erlexec's charlist messages; and all three exited the caller with
:noproc once the handle was spent. read/2 keeps its documented exit, which
is how a read loop terminates.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Resend a signal lost in the spawn window

`exec-port` installs `sigaction` handlers for `SIGINT`, `SIGTERM`, `SIGHUP` and `SIGPIPE` (`deps/erlexec/c_src/exec.cpp:152-155`), and that handler sets a flag rather than terminating. A forked child inherits those handlers until `execve` replaces the image; the child branch restores the signal mask but never the dispositions. A signal in those four arriving in that window is swallowed and never reaches the program.

Measured with three arms interleaved so each sees identical conditions, 100 trials each, using the exit event as the oracle:

| Signal | exec-port installs a handler | Catchable | Lost |
|---|---|---|---|
| `sigterm` | yes | yes | 9/100 |
| `sigquit` | no | yes | 0/100 |
| `sigkill` | no | no | 0/100 |

`sigquit` is the control that makes the diagnosis conclusive: it is catchable, so if the loss were about catchable signals generally it would be lost too.

**The window is narrow but almost certain while it is open**, and much more reliably hit on macOS than on Linux. Measured on a macOS host, varying only the delay between starting the program and signalling it:

| Signal sent after | Lost |
|---|---|
| 0 ms | 36/40 |
| 5 ms | 0/40 |
| 10 ms | 0/40 |
| 25 ms and beyond | 0/40 |

This is what justifies `@resend_after_ms` below. The window closes within 5 ms on that machine, so a recheck at 50 ms sits an order of magnitude clear of it, on both platforms. Confirm the shape of this on the machine you are working on before relying on the constant — if the window turns out to extend past 50 ms anywhere, the resend would land inside it and accomplish nothing.

This is a defect in erlexec's C++, reported separately in the standalone project at `../erlexec_signal_loss`, which reproduces it on both Linux (8/100) and macOS (99/100). This task adds a bounded workaround here until that fix lands.

**Files:**
- Modify: `lib/exec/program.ex`
- Test: `test/exec_test.exs`

**Interfaces:**
- Consumes: `exited?` from Task 3; integer signals from Task 2.
- Produces: `Exec.Program`'s state map gains `started_at: integer()` and `resent?: boolean()`. No public signature changes.

- [ ] **Step 1: Reproduce the loss before fixing it**

Do not take the numbers above on trust — the effect is timing-sensitive.

```bash
./docker/test mix run -e '
  arms = [:sigterm, :sigquit, :sigkill]
  res = Enum.reduce(1..150, Map.new(arms, &{&1, %{}}), fn i, acc ->
    sig = Enum.at(arms, rem(i, 3))
    {:ok, p} = Exec.open(["sleep", "300.#{:erlang.unique_integer([:positive])}"])
    :ok = Exec.signal(p, sig)
    ev = case Exec.read(p, 3000) do
      {:ok, {:exit, _}} -> :delivered
      {:error, :timeout} -> :LOST
    end
    update_in(acc, [sig], &Map.update(&1, ev, 1, fn n -> n + 1 end))
  end)
  for a <- arms, do: IO.puts("#{a}: #{inspect(res[a])}")'
```

Expected: `sigterm` shows some losses; `sigquit` and `sigkill` show none. Record the counts in your report.

If `sigterm` shows **zero** losses, stop and report it: the window may be too narrow to hit on this machine, and the rest of this task would be adding a workaround for something you cannot demonstrate.

- [ ] **Step 2: Write the failing test**

Add to `test/exec_test.exs`, after the `describe "a program that has ended"` block:

```elixir
  describe "signals sent immediately after open/2" do
    # erlexec's port program installs handlers for SIGHUP, SIGINT, SIGPIPE and
    # SIGTERM, and a forked child inherits them until execve replaces the image.
    # A signal in those four sent in that window is swallowed. Measured at
    # roughly nine losses in a hundred before the resend below.
    #
    # 100 iterations asserting zero losses, rather than sampling a rate: at a
    # loss probability of 0.09 a regression appears with probability above
    # 1 - 0.91^100, which is greater than 0.9999, while a working resend gives
    # zero on any machine.
    test "are not lost" do
      losses =
        Enum.count(1..100, fn _ ->
          {:ok, program} = Exec.open(["sleep", unique_token()])
          :ok = Exec.signal(program, :sigterm)

          case Exec.read(program, 3000) do
            {:ok, {:exit, _}} -> false
            {:error, :timeout} -> true
          end
        end)

      assert losses === 0
    end
  end
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `./docker/test mix test test/exec_test.exs`
Expected: FAIL, with `losses` a small non-zero number matching roughly what Step 1 measured.

- [ ] **Step 4: Add the resend to `lib/exec/program.ex`**

Add the module attributes near the top, with the other module-level definitions:

```elixir
  # The four signals exec-port installs a handler for (exec.cpp:152-155). Their
  # numbers are identical on Linux and Darwin because all four are below 16,
  # which is where POSIX stops guaranteeing them.
  @swallowable_signals [1, 2, 13, 15]

  # Far longer than any observed fork-to-execve window, and short enough that no
  # realistic program has begun meaningful work.
  @spawn_window_ms 250

  # Long enough for the execve to have completed in every observed case.
  @resend_after_ms 50
```

Add `started_at` and `resent?` to `init/1`'s state map, alongside `exited?` from Task 3:

```elixir
        {:ok,
         %{
           os_pid: os_pid,
           owner_ref: Process.monitor(owner),
           events: :queue.new(),
           reader: nil,
           exited?: false,
           started_at: System.monotonic_time(:millisecond),
           resent?: false
         }}
```

Replace the existing `handle_call({:kill, signal}, ...)` clause — the one that runs when `exited?` is `false`, below the Task 3 clause:

```elixir
  def handle_call({:kill, signal}, _from, state) do
    {:reply, :exec.kill(state.os_pid, signal), schedule_resend(state, signal)}
  end
```

Add the resend logic with the other private functions:

```elixir
  # A signal swallowed in the fork-to-execve window never reached the program, so
  # sending it once more is the difference between the caller's instruction being
  # carried out and being silently dropped.
  #
  # This cannot tell a swallowed signal from one the program deliberately
  # ignored. A program that installs its own handler for one of these four within 250ms
  # of starting may therefore see it twice. That is
  # accepted against a signal being lost outright roughly one time in eleven.
  #
  # Delete this once erlexec resets the child's signal dispositions before
  # execve; the reproduction and the proposed fix are in ../erlexec_signal_loss.
  defp schedule_resend(%{resent?: false} = state, signal)
       when signal in @swallowable_signals do
    if System.monotonic_time(:millisecond) - state.started_at <= @spawn_window_ms do
      Process.send_after(self(), {:resend, signal}, @resend_after_ms)
      %{state | resent?: true}
    else
      state
    end
  end

  defp schedule_resend(state, _signal), do: state
```

And the handler for the scheduled check, with the other `handle_info/2` clauses:

```elixir
  # The program is still running 50ms after a signal that
  # exec-port's inherited handler may have swallowed. Send it once more.
  def handle_info({:resend, signal}, %{exited?: false} = state) do
    _ = :exec.kill(state.os_pid, signal)
    {:noreply, state}
  end

  # It exited in the meantime, so the first signal landed.
  def handle_info({:resend, _signal}, state), do: {:noreply, state}
```

- [ ] **Step 5: Run the tests**

Run: `./docker/test`
Expected: PASS, 6 doctests, 61 tests, 0 failures.

- [ ] **Step 6: Confirm the resend does not fire outside the window**

A signal sent to a long-established program must be sent exactly once.

```bash
./docker/test mix run -e '
  {:ok, p} = Exec.open("/usr/local/fixtures/ignores-sigterm", kill_timeout: 1)
  {:ok, {:stdout, "ready\n"}} = Exec.read(p)
  Process.sleep(600)
  IO.puts("signal well after the window: #{inspect(Exec.signal(p, :sigterm))}")
  IO.puts("still running (it ignores SIGTERM): #{inspect(Exec.read(p, 500))}")
  Exec.signal(p, :sigkill)'
```

Expected: `:ok`, then `{:error, :timeout}` — the program ignores `SIGTERM` and is not disturbed. The `600`ms wait exceeds `@spawn_window_ms`, so no resend is scheduled.

- [ ] **Step 7: Commit**

```bash
./docker/test mix format --check-formatted
./docker/test mix credo --strict
./docker/test mix dialyzer
git add lib/exec/program.ex test/exec_test.exs
git commit -m "fix: resend a signal lost in the spawn window

exec-port installs handlers for SIGHUP, SIGINT, SIGPIPE and SIGTERM, and a
forked child inherits them until execve. A signal in those four sent in
that window is swallowed -- measured at 9 losses in 100, while SIGQUIT and
SIGKILL, which exec-port does not handle, were never lost.

Bounded workaround: at most one resend, only those four signals, only
within 250ms of the program starting. Removed once erlexec resets the
child's dispositions -- see ../erlexec_signal_loss.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Documentation

Three `@doc`s now describe behaviour the code no longer has, and one — `write/2`'s — was false before this plan began.

**Files:**
- Modify: `lib/exec.ex` (three `@doc`s and the `@moduledoc`)
- Modify: `README.md`

**Interfaces:**
- Consumes: the final behaviour from Tasks 2, 3 and 4.
- Produces: no code change.

- [ ] **Step 1: Replace `write/2`'s `@doc`**

Its current claim — "Returns `{:error, reason}` if the program has already exited" — was false when written: the call returned `:ok`. Task 3 made the claim true, and this states it precisely.

```elixir
  @doc """
  Writes `data` to the standard input of `program`, or closes it with `:eof`.

  A program started with `stdin: false` accepts the write and discards it.

  ## Examples

      :ok = Exec.write(program, "hello\\n")
      :ok = Exec.write(program, :eof)

  ## Errors

    * `{:error, :not_running}` - the program has ended. Any output it produced
      before ending is still readable with `read/2`.
  """
```

- [ ] **Step 2: Replace `stop/1`'s `@doc`**

```elixir
  @doc """
  Ends `program` gracefully.

  Sends `SIGTERM` and escalates to `SIGKILL` after roughly five seconds, so a
  program that ignores `SIGTERM` can take that long to end. The `:kill_timeout`
  option changes that delay. `signal/2` with `:sigkill` ends it immediately.

  A program stopped this way reports exit status `0`, not a signal.

  ## Errors

    * `{:error, :not_running}` - the program had already ended.
  """
```

- [ ] **Step 3: Replace `signal/2`'s `@doc`**

```elixir
  @doc """
  Sends `signal` to `program`.

  `signal` is a name such as `:sigterm`, `:sigkill` or `:sigusr1`, or the
  integer number. Names are resolved for the current operating system, because
  only signals 1 to 15 have numbers POSIX guarantees: `:sigusr1` is 10 on Linux
  and 30 on Darwin.

  Unlike `stop/1` nothing is escalated: exactly one signal is sent, to the
  program's whole process group.

  ## Examples

      :ok = Exec.signal(program, :sigkill)
      :ok = Exec.signal(program, 9)

  ## Errors

    * `{:error, :not_running}` - the program had already ended.

  Raises `ArgumentError` for a name that is not a known signal, for an integer
  outside `0..64`, and for anything that is neither. Signal `0` is accepted: it
  sends nothing and asks whether the program exists.
  """
```

- [ ] **Step 4: Add the spawn-window section to the `@moduledoc`**

Insert immediately after the `## Exit status` section and before `## Failure to launch`:

```
  ## Signals sent immediately after starting

  `SIGHUP`, `SIGINT`, `SIGPIPE` and `SIGTERM` can be lost if they are sent in
  the moment between a program being created and its beginning to run. The
  runner's own port program installs handlers for those four, and a newly
  created program inherits them until it replaces itself with the command being
  run, so a signal arriving in that gap is absorbed by an inherited handler
  instead of reaching the program.

  This module sends such a signal a second time, once, if the program is still
  running shortly afterwards. A program that installs its own handler for one of
  those four signals within the first quarter-second may therefore observe it
  twice.

  `stop/1` is unaffected: it escalates to `SIGKILL`, which cannot be absorbed by
  any handler. Signals outside those four are unaffected for the same reason.
```

- [ ] **Step 5: Update `README.md`**

Find the `### Process groups and exit status` section. Immediately after it, add a section mirroring the moduledoc's, in the README's voice, naming the same four signals and the same one-resend behaviour. Then check the whole README for anything Tasks 2 and 3 falsified — in particular any example showing `signal/2` or `stop/1` returning something other than `:ok` or `{:error, :not_running}`.

- [ ] **Step 6: Check the voice and the references**

```bash
grep -nE '\byou\b|\byour\b|\byours\b' README.md lib/exec.ex
./docker/test mix docs
```
Expected: no grep matches; `mix docs` completes with no warnings about broken references.

- [ ] **Step 7: Full verification**

```bash
./docker/test
./docker/test mix format --check-formatted
./docker/test mix credo --strict
./docker/test mix dialyzer
./docker/test mix docs
./docker/test mix hex.build
```
Expected: all pass, 6 doctests, 61 tests, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/exec.ex README.md
git commit -m "docs: describe the signal contract and the spawn window

write/2's documented {:error, reason} on an ended program was false when
written -- the call returned :ok. It is now true, as {:error, :not_running}.
Adds signal/2's accepted set and its ArgumentError contract, and a section
on the four signals that can be lost immediately after a program starts.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

Spec coverage:

| Spec section | Task |
|---|---|
| 1. `Exec` owns the signal table | 2 |
| 2. One documented error for a program that has ended | 3 |
| 3. A bounded resend inside the spawn window | 4 |
| 4. Documentation | 5 |
| 5. The two parked findings | 1 |
| Testing: `:sigusr1`, bad names, bad integers | 2 |
| Testing: `:not_running` after exit and on a spent handle | 3 |
| Testing: `read/2` still exits on a spent handle | 3, Step 1 — covered by the existing suite, which asserts it today |
| Testing: the resend, 100 iterations, zero losses | 4 |
| Out of scope: the erlexec fix, its signal table, `decode_exit_reason/1`'s fallback | not implemented, by design |

Test-count arithmetic: baseline 52 → Task 2 adds 5 (57) → Task 3 adds 3 (60) → Task 4 adds 1 (61). Task 1 and Task 5 add none.

Two things to watch during execution:

1. **Task 2's tables are the plan's only unverified content.** Step 1 exists to verify them, and says to drop entries rather than guess. Every other number in this plan was measured.
2. **Task 4 depends on reproducing a timing-sensitive effect.** Step 1 makes reproduction a precondition and says to stop if the loss cannot be demonstrated, rather than adding a workaround for something invisible on the machine at hand.
