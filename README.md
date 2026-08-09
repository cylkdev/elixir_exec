# elixir_exec

An idiomatic Elixir wrapper for [`erlexec`](https://hex.pm/packages/erlexec) — run and control operating system processes from Elixir.

`:erlexec` does the work of starting programs and reaping them; `elixir_exec` puts an Elixir-shaped surface on it. The public module is `Exec`: a command is a binary or a list of binaries, output arrives as `{:stdout, data}` and `{:stderr, data}` events read on demand rather than as unsolicited mailbox messages, and a program never outlives the process that started it.

## Installation

Add `:elixir_exec` to the `deps/0` function in the consuming project's `mix.exs`:

```elixir
def deps do
  [
    {:elixir_exec, "~> 0.1.0"}
  ]
end
```

`:erlexec` is an ordinary dependency. It starts itself and supervises its own `exec` process, so a Mix project needs no further setup.

**Requirements:** Elixir `~> 1.18`. `:erlexec` compiles a small port binary, `exec-port`, during `mix deps.compile`, so the machine performing that compile needs a C and C++ toolchain — `cc`, `c++` and `make`.

**The `SHELL` environment variable must be set to a non-empty value** in the environment of the Erlang VM, or `:erlexec` does not start at all. `exec-port` reads `SHELL` on startup and exits with status 4 when the variable is missing or empty (`deps/erlexec/c_src/exec.cpp:626`). The resulting crash report names neither `elixir_exec` nor the calling application, so the cause is not obvious from the failure. systemd units, container images and cron jobs are the environments where this bites: none of the three sets `SHELL` for the processes it starts. A systemd unit needs `Environment=SHELL=/bin/sh`, a Dockerfile needs `ENV SHELL=/bin/sh`, and a crontab needs a `SHELL=/bin/sh` line.

This requirement is **not** about which shell interprets a binary command. `elixir_exec` names `/bin/sh` itself when it builds the command, and never consults `SHELL` to decide anything. Setting `SHELL` to `bash`, `zsh` or `fish` does not change how any command behaves; it only satisfies the check that `exec-port` performs before it will run.

## Quick start

`Exec` has three entry points, in increasing order of control.

### Run a command to completion

`Exec.run/2` runs a command, collects everything it printed, and returns an `Exec.Result` struct whose `:stdout` and `:stderr` fields are binaries:

```elixir
iex> Exec.run("echo hi")
{:ok, %Exec.Result{stdout: "hi\n", stderr: "", exit_status: 0}}
```

A non-zero exit is an outcome, not an error — `grep` finding no match exits `1` — so a command that ran and failed still returns `{:ok, %Exec.Result{}}`, with the code in the `:exit_status` field:

```elixir
iex> {:ok, result} = Exec.run("exit 3")
iex> result.exit_status
3
```

The `:timeout` option bounds the whole call in milliseconds, rather than the gap between two chunks of output, so a command that prints continuously still times out. When the timeout expires the program is stopped and `{:error, :timeout}` is returned:

```elixir
iex> Exec.run("sleep 30", timeout: 200)
{:error, :timeout}
```

### Stream a command's output

`Exec.stream/2` returns a lazy stream of lines, for a command that runs for a long time or prints more than the calling process should hold in memory at once:

```elixir
iex> ~S(printf 'a\nb\n') |> Exec.stream() |> Enum.to_list()
[:start, {:ok, {:stdout, "a\n"}}, {:ok, {:stdout, "b\n"}}, {:ok, {:exit, 0}}, :end]
```

Every enumeration is framed: `:start` first, `:end` last, the program's output as `{:ok, event}` in between, and any failure as `{:error, reason}`. A consumer can therefore tell a command that ended from one that never started, and a stream that ran out from one that was cut short, without inspecting the program itself:

```elixir
Exec.stream("mix test")
|> Enum.each(fn
  :start -> Logger.info("started")
  {:ok, {:stdout, line}} -> Logger.info(line)
  {:ok, {:stderr, line}} -> Logger.warning(line)
  {:ok, {:exit, status}} -> Logger.info("exited #{inspect(status)}")
  {:error, reason} -> Logger.error("failed: #{inspect(reason)}")
  :end -> Logger.info("done")
end)
```

Each line keeps its trailing newline, and a last line that has none is emitted as it stands, ahead of the frame that ends the stream. Standard output is in order and standard error is in order, but the two are not ordered relative to each other.

Nothing runs until enumeration begins, so a stream that is built and never enumerated starts no program.

A failure ends the stream: `{:error, reason}` is followed by `:end` and nothing else. It carries the same reasons `Exec.run/2` returns, including `:timeout` — `:timeout` bounds a whole enumeration, measured from when it begins, and defaults to five minutes here as it does for `Exec.run/2`. A stream meant to outlive that passes `:infinity`:

```elixir
"tail -f /var/log/system.log"
|> Exec.stream(timeout: :infinity)
|> Stream.filter(&match?({:ok, {:stdout, _}}, &1))
|> Enum.take(5)
```

Halting the enumeration early — through `Enum.take/2`, an `Enum.reduce_while/3` halt, or an exception raised by the consumer — stops the program, and the frames after the halt are not emitted. A consumer that halted knows it halted; the absent `:end` says so to anyone further down the pipeline.

`Exec.run/2` is this stream consumed eagerly: it folds the frames into an `Exec.Result` rather than handing them to the caller one at a time. There is one reading loop underneath both, so anything true of one is true of the other.

### Start a command and control it

`Exec.open/2` starts a command and returns a handle. The handle is the argument to `Exec.read/2`, `Exec.write/2`, `Exec.stop/1` and `Exec.signal/2`. Output is held until `Exec.read/2` asks for it, so no output reaches the mailbox of the calling process and none is lost between two reads:

```elixir
{:ok, program} = Exec.open("cat")

Exec.write(program, "hello\n")
{:ok, {:stdout, "hello\n"}} = Exec.read(program)

Exec.write(program, :eof)
{:ok, {:exit, 0}} = Exec.read(program)
```

`Exec.read/2` blocks until an event arrives or until its timeout, given in milliseconds, expires. That timeout defaults to `:infinity`, and a read that expires leaves the program running:

```elixir
{:error, :timeout} = Exec.read(program, 0)
```

`{:ok, {:exit, status}}` is the last event a program produces. The handle is spent once that event has been read, and reading from a spent handle exits the calling process.

`Exec.stop/1` sends `SIGTERM` and escalates to `SIGKILL` after roughly five seconds, so a program that ignores `SIGTERM` can take that long to end; the `:kill_timeout` option changes that delay. `Exec.signal/2` escalates nothing — the signal sent is the signal asked for and never a different one — so `Exec.signal(program, :sigkill)` ends a program immediately. It is not always sent exactly once: `SIGHUP`, `SIGINT`, `SIGPIPE` and `SIGTERM` are sent again while the program is still running inside the first 250 milliseconds of its life, for the reason given under [Signals sent immediately after starting](#signals-sent-immediately-after-starting):

```elixir
{:ok, program} = Exec.open("tail -f /var/log/system.log")
{:ok, {:stdout, _line}} = Exec.read(program)
Exec.stop(program)
```

## Command forms and shell safety

A command is either a binary or a list of binaries, and the two are run in different ways:

```elixir
Exec.run("ls -l | wc -l")   # run as /bin/sh -c "ls -l | wc -l"
Exec.run(["ls", "-l"])      # passed to execve, with no shell involved
```

A binary command is handed to `/bin/sh -c`, which is what performs `PATH` lookup, glob expansion, variable substitution, pipes and redirection. `/bin/sh` is named by this library rather than read from the `SHELL` environment variable, so a binary command is interpreted by the same shell on every machine.

A list command is passed to `execve` directly. No shell reads it, so no character in it is special: a pipe symbol, a dollar sign or a space inside an element is an ordinary character of an argument. A bare executable name in list form, one containing no `/`, is resolved against `PATH` before the call, so `["echo", "hi"]` finds the same program that `"echo hi"` does. A name containing `/` is used exactly as written, and a bare name that resolves to nothing is passed through unchanged so that the operating system reports the real failure.

> ⚠ A binary command is interpreted by a shell, so a binary command must never be built from untrusted input. `Exec.run("cat #{user_input}")` runs whatever `user_input` says, including `"x; rm -rf /"`. Use the list form whenever any part of a command comes from outside the application.

### Failure to launch

A missing executable, a permission failure and a `:cd` directory that does not exist are reported as a non-zero exit status carrying a diagnostic on standard error, in the same shape as any other failed command. None of the three is reported as `{:error, reason}`:

```elixir
{:ok, result} = Exec.run(["/nonexistent/nope"])
result.exit_status  #=> 1
result.stderr       #=> a diagnostic naming the missing file
```

`{:error, reason}` from `Exec.run/2` or `Exec.open/2` means the command was never handed to the operating system at all — an empty command, or a set of options the underlying runner refused.

## Options

Options are a keyword list, given as the second argument to `Exec.run/2`, `Exec.stream/2` and `Exec.open/2`.

Read by `Exec` itself:

* `:timeout` — milliseconds bounding a whole `Exec.run/2` call or a whole `Exec.stream/2` enumeration, measured from when it begins. Defaults to five minutes; pass `:infinity` for no bound. `Exec.open/2` accepts the key and ignores it, handing back a handle rather than reading anything; `Exec.read/2` takes its own timeout per call.
* `:stream` — a one-argument function `Exec.run/2` calls with each `{:stdout, chunk}` and `{:stderr, chunk}` as it arrives, so a long command is visible while it runs. Chunks, not lines. Ignored by `Exec.stream/2` and `Exec.open/2`, which hand the caller their output already.
* `:owner` — the process whose death stops the program. Defaults to the process that called `Exec.run/2`, `Exec.stream/2` or `Exec.open/2`.
* `:stdin`, `:stdout`, `:stderr` — whether to connect that one stream to the program. Each defaults to `true`. A program started with `stdout: false` produces no `{:stdout, _}` events at all, and one started with `stdin: false` accepts a write and discards it.

Forwarded to `:erlexec` unchanged: `:executable`, `:cd`, `:env`, `:kill`, `:kill_timeout`, `:user`, `:nice`, `:success_exit_code`, `:winsz`, `:pty`, `:capabilities` and `:debug`. [erlexec's documentation](https://hexdocs.pm/erlexec/exec.html) describes what each of those means.

`:group` is not accepted. `Exec` sets it, so that `Exec.stop/1` and `Exec.signal/2` reach a program's whole process group.

**Any option the runner rejects raises `ArgumentError`**, which includes a key it does not know. A silently dropped option would be an invisible bug — the command runs, ignoring the `cd:` that was meant to place it — so an unrecognised key is refused rather than forwarded.

## Lifetime

A program never outlives the process that started it. If that process dies, including under `Process.exit(pid, :kill)`, which leaves no code of its own to run, the program is stopped. This holds for `Exec.run/2`, `Exec.stream/2` and `Exec.open/2` alike:

```elixir
spawn(fn -> {:ok, _program} = Exec.open("sleep 3600") end)
# The spawned process exits immediately, and `sleep 3600` is stopped with it.
```

The guarantee does not survive the Erlang VM itself going down.

The reverse does not hold. A program that fails, exits non-zero or is killed by a signal does not disturb the process that started it.

`owner: pid` ties a program's lifetime to a process other than the one that started it, which is how a program outlives a short-lived caller without being orphaned.

### Process groups and exit status

Each program runs in a process group of its own, and `Exec.stop/1` and `Exec.signal/2` act on that whole group. A binary command therefore takes down `/bin/sh` and every program the shell started, rather than leaving the real work orphaned when the shell dies. `Exec.signal/2` reports the signal identically for a binary command and a list command:

```elixir
{:exit, {:signal, :sigterm}}
```

`Exec.stop/1` is an ordered termination rather than a raw signal, so a program stopped that way reports exit status `0`, whichever form the command took:

```elixir
{:exit, 0}
```

A signal that arrives from outside the group behaves differently. It reaches the one program it names and no other, so an operator who runs `kill -TERM` against the inner program of `Exec.open("sleep 30")` leaves `/bin/sh` alive to reap that program, write a diagnostic of its own on standard error, and exit `128 + signal`:

```elixir
{:stderr, "Terminated\n"}
{:exit, 143}
```

That `"Terminated\n"` is written by `/bin/sh`, not by `sleep`. A list command has no shell in it to write such a line: an outside signal reaches the one program that is there, so a list command reports that signal in the same `{:exit, {:signal, :sigterm}}` form whether the signal came from `Exec.signal/2` or from outside the group.

Because `Exec.signal/2` signals the whole group, a program that traps a signal is not protected from `Exec.signal/2` when its command was given as a binary. The `/bin/sh -c` wrapper is in the same group and traps nothing, so the wrapper dies of the signal and the wrapper's death is the exit `Exec.read/2` reports, even while the program the shell wrapped is still running and still ignoring the signal. Against a script whose first line is `trap '' TERM`, `Exec.signal(program, :sigterm)` produces `{:exit, {:signal, :sigterm}}` for `Exec.open("/path/to/script")` and `{:error, :timeout}` for `Exec.open(["/path/to/script"])`, the latter because the trap holds and the program is still there. The list form is what signals a program that handles signals itself.

`Exec.write/2`, `Exec.stop/1` and `Exec.signal/2` each return `{:error, :not_running}` when the program has already ended. Output the program produced before it ended is still readable with `Exec.read/2`; the handle is spent only once the `{:exit, status}` event has been read.

`Exec.signal/2` accepts a signal name such as `:sigterm`, `:sigkill` or `:sigusr1`, or the integer number. Names are resolved for the operating system the VM is running on, because the two systems disagree about some of the numbers: `:sigusr1` is 10 on Linux and 30 on Darwin. The same table names the signal reported in `{:exit, {:signal, name}}`, so a signal sent by name comes back under that name. The names known are `:sighup`, `:sigint`, `:sigquit`, `:sigill`, `:sigtrap`, `:sigabrt`, `:sigfpe`, `:sigkill`, `:sigsegv`, `:sigpipe`, `:sigalrm`, `:sigterm`, `:sigttin`, `:sigttou`, `:sigxcpu`, `:sigxfsz`, `:sigvtalrm`, `:sigprof`, `:sigwinch`, `:sigusr1`, `:sigusr2`, `:sigchld`, `:sigcont`, `:sigstop` and `:sigtstp`. A name that is not a known signal raises `ArgumentError` in the calling process: there is no number to send, and guessing one would signal something. An integer is sent as it stands, and one the operating system has no signal for comes back as `{:error, :einval}`. Signal `0` is accepted: it sends nothing and asks whether the program exists.

### Signals sent immediately after starting

`SIGHUP`, `SIGINT`, `SIGPIPE` and `SIGTERM` can be lost when they are sent in the moment between a program being created and its beginning to run. `:erlexec`'s port program, `exec-port`, installs handlers for those four signals for itself, and a newly created program inherits those handlers until it replaces itself with the command being run. A signal arriving in that gap is absorbed by an inherited handler instead of reaching the program that was asked for.

`Exec` sends such a signal again, every 50 milliseconds, for as long as the program is still running and no more than 250 milliseconds have passed since it started — at most six further sends, the last of them no later than 300 milliseconds after the program started. The consequence for a program that installs its own handler for one of those four signals inside that window is that the program may observe the signal more than once. That trade is deliberate: a duplicate is a nuisance the caller can reason about, and a lost signal is the caller's instruction silently not happening.

`Exec.stop/1` always ends the program, because it escalates to `SIGKILL`, which no handler can absorb. Its opening `SIGTERM` is one of the four, though, and can be swallowed in that same moment like any other. When that happens the program ends at the escalation rather than promptly — around five seconds after the `Exec.stop/1` call by default, or after whatever `:kill_timeout` was given. A program stopped a moment after `Exec.open/2` returns can therefore stall for that long before its `{:exit, 0}` arrives, where the same call a few tens of milliseconds later returns the exit almost at once.

Signals other than those four are not absorbed this way. The only other handler `exec-port` installs is for `SIGCHLD`, which a program ignores by default in any case, so nothing a caller can send through `Exec.signal/2` is swallowed except those four.

## Configuration

`elixir_exec` has no configuration of its own. `:erlexec` starts itself and reads its own start options, so it is configured directly. Every key below is optional:

```elixir
config :erlexec,
  # Whether to allow starting child programs as root. Defaults to false.
  # The non-root user tooling below is the better answer than setting this.
  root: false,
  user: "elixir_exec",
  limit_users: ["elixir_exec"],
  verbose: false,
  alarm: 12,
  # Absolute path to erlexec's exec-port binary. When unset, erlexec finds it
  # in its own priv/ directory, which is correct for a plain Mix project and
  # wrong only for a release that relocated it.
  portexe: "/opt/myapp/bin/exec-port"
```

Configuration does not cover the `SHELL` environment variable described under Installation. `exec-port` reads `SHELL` from the operating system environment, which no `config :erlexec` key can supply.

## Running child programs as a non-root user

`:erlexec` refuses to start any program while running as root, unless it was configured with `root: true`. Rather than granting that, create a dedicated unprivileged operating system user and have child programs drop to it. The Mix task that creates that user runs on the deploy host, once, and is not part of the runtime:

```sh
mix exec.user.create                       # creates the "elixir_exec" system user
mix exec.user.create --username myapp_exec # or a user and group of another name
```

The `:user` option then names that user, per command:

```elixir
Exec.run("whoami", user: "elixir_exec")
```

`config :erlexec, limit_users: ["elixir_exec"]` restricts every command to that user instead, so that a call omitting the `:user` option is refused rather than run with the VM's own privileges.

---

## Manually Creating an Exec User

Run the application and its commands under a dedicated non-root user with only
the access they need.

### 1. Create the group

Choose an unused GID and create the group:

```bash
groupadd --gid 10001 sandbox
````

`groupadd --gid` assigns the specified GID, which must be unique unless non-unique
IDs are explicitly enabled.

### 2. Create the user

First, find the path to `nologin`:

```bash
command -v nologin
```

Then create the user using that path:

```bash
useradd \
  --system \
  --uid 10001 \
  --gid sandbox \
  --no-create-home \
  --shell /usr/sbin/nologin \
  sandbox
```

This configures:

```text
username:      sandbox
UID:           10001
primary group: sandbox
GID:           10001
home:          (none)
login shell:   /usr/sbin/nologin
```

`--gid` sets the primary group. `--no-create-home` keeps the account locked down by
not creating a home directory.

Do not set a password. When `useradd` is used without `--password`, the password is
created in a locked state.

`nologin` refuses login attempts that use the account's login shell.

### 3. Restrict the account

Because the account is created without a home directory and with a non-login shell,
there is no home directory to restrict. Only give `sandbox` write access to files and
directories that the application needs to modify.

### 4. Verify the account

Check the user and group membership:

```bash
id sandbox
```

The account should have `sandbox` as its primary group and no supplementary groups.

`useradd` normally assigns only the initial group, but `/etc/default/useradd` can configure
supplementary groups. If `id` shows an unwanted group, remove it with:

```bash
gpasswd -d sandbox GROUP
```

For example:

```bash
gpasswd -d sandbox docker
```

Check the account fields:

```bash
getent passwd sandbox
```

Verify the UID, GID, home directory, and `nologin` shell.

Check the password state:

```bash
passwd -S sandbox
```

The second field should be `L`, meaning the password is locked.

### 5. Do not give erlexec additional privileges

For this sandbox configuration, do not configure `exec-port` to run through `sudo`, install
it setuid root, or grant it capabilities that allow it to change user identity or perform
privileged operations.

Those erlexec configurations are specifically intended to let `exec-port` perform operations
that the application's normal user could not perform.

### 6. Run the application as the sandbox user

For Docker:

```dockerfile
USER sandbox:sandbox
```

Docker uses this user and group for subsequent `RUN` instructions and for the container's
runtime `ENTRYPOINT` and `CMD`.

Specifying both the user and group also causes Docker to ignore any other configured group
memberships for that user.

### Final configuration

```text
username:             sandbox
UID:                  10001
primary group:        sandbox
GID:                  10001
supplementary groups: none
home:                 /home/sandbox
login shell:          nologin
password:             locked
administrative access: none
```

Creating the account only establishes its OS identity. Configure filesystem permissions,
Linux capabilities, container restrictions, network access, and resource limits separately.