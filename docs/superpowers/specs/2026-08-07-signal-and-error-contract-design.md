# Signal and Error Contract — Design

**Date:** 2026-08-07
**Status:** Approved, ready for implementation planning
**Follows:** `2026-08-07-exec-api-revision-design.md`, whose final review left these open.

## Problem

Four issues remained after the API revision merged. Three are defects; one is a
documentation error the revision carried forward rather than introduced.

1. **`signal/2` accepts input that destroys the program it is meant to signal.**
   `Exec.signal(program, :not_a_signal)` raises `function_clause` inside
   `Exec.Program`, whose link to erlexec's controller then kills the running
   program and exits the caller. A typo is lethal.
2. **`write/2`, `stop/1` and `signal/2` leak erlexec's terms**, and a spent handle
   leaks `:noproc`.
3. **`write/2`'s documentation is false.** It claims `{:error, reason}` when the
   program has already exited; it returns `:ok`.
4. **Signals sent immediately after `open/2` are silently lost** about nine times in
   a hundred.

Two parked findings from the previous branch are folded in: `shutdown/1`'s `catch`
covers two statements when it should cover one, and the test suite's `pgrep`
pattern matches on a prefix.

## Measured behaviour

Everything below was measured in the project's container, not inferred.

### `signal/2` today

| Call | Result |
|---|---|
| `signal(p, :sigterm)` | `:ok` |
| `signal(p, :not_a_signal)` | `function_clause` in `Exec.Program`; program killed, caller exits |
| `signal(p, "sigterm")` | same |
| `signal(p, :sigusr1)` | same — erlexec's table has no entry for it |
| `signal(p, 9999)` / `signal(p, -1)` | `{:error, :einval}` |
| `signal(p, 0)` | `:ok` |

### Error terms today

Program ended, exit event not yet read (the handle's process is still alive):

| Call | Returns |
|---|---|
| `write/2` | `:ok` — silently discarded |
| `signal/2` | `{:error, ~c"Cannot kill a pid not managed by this application"}` |
| `stop/1` | `{:error, ~c"pid not alive"}` |

Handle spent (exit read, process gone): all of `write/2`, `stop/1`, `signal/2` and
`read/2` exit the caller with `:noproc`.

### The signal-loss race

Three arms, interleaved so each sees identical conditions, 100 trials each, using
the exit event as the oracle:

| Signal | exec-port installs a handler | Catchable | Lost |
|---|---|---|---|
| `sigterm` | yes | yes | **9/100** |
| `sigquit` | no | yes | 0/100 |
| `sigkill` | no | no | 0/100 |

Interleaving matters: measuring one signal per batch produced 7/60 for `sigterm`
in one run and 0/60 in another, because the first arm of a batch runs on a cold
container. The confounded result was discarded.

`sigquit` is the control that settles the diagnosis. It is catchable, so if the
loss were about catchable signals generally it would be lost too.

**Root cause.** `exec-port` installs `sigaction` handlers for SIGINT, SIGTERM,
SIGHUP and SIGPIPE (`c_src/exec.cpp:152-155`), and that handler sets a `terminated`
flag rather than dying. A forked child inherits them until `execve` replaces the
image; the child branch restores the signal mask but never the dispositions. A
signal in those four arriving in that window is swallowed.

This is a bug in erlexec's C++, not in this library. It is reported separately —
see "Out of scope" below.

### Signal numbers are platform-specific

`erlexec`'s `signal_to_int/1` (`src/exec.erl:811`) hardcodes Linux numbers:

| Signal | erlexec | Darwin |
|---|---|---|
| `sigusr1` | 10 | 30 |
| `sigusr2` | 12 | 31 |
| `sigchld` | 17 | 20 |
| `sigcont` | 18 | 19 |
| `sigstop` | 19 | 17 |

On macOS `Exec.signal(p, :sigchld)` therefore sends signal 17 — `SIGSTOP` there.
Only numbers 1–15 are POSIX-guaranteed and identical across both platforms.

## Design

### 1. `Exec` owns the signal table

`Exec.signal/2` resolves a signal name to a number itself and passes `:exec.kill/2`
an integer, so erlexec's table is never consulted. This is the root-cause fix
rather than a guard: the `function_clause` becomes unreachable instead of merely
caught.

- Names 1–15 come from a single POSIX table.
- Names above 15 come from a per-platform table selected by `:os.type()`.
- `:sigusr1` and `:sigusr2` are supported, which erlexec does not support at all.
- An unknown name, a non-atom/non-integer, or an integer outside `0..64` raises
  `ArgumentError` **in the caller's process**, where it cannot reach the program.
  `0` stays valid: it is the POSIX existence check and currently returns `:ok`.

Raising rather than returning matches what this library already does for unknown
option keys and rejected option values. A typo is a programmer error, not a
runtime condition.

### 2. One documented error for a program that has ended

`write/2`, `stop/1` and `signal/2` return `{:error, :not_running}` once the program
has ended, whether or not its exit has been read.

`Exec.Program` gains an `exited?` flag, set when the `{:EXIT, controller, _}`
message arrives. The three calls answer from that flag without reaching erlexec,
which is what removes the charlists. `Exec.Program`'s client functions catch the
`:noproc`/`:normal` exit from a call to a departed process and return the same
reason, which is what removes the leaked `GenServer` detail.

`read/2` keeps its documented behaviour of exiting the caller on a spent handle:
that is how a read loop terminates, and turning it into a return value would make
a naive loop spin instead of crash.

This also makes `write/2`'s existing documentation true rather than requiring it to
be weakened.

### 3. A bounded resend inside the spawn window

Accepted with its limitation stated, as a temporary measure until the erlexec fix
lands.

`Exec.Program` records the monotonic time `:exec.run/2` returned. When `signal/2`
sends one of the four signals exec-port handles — `SIGHUP` (1), `SIGINT` (2),
`SIGPIPE` (13), `SIGTERM` (15), whose numbers are identical on both platforms
because all are below 16 — and the program is younger than **250 ms** and has not
exited, it schedules a check **50 ms** later and sends once more if the program is
still running.

Both figures are deliberate rather than tuned: 250 ms is far longer than any
observed `fork`-to-`execve` window and short enough that no realistic program has
begun meaningful work, and 50 ms is long enough for the `execve` to have completed
in every observed case. They are named constants so a maintainer can see and change
them.

**What this cannot do:** it cannot distinguish a signal swallowed before `execve`
from one a program deliberately ignored. A program that installs its own `SIGTERM`
handler within the window may see the signal twice. That is accepted against a
signal being lost outright roughly one time in eleven, and the code comment says so
plainly. It is removed when erlexec resets the child's dispositions.

At most one resend, only those four signals, only inside the window.

### 4. Documentation

- `write/2`: `{:error, :not_running}`, now true.
- `signal/2`: the accepted signal set, the `ArgumentError` contract, and that names
  resolve per platform.
- `stop/1`: `{:error, :not_running}`.
- All three gain an `## Errors` section.
- The moduledoc gains a section on the spawn window: which four signals can be
  lost, that `stop/1` is unaffected because it escalates to `SIGKILL`, and that the
  library resends once as a temporary measure.
- README mirrors the moduledoc.

### 5. The two parked findings

- `shutdown/1`'s `catch` covers both statements, so an exit from the inner `stop`
  skips `GenServer.stop` and silently restores the process leak the previous branch
  fixed. The `try` narrows to the `stop` call alone.
- `await_os_process/3`'s `pgrep -f "sleep #{token}"` becomes `... #{token}$`, so
  token `300.01` stops matching `300.011`.

## Testing

- `:sigusr1` sends a signal rather than killing the program.
- A typo'd name, a string, and an integer outside `0..64` each raise
  `ArgumentError`, and the program is still running afterwards.
- `write/2`, `stop/1` and `signal/2` return `{:error, :not_running}` after the
  program has exited, and again on a spent handle.
- `read/2` still exits the caller on a spent handle.
- The resend closes the spawn-window loss. This assertion is statistical, so it
  runs **100 iterations** and asserts **zero** losses rather than sampling a rate.
  At the measured loss probability of roughly 0.09, a regression that reinstated
  the loss would show up in 100 trials with probability above `1 - 0.91^100`, which
  is greater than 0.9999 — while a working resend produces zero, so a slow machine
  does not make the test flaky. The test signals with `SIGTERM` and uses the exit
  event as its oracle, never `pgrep`.

## Out of scope

- **The erlexec fix itself.** It lives in a standalone project at
  `../erlexec_signal_loss`, containing only the reproduction and the pull-request
  description, so the bug report is isolated from this library's work.
- **erlexec's incomplete and Linux-specific signal table.** Section 1 routes around
  it; the table itself is reported in that same project as a secondary finding.
- `decode_exit_reason/1`'s `other -> other` fallback still passes an unrecognised
  erlexec reason through. It is unreachable in practice and left alone.

## Success criteria

- `./docker/test` and all five other gates pass.
- No input to `signal/2` can terminate the program or exit the caller.
- No public function returns an erlexec charlist or a `GenServer` exit reason.
- Every documented return value is covered by a test.
- The spawn-window resend is annotated with the condition for its removal.
