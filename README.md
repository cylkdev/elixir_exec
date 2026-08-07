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

`Exec.stream!/2` returns a lazy stream of lines, for a command that runs for a long time or prints more than the calling process should hold in memory at once:

```elixir
iex> ~S(printf 'a\nb\n') |> Exec.stream!() |> Enum.to_list()
[stdout: "a\n", stdout: "b\n", exit: 0]
```

Elements are `{:stdout, line}`, `{:stderr, line}` and a final `{:exit, status}`. Each line keeps its trailing newline, and a last line that has none is emitted as it stands. Standard output is in order and standard error is in order, but the two are not ordered relative to each other.

Nothing runs until enumeration begins, so a stream that is built and never enumerated starts no program.

Halting the enumeration early — through `Enum.take/2`, an `Enum.reduce_while/3` halt, or an exception raised by the consumer — stops the program and emits no `{:exit, status}` element. The absence of that element is what distinguishes an enumeration the consumer halted from a program that ended on its own:

```elixir
"tail -f /var/log/system.log"
|> Exec.stream!()
|> Stream.filter(&match?({:stdout, _}, &1))
|> Enum.take(5)
```

`Exec.stream!/2` raises `Exec.Error` when the command cannot be started, where `Exec.run/2` and `Exec.open/2` return `{:error, reason}`. A lazy stream is built before it is enumerated and so has no return value in which to carry a start failure.

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

`Exec.stop/1` sends `SIGTERM` and escalates to `SIGKILL` after roughly five seconds, so a program that ignores `SIGTERM` can take that long to end; the `:kill_timeout` option changes that delay. `Exec.signal/2` sends exactly one signal and escalates nothing, so `Exec.signal(program, :sigkill)` ends a program immediately:

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

Options are a keyword list, given as the second argument to `Exec.run/2`, `Exec.stream!/2` and `Exec.open/2`.

Read by `Exec` itself:

* `:timeout` — milliseconds bounding a whole `Exec.run/2` call. Defaults to `:infinity`. `Exec.stream!/2` and `Exec.open/2` accept the key and ignore it, having no total duration to bound.
* `:owner` — the process whose death stops the program. Defaults to the process that called `Exec.run/2`, `Exec.stream!/2` or `Exec.open/2`.
* `:stdin`, `:stdout`, `:stderr` — whether to connect that one stream to the program. Each defaults to `true`. A program started with `stdout: false` produces no `{:stdout, _}` events at all, and one started with `stdin: false` accepts a write and discards it.

Forwarded to `:erlexec` unchanged: `:executable`, `:cd`, `:env`, `:kill`, `:kill_timeout`, `:user`, `:nice`, `:success_exit_code`, `:winsz`, `:pty`, `:capabilities` and `:debug`. [erlexec's documentation](https://hexdocs.pm/erlexec/exec.html) describes what each of those means.

`:group` is not accepted. `Exec` sets it, so that `Exec.stop/1` and `Exec.signal/2` reach a program's whole process group.

**Any other key raises `ArgumentError`**, as does a value the underlying runner rejects. A silently dropped option is an invisible bug — the command runs, ignoring the `cd:` that was meant to place it — so an unrecognised key is refused rather than forwarded.

## Lifetime

A program never outlives the process that started it. If that process dies, including under `Process.exit(pid, :kill)`, which leaves no code of its own to run, the program is stopped. This holds for `Exec.run/2`, `Exec.stream!/2` and `Exec.open/2` alike:

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
mix elixir_exec.setup_user                       # creates the "elixir_exec" system user
mix elixir_exec.setup_user --username myapp_exec # or a user and group of another name
```

The `:user` option then names that user, per command:

```elixir
Exec.run("whoami", user: "elixir_exec")
```

`config :erlexec, limit_users: ["elixir_exec"]` restricts every command to that user instead, so that a call omitting the `:user` option is refused rather than run with the VM's own privileges.

## Design notes

**The owner is held by a monitor; `:erlexec`'s controller is held by a link.** The two are deliberately different. `:erlexec` kills an operating system process when the controller process it associated with that program dies, and the controller dies with anything it is linked to. Linking the controller therefore reaps the program however the process that owns it goes away — including `Process.exit(pid, :kill)` and the supervision tree coming down, neither of which leaves any cleanup code a chance to run. A monitor there would let the controller outlive the library and orphan the operating system process. The owner is the opposite case: a program that exits non-zero must not take the owner with it, so the owner is watched with a monitor, which carries no such exit, and never with a link.

**Supervised children are `:temporary`.** One process supervises each running program, under a `DynamicSupervisor`. A program that has ended has ended, and restarting its supervising process would run the command a second time — a second `git push`, a second `rm`. The supervisor exists to own those processes and take them down when the VM does, not to bring any of them back.

**`:erlexec` supervises itself.** It is listed as an ordinary dependency and starts as an ordinary OTP application, with its own supervision tree over a single VM-wide `exec` process. `elixir_exec` does not start it, wrap it, or put it under `elixir_exec`'s own supervisor. `elixir_exec`'s application module starts one thing: the supervisor over running programs.

**`/bin/sh` is named rather than inherited from `$SHELL`.** Left to itself, `:erlexec` passes a binary command to whatever `SHELL` names, which makes the resulting process tree depend on the machine. `zsh` and `bash` replace themselves with the program when the script is a single simple command, while `dash` — which is `/bin/sh` on Debian — forks and runs the program as a child. That difference decides whether the process this library tracks is the program itself or only its parent, and with it whether `Exec.stop/1` and the lifetime guarantee mean anything. Naming `/bin/sh` settles the question the same way on every machine, as `System.shell/2` does.

## Development

**Docker is the only supported way to run the test suite.** `docker/test` builds the image and runs a command inside it, defaulting to `mix test`:

```sh
docker/test                              # the ExUnit suite, including doctests
docker/test mix format --check-formatted  # formatting
docker/test mix credo --strict            # linting
docker/test mix dialyzer                  # type checking
docker/test mix coveralls                 # coverage
docker/test mix docs                      # HexDocs output
docker/test mix hex.build                 # the Hex package
```

`mix test` run directly on a development machine fails. `test/exec_test.exs` starts `/usr/local/fixtures/ignores-sigterm`, a program that exists only inside the image, and four further tests reach `pgrep`, which macOS and Debian do not agree on, through a shared helper. The image exists because this suite starts real operating system programs and inspects what they print and how they end, so those programs have to be present and have to behave the same way from one run to the next. `docker/Dockerfile` declares which programs the suite needs rather than trusting whatever the machine running the tests happens to have installed.

The files that make that work:

* `docker/Dockerfile` — the image: Elixir on Debian, plus `build-essential` for compiling `:erlexec`'s `exec-port` and `procps` for `pgrep`. Heavily commented; it is the reference for how the test environment is put together.
* `docker/test` — the two-line script that builds that image and runs a command in it.
* `docker/fixtures/ignores-sigterm` — a shell script that ignores `SIGTERM` and loops forever, copied into the image at `/usr/local/fixtures/ignores-sigterm`. A test starts it to confirm that `Exec.stop/1` escalates to `SIGKILL` when a program declines to exit.
* `.dockerignore` — keeps `deps/` and `_build/` out of the build context, so that macOS-compiled artefacts can never reach the Linux image.

The library itself:

* `lib/exec.ex` — the public API, and the reference documentation for it.
* `lib/exec/` — `Result` and `Error`, which are public, alongside the private application, supervisor and per-program modules.
* `lib/mix/tasks/elixir_exec.setup_user.ex` — the deploy-host Mix task described above.
* `priv/scripts/` — the shell scripts that task runs.

## Documentation

Function-level documentation lives in the `@doc` attributes of `lib/exec.ex` and is published on [HexDocs](https://hexdocs.pm/elixir_exec).

## License

Apache-2.0. The full text is in the [LICENSE](https://github.com/kurtome/elixir_exec/blob/main/LICENSE) file at the root of the repository, and is shipped in the Hex package.
