#!/bin/sh
# Builds the test image from docker/Dockerfile and runs a command inside it.
#
# With no arguments it runs the test suite, because docker/Dockerfile ends with
# CMD ["mix", "test"]. Any arguments given are run instead:
#
#     docker/test                          # mix test
#     docker/test mix test test/exec_test.exs:42
#     docker/test mix credo --strict
#     docker/test mix format --check-formatted
#
# The build is fast after the first run: Docker reuses its stored results for
# every instruction whose inputs are unchanged, and editing lib/ or test/ only
# invalidates the two COPY instructions at the end of docker/Dockerfile.
set -e
docker build -f docker/Dockerfile -t elixir_exec_test .
docker run --rm elixir_exec_test "$@"
