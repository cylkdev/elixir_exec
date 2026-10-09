# elixir_exec

An idiomatic Elixir wrapper for [`erlexec`](https://hex.pm/packages/erlexec) — run and control operating system processes from Elixir.

`:erlexec` does the work of starting programs and reaping them; `elixir_exec` puts an Elixir-shaped surface on it. The public module is `Exec`: a command is a binary or a list of binaries, output arrives in the owner's mailbox as `{program, event}` messages that `Exec.read/2` receives, and a program lives at most as long as the process that started it.

## Installation

Add `:elixir_exec` to the `deps/0` function in the consuming project's `mix.exs`:

```elixir
def deps do
  [
    {:elixir_exec, "~> 0.1.0"}
  ]
end
```

`:erlexec` is an ordinary dependency. It starts itself and supervises its own `exec` process, so adding the dependency is all the setup a Mix project needs.

**Requirements:** Elixir `~> 1.18`. `:erlexec` compiles a small port binary, `exec-port`, during `mix deps.compile`, so the machine performing that compile needs a C and C++ toolchain — `cc`, `c++` and `make`.

**The `SHELL` environment variable must be set to a value of one or more characters** in the environment of the Erlang VM for `:erlexec` to start at all. `exec-port` reads `SHELL` on startup and exits with status 4 when the variable is missing or empty (`deps/erlexec/c_src/exec.cpp:626`). The resulting crash report leaves out both `elixir_exec` and the calling application, so the cause is hard to see from the failure. systemd units, container images and cron jobs are the environments where this bites: all three leave `SHELL` out of the environment they give the processes they start. A systemd unit needs `Environment=SHELL=/bin/sh`, a Dockerfile needs `ENV SHELL=/bin/sh`, and a crontab needs a `SHELL=/bin/sh` line.

This requirement is **separate** from the choice of which shell interprets a binary command. `elixir_exec` names `/bin/sh` itself when it builds the command, and ignores `SHELL` in every decision it makes. Setting `SHELL` to `bash`, `zsh` or `fish` leaves every command behaving exactly as before; its one effect is to satisfy the check that `exec-port` performs before it will run.

## Quick start

`Exec` has three entry points, in increasing order of control.

### Run a command to completion

`Exec.run/2` runs a command, collects everything it printed, and returns an `Exec.Result` struct whose `:stdout` and `:stderr` fields are binaries:

```elixir
iex> Exec.run("echo hi")
{:ok, %Exec.Result{stdout: "hi\n", stderr: "", exit: %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}}}
```

A non-zero exit is an outcome, reported in the result like any other — `grep` finding zero matches exits `1` — so a command that ran and failed still returns `{:ok, %Exec.Result{}}`, with the code in its `exit.exit_code`:

```elixir
iex> {:ok, result} = Exec.run("exit 3")
iex> result.exit.exit_code
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
[:start, {:ok, {:stdout, "a\n"}}, {:ok, {:stdout, "b\n"}}, {:ok, {:exit, %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}}}, :end]
```

Every enumeration is framed: `:start` first, `:end` last, the program's output as `{:ok, event}` in between, and any failure as `{:error, reason}`. A consumer can therefore tell a command that ended from one that failed to start, and a stream that ran out from one that was cut short, using the frames alone:

```elixir
Exec.stream("mix test")
|> Enum.each(fn
  :start -> Logger.info("started")
  {:ok, {:stdout, line}} -> Logger.info(line)
  {:ok, {:stderr, line}} -> Logger.warning(line)
  {:ok, {:exit, exit}} -> Logger.info("exited #{inspect(exit)}")
  {:error, reason} -> Logger.error("failed: #{inspect(reason)}")
  :end -> Logger.info("done")
end)
```

Each line keeps its trailing newline, and a last line that lacks one is emitted as it stands, ahead of the frame that ends the stream. Standard output is in order and standard error is in order; that ordering holds within each stream only.

The program starts when enumeration begins, so building a stream starts a program only once that stream is enumerated.

A failure ends the stream: `{:error, reason}` is followed only by `:end`. It carries the same reasons `Exec.run/2` returns, including `:timeout` — `:timeout` bounds a whole enumeration, measured from when it begins, and defaults to `5_000` here as it does for `Exec.run/2`. A stream meant to outlive that passes `:infinity`:

```elixir
"tail -f /var/log/system.log"
|> Exec.stream(timeout: :infinity)
|> Stream.filter(&match?({:ok, {:stdout, _}}, &1))
|> Enum.take(5)
```

Halting the enumeration early — through `Enum.take/2`, an `Enum.reduce_while/3` halt, or an exception raised by the consumer — stops the program, and emission ends at the halt. A consumer that halted knows it halted; the stream ending before `:end` says so to anyone further down the pipeline.

`Exec.run/2` is this stream consumed eagerly: it folds the frames into an `Exec.Result` rather than handing them to the caller one at a time. There is one reading loop underneath both, so anything true of one is true of the other.

### Start a command and control it

`Exec.open/2` starts a command and returns a handle. The handle is the argument to `Exec.read/2`, `Exec.write/2`, `Exec.stop/1` and `Exec.signal/2`. Output arrives in the owner's mailbox as `{program, event}` messages, in order, and `Exec.read/2` receives them there:

```elixir
{:ok, program} = Exec.open("cat")

Exec.write(program, "hello\n")
{:ok, %{stdout: "hello\n"}} = Exec.read(program)

Exec.write(program, :eof)
{:ok, %{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}} = Exec.read(program)
```

`Exec.read/2` blocks until an event arrives or until its timeout, given in milliseconds, expires. That timeout defaults to `5_000`, and a read that expires leaves the program running:

```elixir
{:error, :timeout} = Exec.read(program, 0)
```

`{:ok, exit}`, a map of how the program ended, is the last event a program produces. Everything a program reports comes before it.

`Exec.stop/1` sends `SIGTERM` and escalates to `SIGKILL` after roughly five seconds, so a program that ignores `SIGTERM` can take that long to end; the `:kill_timeout` option changes that delay. `Exec.signal/2` keeps to one signal — the signal sent is always the signal asked for — so `Exec.signal(program, :sigkill)` ends a program immediately. It may be sent more than once: `SIGHUP`, `SIGINT`, `SIGPIPE` and `SIGTERM` are sent again while the program is still running inside the first 250 milliseconds of its life, for the reason given under [Signals sent immediately after starting](#signals-sent-immediately-after-starting):

```elixir
{:ok, program} = Exec.open("tail -f /var/log/system.log")
{:ok, %{stdout: _line}} = Exec.read(program)
Exec.stop(program)
```

## Command forms and shell safety

A command is either a binary or a list of binaries, and the two are run in different ways:

```elixir
Exec.run("ls -l | wc -l")   # run as /bin/sh -c "ls -l | wc -l"
Exec.run(["ls", "-l"])      # passed to execve as written
```

A binary command is handed to `/bin/sh -c`, which is what performs `PATH` lookup, glob expansion, variable substitution, pipes and redirection. `/bin/sh` is named by this library rather than read from the `SHELL` environment variable, so a binary command is interpreted by the same shell on every machine.

A list command is passed to `execve` directly. The shell stays out of it entirely, so every character in it is literal: a pipe symbol, a dollar sign or a space inside an element is an ordinary character of an argument. A bare executable name in list form, one free of any `/`, is resolved against `PATH` before the call, so `["echo", "hi"]` finds the same program that `"echo hi"` does. A name containing `/` is used exactly as written, and a bare name that fails to resolve returns `{:error, {:executable_not_found, name}}`.

> ⚠ A binary command is interpreted by a shell, so a binary command must be built only from trusted input. `Exec.run("cat #{user_input}")` runs whatever `user_input` says, including `"x; rm -rf /"`. Use the list form whenever any part of a command comes from outside the application.

### Failure to launch

A missing executable given as a path, a permission failure and a missing `:cd` directory are reported as a non-zero exit code carrying a diagnostic on standard error, in the same shape as any other failed command. All three arrive as `{:ok, result}`:

```elixir
{:ok, result} = Exec.run(["/nonexistent/nope"])
result.exit.exit_code  #=> 1
result.stderr       #=> a diagnostic naming the missing file
```

`{:error, reason}` from `Exec.run/2` or `Exec.open/2` means the command stopped short of the operating system — an empty command, a list command whose executable name is missing from PATH (`{:error, {:executable_not_found, name}}`), or a set of options the underlying runner refused.

## Options

Options are a keyword list, given as the second argument to `Exec.run/2`, `Exec.stream/2` and `Exec.open/2`.

Read by `Exec` itself:

* `:timeout` — milliseconds bounding a whole `Exec.run/2` call or a whole `Exec.stream/2` enumeration, measured from when it begins. Defaults to `5_000`; pass `:infinity` to let it run for as long as it takes. `Exec.open/2` accepts the key and ignores it, handing back a handle and leaving all reading to `Exec.read/2`; `Exec.read/2` takes its own timeout per call.
* `:stream` — a one-argument function `Exec.run/2` calls with each `{:stdout, chunk}` and `{:stderr, chunk}` as it arrives, so a long command is visible while it runs. Each call gets a raw chunk, whose boundaries are independent of line breaks. Ignored by `Exec.stream/2` and `Exec.open/2`, which hand the caller their output already.
* `:owner` — the process whose death stops the program. Defaults to the process that called `Exec.run/2`, `Exec.stream/2` or `Exec.open/2`.
* `:stdin`, `:stdout`, `:stderr` — whether to connect that one stream to the program. Each defaults to `true`. A program started with `stdout: false` produces zero `%{stdout: _}` events, and one started with `stdin: false` accepts a write and discards it.

Forwarded to `:erlexec` unchanged: `:executable`, `:cd`, `:env`, `:kill`, `:kill_timeout`, `:user`, `:nice`, `:success_exit_code`, `:winsz`, `:pty`, `:capabilities` and `:debug`. [erlexec's documentation](https://hexdocs.pm/erlexec/exec.html) describes what each of those means.

`:group` is rejected. `Exec` sets it, so that `Exec.stop/1` and `Exec.signal/2` reach a program's whole process group.

**Any option the runner rejects raises `ArgumentError`**, which includes any key outside the set it knows. A silently dropped option would be a hidden bug — the command runs, ignoring the `cd:` that was meant to place it — so such a key is refused rather than forwarded.

## Lifetime

A program lives at most as long as the process that started it. If that process dies, including under `Process.exit(pid, :kill)`, which stops the process before it runs another line of its own code, the program is stopped. This holds for `Exec.run/2`, `Exec.stream/2` and `Exec.open/2` alike:

```elixir
spawn(fn -> {:ok, _program} = Exec.open("sleep 3600") end)
# The spawned process exits immediately, and `sleep 3600` is stopped with it.
```

The guarantee ends when the Erlang VM itself goes down.

The tie runs one way only. A program that fails, exits non-zero or is killed by a signal leaves the process that started it running as before.

`owner: pid` ties a program's lifetime to a process other than the one that started it, which is how a program outlives a short-lived caller while still tied to a living owner.

### Process groups and exit status

Each program runs in a process group of its own, and `Exec.stop/1` and `Exec.signal/2` act on that whole group. A binary command therefore takes down `/bin/sh` and every program the shell started, so the real work ends together with the shell. `Exec.signal/2` reports the signal identically for a binary command and a list command:

```elixir
%{exit_reason: 15, exit_code: nil, signal: 15, exit_status: :sigterm, core_dump: false}
```

`Exec.stop/1` sends `SIGTERM` and escalates to `SIGKILL`, and `:erlexec` reports a program it stopped as a graceful termination:

```elixir
%{exit_reason: 0, exit_code: 0, signal: nil, exit_status: nil, core_dump: false}
```

A signal that arrives from outside the group behaves differently. It reaches only the one program it names, so an operator who runs `kill -TERM` against the inner program of `Exec.open("sleep 30")` leaves `/bin/sh` alive to reap that program, write a diagnostic of its own on standard error, and exit `128 + signal`:

```elixir
%{stderr: "Terminated\n"}
%{exit_reason: 36608, exit_code: 143, signal: nil, exit_status: nil, core_dump: false}
```

That `"Terminated\n"` is written by `/bin/sh`; `sleep` itself dies silently. A list command runs the program alone, so that line stays out of its output: an outside signal reaches the one program that is there, so a list command reports that signal in the same `exit_status: :sigterm` form whether the signal came from `Exec.signal/2` or from outside the group.

Because `Exec.signal/2` signals the whole group, a program that traps a signal is still exposed to `Exec.signal/2` when its command was given as a binary. The `/bin/sh -c` wrapper is in the same group and keeps its default signal handling, so the wrapper dies of the signal and the wrapper's death is the exit `Exec.read/2` reports, even while the program the shell wrapped is still running and still ignoring the signal. Against a script whose first line is `trap '' TERM`, `Exec.signal(program, :sigterm)` produces `exit_status: :sigterm` for `Exec.open("/path/to/script")` and `{:error, :timeout}` for `Exec.open(["/path/to/script"])`, the latter because the trap holds and the program is still there. The list form is what signals a program that handles signals itself.

`Exec.write/2`, `Exec.stop/1` and `Exec.signal/2` each return `{:error, :not_running}` when the program has already ended. Output the program produced before it ended is still in the owner's mailbox for `Exec.read/2`.

`Exec.signal/2` accepts a signal name such as `:sigterm`, `:sigkill` or `:sigusr1`, or the integer number. Names are resolved for the operating system the VM is running on, because the two systems disagree about some of the numbers: `:sigusr1` is 10 on Linux and 30 on Darwin. The same table names the signal reported in the exit's `:exit_status`, so a signal sent by name comes back under that name. The names known are `:sighup`, `:sigint`, `:sigquit`, `:sigill`, `:sigtrap`, `:sigabrt`, `:sigfpe`, `:sigkill`, `:sigsegv`, `:sigpipe`, `:sigalrm`, `:sigterm`, `:sigttin`, `:sigttou`, `:sigxcpu`, `:sigxfsz`, `:sigvtalrm`, `:sigprof`, `:sigwinch`, `:sigusr1`, `:sigusr2`, `:sigchld`, `:sigcont`, `:sigstop` and `:sigtstp`. A name outside that list raises `ArgumentError` in the calling process: any number sent would be a guess, and a guess would signal something. An integer is sent as it stands, and one outside the operating system's set of signals comes back as `{:error, :einval}`. Signal `0` is accepted: it performs only the check of whether the program exists.

### Signals sent immediately after starting

`SIGHUP`, `SIGINT`, `SIGPIPE` and `SIGTERM` can be lost when they are sent in the moment between a program being created and its beginning to run. `:erlexec`'s port program, `exec-port`, installs handlers for those four signals for itself, and a newly created program inherits those handlers until it replaces itself with the command being run. A signal arriving in that gap is absorbed by an inherited handler, and the program that was asked for misses it.

`Exec` sends such a signal again, every 50 milliseconds, for as long as the program is still running and at most 250 milliseconds have passed since it started — at most six further sends, the last of them within 300 milliseconds of the program starting. The consequence for a program that installs its own handler for one of those four signals inside that window is that the program may observe the signal more than once. That trade is deliberate: a duplicate is a nuisance the caller can reason about, and a lost signal is the caller's instruction silently dropped.

`Exec.stop/1` always ends the program, because it escalates to `SIGKILL`, which bypasses every handler. Its opening `SIGTERM` is one of the four, though, and can be swallowed in that same moment like any other. When that happens the program ends only at the escalation — around five seconds after the `Exec.stop/1` call by default, or after whatever `:kill_timeout` was given. A program stopped a moment after `Exec.open/2` returns can therefore stall for that long before its exit arrives, where the same call a few tens of milliseconds later returns the exit almost at once.

Signals other than those four reach the program as sent. The only other handler `exec-port` installs is for `SIGCHLD`, which a program ignores by default in any case, so those four are the only signals sent through `Exec.signal/2` that can be swallowed.

## Configuration

All configuration belongs to `:erlexec`. `:erlexec` starts itself and reads its own start options, so it is configured directly. Every key below is optional:

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

The `SHELL` environment variable described under Installation lies outside configuration. `exec-port` reads `SHELL` from the operating system environment, which sits beyond the reach of every `config :erlexec` key.

## Running child programs as a non-root user

While running as root, `:erlexec` starts programs only when configured with `root: true`. Rather than granting that, create a dedicated unprivileged operating system user and have child programs drop to it. The Mix task that creates that user runs on the deploy host, once, and stays outside the runtime:

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

`groupadd --gid` assigns the specified GID, which must be unique; duplicate
IDs are allowed only when explicitly enabled.

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
skipping creation of a home directory.

Skip setting a password. When `useradd` runs with `--password` omitted, the password is
created in a locked state.

`nologin` refuses login attempts that use the account's login shell.

### 3. Restrict the account

Because the account is created with home-directory creation skipped and with a `nologin` shell,
restricting it comes down to the files it may write. Only give `sandbox` write access to files and
directories that the application needs to modify.

### 4. Verify the account

Check the user and group membership:

```bash
id sandbox
```

The account should have `sandbox` as its primary group and as its only group.

`useradd` normally assigns only the initial group, but `/etc/default/useradd` can configure
supplementary groups. If `id` shows an extra group, remove it with:

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

### 5. Keep erlexec at the application user's privileges

For this sandbox configuration, keep `exec-port` at the application user's own privileges: leave out
`sudo`, the setuid-root install, and any capabilities that allow it to change user identity or perform
privileged operations.

Those erlexec configurations are specifically intended to let `exec-port` perform operations
beyond the reach of the application's normal user.

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