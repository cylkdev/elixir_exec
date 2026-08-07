# Builds a Linux machine image that contains this project and everything its
# test suite needs, so the tests can run without installing anything on the
# computer you are sitting at.
#
# Why bother: the tests in test/elixir_exec_test.exs start real programs --
# `sleep`, `cat`, `printf`, `pgrep` -- and check what those programs print and
# how they end. Those programs have to exist. On a Mac some of them are missing
# and others behave differently than on Linux. Installing them here means every
# run of the suite uses the same ones.
#
# Run these two commands from the top of the repository, the folder that holds
# mix.exs. Do not run them from inside the docker/ folder:
#
#     docker build -f docker/Dockerfile -t elixir_exec_test .
#     docker run --rm elixir_exec_test
#
# In the first command, `-f docker/Dockerfile` says which file to read, and the
# `.` on the end says which folder Docker may copy files out of while building.
# That folder is called the build context, and here it is the repository root.
# Every COPY instruction below names its source relative to the repository root,
# which is why they read `mix.exs` and `lib` rather than `../mix.exs` and
# `../lib`.
#
# `-t elixir_exec_test` names the built image, so `docker run` can refer to it.
# `--rm` deletes the container after the tests finish.
#
# One file in the repository root controls what the build context may contain:
# .dockerignore, which sits beside mix.exs and lists deps/ and _build/ so that
# the macOS-compiled copies on your machine can never be copied into this Linux
# image. Docker only reads .dockerignore from the build context root, so it
# cannot live in docker/.
#
# The instructions below run top to bottom. Each one starts from the filesystem
# that the instruction above it left behind.

# FROM names the filesystem to start from: an image published by the Elixir team
# with Elixir 1.18.4 and Erlang 27.3.4 already installed on top of Debian 12
# ("bookworm"), so this file does not have to install either.
#
# "slim" means Debian packages that most projects do not need were left out of
# that image to keep its download small. Two of the omitted packages are needed
# here, and the RUN instruction below installs them.
FROM hexpm/elixir:1.18.4-erlang-27.3.4-debian-bookworm-20250428-slim

# SHELL names the program that will execute the command in every RUN instruction
# below. The default is `/bin/sh -c`. This line keeps /bin/sh and adds the `-e`
# flag, which tells /bin/sh to stop at the first command that fails.
#
# Without `-e`, a RUN instruction holding several commands is considered to have
# succeeded as long as the last of those commands succeeded. A failure in the
# middle would be ignored and this file would finish building a broken image.
SHELL ["/bin/sh", "-e", "-c"]

# RUN executes a command inside the image while the image is being built, and
# keeps the files that command creates. Nothing in a RUN instruction happens
# when the container is later started; this is installation, performed once.
#
# This RUN installs two Debian packages:
#
#   build-essential  The C and C++ compilers, `gcc` and `g++`, plus `make`. The
#                    erlexec package that mix.exs depends on is not pure Erlang.
#                    It includes a C++ program named exec-port that is compiled
#                    from source by the `mix deps.compile` instruction further
#                    down this file. If no compiler is installed, that
#                    instruction fails and the image does not build.
#
#   procps           The `pgrep` command, which searches the operating system's
#                    list of running programs by name. Three tests in
#                    test/elixir_exec_test.exs shell out to `pgrep` to confirm
#                    that a program really disappeared from the operating
#                    system, rather than trusting this library's own report that
#                    it stopped that program.
#
# The three commands do this: `apt-get update` downloads Debian's catalogue of
# available packages into the folder /var/lib/apt/lists; `apt-get install` reads
# that catalogue and installs build-essential and procps; `rm -rf` deletes
# /var/lib/apt/lists, which has no further use once the install has finished and
# which adds roughly 40 MB to the image if kept.
#
# Those three commands are written as a single RUN, joined by `;`, on purpose.
# Each instruction in this file saves its resulting files as a frozen layer,
# stacked on top of the layers from the instructions above it. A file deleted by
# a later layer stops being visible, but its bytes are still carried inside the
# earlier layer that created it. So deleting /var/lib/apt/lists only reclaims
# space if the deletion happens in the same instruction that downloaded it.
RUN apt-get update; \
    apt-get install -y --no-install-recommends build-essential procps; \
    rm -rf /var/lib/apt/lists/*

# Every instruction so far has run as the user `root`, the superuser, because
# `root` is what Docker uses unless a USER instruction says otherwise.
#
# `root` does not work for this project. The erlexec package refuses to start
# any program at all while erlexec itself is running as `root`, on the reasoning
# that a mistake made with unlimited privileges costs far more than the same
# mistake made without them. If the test suite ran as `root`, every test that
# starts a program would fail.
#
# `useradd` therefore creates an ordinary, unprivileged user named `app`, gives
# it a home folder at /home/app, and sets /bin/sh as its shell.
RUN useradd --create-home --shell /bin/sh app

# WORKDIR creates the folder /app inside the image and makes /app the folder
# that every instruction below runs in. After this line, a relative path in a
# COPY destination or a RUN command is resolved against /app: `./` means /app,
# and `lib` means /app/lib.
WORKDIR /app

# The WORKDIR instruction above created /app while `root` was still the current
# user, so /app is owned by `root` and the `app` user cannot write to it. The
# `app` user does need to write to it, because `mix deps.get` and
# `mix deps.compile` below create /app/deps and /app/_build. `chown` transfers
# ownership of /app to the user `app` and the group `app`.
RUN chown app:app /app

# USER changes the account that runs everything below this line: the remaining
# RUN instructions during the build, and the CMD instruction when the container
# is started. Nothing after this line runs as `root`.
USER app

# ENV SHELL is still required here, but no longer for the reason it originally
# was. It used to matter because erlexec decided which shell interpreted a
# string command by reading $SHELL, and leaving that to the surrounding machine
# made the tests behave differently on a Mac than on Debian. The library now
# names /bin/sh itself when it builds the command, so that reason is gone --
# but exec-port, the C++ program erlexec's OTP application starts, refuses to
# start at all unless $SHELL is set to something non-empty (exec.cpp:626-628,
# "SHELL environment variable not set!"), whether or not any command it runs is
# ever a string. Removing this line was tried while fixing the shell-forking
# defect this Dockerfile's tests exist to catch, and it broke every test by
# preventing the erlexec application from starting in the first place.
ENV SHELL=/bin/sh

# MIX_ENV tells Elixir which of its three build environments to use: dev, test
# or prod. Setting it to `test` makes `mix deps.get` below install the
# dependencies that mix.exs marks `only: [:dev, :test]` or `only: :test` --
# credo, blitz_credo_checks, dialyxir, excoveralls and ex_doc -- and makes
# `mix deps.compile` write its output to /app/_build/test, which is where
# `mix test` will later look for it.
ENV MIX_ENV=test

# Hex is Elixir's package manager, and rebar builds dependencies that are
# written in Erlang rather than Elixir. Neither is present in a freshly
# downloaded image, and the `mix deps.get` instruction below needs both. The
# `--force` flag answers the "shall I install this?" prompt that each command
# would otherwise print and wait on, with no person present to answer it.
RUN mix local.hex --force
RUN mix local.rebar --force

# COPY reads files from the build context -- the repository root on your
# computer, named by the `.` in the `docker build` command at the top of this
# file -- and writes them inside the image. Every path before the last one is a
# source in the repository; the last one is the destination in the image.
#
# This instruction copies the repository's mix.exs and mix.lock to /app/mix.exs
# and /app/mix.lock. The destination `./` means /app because of the WORKDIR
# instruction above.
#
# `--chown=app:app` makes both copies owned by the user `app`. Without it they
# would arrive owned by `root`, and the `app` user running the build steps below
# could read but not replace them.
#
# Only these two files are copied here, ahead of the library's source code, and
# the reason is build speed. Docker reuses the stored result of an instruction
# whenever that instruction and its inputs are unchanged since the last build.
# The three instructions after this one download and compile every dependency
# and build Dialyzer's lookup tables, which together take several minutes -- and
# their only inputs are mix.exs and mix.lock. Copying just those two files at
# this point means that editing a file in lib/ or test/ leaves this instruction
# unchanged, so those several minutes are skipped until a dependency actually
# changes.
COPY --chown=app:app mix.exs mix.lock ./

# Reads /app/mix.lock and downloads every dependency it names into /app/deps.
RUN mix deps.get

# Compiles everything in /app/deps into /app/_build/test. This is the
# instruction that builds erlexec's exec-port C++ program, using the `g++`
# installed by the build-essential package near the top of this file.
#
# /app/deps and /app/_build are created here, inside the image, and are never
# copied in from your computer. The deps/ and _build/ folders in the repository
# hold code compiled for macOS, which cannot run on the Linux in this image.
# The .dockerignore file in the repository root lists both folders so that no
# COPY instruction can pull them in by accident.
RUN mix deps.compile

# Builds Dialyzer's lookup tables, the PLTs, and stores them in the image.
#
# `mix dialyzer` cannot type-check anything until it has catalogued every
# function in Erlang/OTP and in this project's dependencies. Building that
# catalogue takes several minutes. Every `docker run` starts a fresh container
# and throws away whatever the previous one wrote, so without this instruction
# that catalogue would be rebuilt from nothing on every single run.
#
# Building it here instead makes it part of the image, and Docker only repeats
# this instruction when mix.exs or mix.lock change. The paths it writes to,
# /app/dialyzer, come from the `dialyzer:` key in mix.exs.
#
# It runs before lib/ is copied on purpose: the PLTs describe OTP and the
# dependencies, never this project's own code, so copying lib/ first would only
# make this slow step repeat whenever a source file changed.
RUN mix dialyzer --plt

# Copies the repository's docker/fixtures folder to /usr/local/fixtures in the
# image.
#
# docker/fixtures holds one file: a shell script named ignores-sigterm, which
# ignores the SIGTERM signal and then loops forever. A test in
# test/elixir_exec_test.exs starts it by its full path inside the image,
# /usr/local/fixtures/ignores-sigterm, to check that ElixirExec.stop/1 escalates
# to SIGKILL when a program declines to exit on SIGTERM. It is a file on disk
# rather than a string inside a test because the operating system can only
# execute a program that exists as a file.
COPY --chown=app:app docker/fixtures /usr/local/fixtures

# Copies three configuration files from the repository root to /app: the
# repository's .formatter.exs to /app/.formatter.exs, read by `mix format`; its
# .credo.exs to /app/.credo.exs, read by `mix credo`; and its
# .dialyzer-ignore.exs to /app/.dialyzer-ignore.exs, read by `mix dialyzer`.
#
# They are copied before lib/ and test/ below because these three files change
# far less often than the source code does, and an instruction only has to run
# again when an instruction above it has changed.
COPY --chown=app:app .formatter.exs .credo.exs .dialyzer-ignore.exs ./

# Copies the repository's lib folder to /app/lib and its test folder to
# /app/test. lib/ holds the library's source code and test/ holds its test
# suite.
#
# These two are copied last because they are what changes from one build to the
# next, and Docker has to re-run every instruction below a changed one. Since
# nothing follows these except CMD, editing a test costs only the two copies.
COPY --chown=app:app lib lib
COPY --chown=app:app test test

# CMD names the command the container runs when `docker run` is given no command
# of its own. It runs `mix test` in the folder /app, as the user `app`, both set
# by the WORKDIR and USER instructions above.
#
# To run a different command instead, write it after the image name:
#
#     docker run --rm elixir_exec_test mix credo --strict
#     docker run --rm -it elixir_exec_test iex -S mix
CMD ["mix", "test"]
