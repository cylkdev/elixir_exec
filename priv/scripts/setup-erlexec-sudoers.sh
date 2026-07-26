#!/usr/bin/env bash
#
# setup-erlexec-sudoers.sh
#
# Install a /etc/sudoers.d drop-in granting the current user passwordless
# sudo only for the consuming project's deps/erlexec/priv/<arch>/exec-port.
#
# This is the "Preferred option" documented at
# deps/erlexec/src/exec.erl:18-20, and is what erlexec needs in order to
# start when a project is configured with `:erlexec, root: true` (the
# typical setting when the same release runs under root in a deploy
# container) but the local / CI Erlang VM is NOT itself running as root.
#
# Designed for non-interactive use in CI pipelines:
#   - Fully scriptable; no editor invocation.
#   - Validates sudoers syntax with `visudo -c` BEFORE writing into
#     /etc/sudoers.d so a malformed line can never corrupt the system
#     sudoers configuration.
#   - Idempotent; re-running replaces the drop-in with identical content.
#
# Prerequisites:
#   - Run from inside a Mix project that depends on :erlexec.
#   - Dependencies fetched and compiled (`mix deps.get && mix deps.compile`)
#     so that deps/erlexec/priv/<arch>/exec-port exists.
#   - The invoking user has passwordless sudo available
#     (true by default on GitHub-hosted macOS and Ubuntu runners).
#
# Typical CI usage (the script is shipped inside :elixir_exec; consumers
# call it via the path Mix fetches it to):
#
#   - run: mix deps.get
#   - run: mix deps.compile
#   - run: ./deps/elixir_exec/priv/scripts/setup-erlexec-sudoers.sh
#   - run: mix test

set -euo pipefail

# ----------------------------------------------------------------------
# Early exit: container CI running as root needs no sudo grant.
# erlexec's case statement at exec.erl:966-982 takes the IsRoot=true
# branch and invokes exec-port directly, with no sudo prefix.
# ----------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "Erlang VM will run as root; exec-port escalation not needed. Skipping."
  exit 0
fi

# ----------------------------------------------------------------------
# Resolve the exec-port path via erlexec's own resolver.
# `mix run --no-start` loads compiled code without booting :exec_app
# (booting would re-trigger the very sudo failure this script fixes).
# `:exec.default(:portexe)` returns the full filename or "" on failure.
# ----------------------------------------------------------------------
if ! command -v mix >/dev/null 2>&1; then
  echo "ERROR: 'mix' not found on PATH; cannot resolve exec-port path." >&2
  exit 1
fi

EXEC_PORT="$(mix run --no-start -e 'IO.puts(:exec.default(:portexe))' 2>/dev/null | tail -n1)"

if [ -z "${EXEC_PORT}" ] || [ ! -f "${EXEC_PORT}" ]; then
  echo "ERROR: could not resolve exec-port via :exec.default(:portexe)." >&2
  echo "       Run 'mix deps.get && mix deps.compile' first." >&2
  exit 1
fi

# Use the priv directory with an arch wildcard so a re-build for a
# different architecture under the same priv dir is also covered.
# Sudoers fnmatch wildcards do NOT match '/', so this grant cannot
# expand into deeper paths.
PRIV_DIR="$(dirname "$(dirname "${EXEC_PORT}")")"
EXEC_PORT_GLOB="${PRIV_DIR}/*/exec-port"

# ----------------------------------------------------------------------
# Determine the user the grant should authorize.
# SUDO_USER is set when this script is itself invoked under sudo;
# otherwise fall back to the current login user.
# ----------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-$USER}"

SUDOERS_FILE="/etc/sudoers.d/erlexec"
TMPFILE="$(mktemp)"
trap 'rm -f "${TMPFILE}"' EXIT

printf '%s ALL=(root) NOPASSWD: %s\n' "${TARGET_USER}" "${EXEC_PORT_GLOB}" > "${TMPFILE}"

# ----------------------------------------------------------------------
# Validate sudoers syntax against the temp file BEFORE the content can
# reach /etc/sudoers.d/. `visudo -c -f` exits non-zero on syntax errors;
# `set -e` then aborts the script with the actual visudo error visible.
# ----------------------------------------------------------------------
sudo visudo -cf "${TMPFILE}"

# ----------------------------------------------------------------------
# Atomic install with the ownership (root) and mode (0440) sudoers requires.
# `install` does an atomic rename so concurrent reads of /etc/sudoers.d/
# never see a partial file.
# ----------------------------------------------------------------------
sudo install -m 0440 -o root "${TMPFILE}" "${SUDOERS_FILE}"

echo "Installed ${SUDOERS_FILE} for user ${TARGET_USER}:"
sudo cat "${SUDOERS_FILE}"
