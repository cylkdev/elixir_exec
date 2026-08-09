#!/usr/bin/env bash
#
# create-erlexec-user.sh
#
# Create a dedicated NON-root system user that child commands can drop to,
# so a project never has to run erlexec with `root: true` or set the
# exec-port SUID bit.
#
# This is the safe alternative to privilege escalation: erlexec keeps
# `root: false` (the Exec default), and individual commands run as
# this unprivileged user via Exec's per-command `:user` / `:group`
# options, or the exec-level `limit_users` allow-list.
#
# Designed for non-interactive use (CI, provisioning):
#   - Idempotent: if the user already exists, it is left untouched.
#   - Cross-platform: Linux (useradd) and macOS (dscl).
#   - Creates a locked-down account: system user, no home, no login shell.
#
# Usage:
#   ./create-erlexec-user.sh [--username NAME] [--group GROUP]
#
#   --username NAME   User to create (default: elixir_exec)
#   --group GROUP     Primary group (default: same as username)
#
# After creation, run commands as the user:
#
#   Exec.run("whoami", sync: true, stdout: true, user: "elixir_exec")
#
# or restrict at the exec level in config:
#
#   config :elixir_exec, limit_users: ["elixir_exec"]

set -euo pipefail

USERNAME="elixir_exec"
GROUP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --username) USERNAME="$2"; shift 2 ;;
    --username=*) USERNAME="${1#*=}"; shift ;;
    --group) GROUP="$2"; shift 2 ;;
    --group=*) GROUP="${1#*=}"; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

GROUP="${GROUP:-$USERNAME}"

# ----------------------------------------------------------------------
# User-creation needs root. Re-exec via sudo for the create step only.
# ----------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -- "$0" --username "$USERNAME" --group "$GROUP"
  fi
  echo "ERROR: must run as root (or with sudo) to create a user." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Idempotency: nothing to do if the user already exists.
# ----------------------------------------------------------------------
if id -u "$USERNAME" >/dev/null 2>&1; then
  echo "User '${USERNAME}' already exists; nothing to do."
  exit 0
fi

OS="$(uname -s)"
case "$OS" in
  Linux)
    if getent group "$GROUP" >/dev/null 2>&1; then :; else
      groupadd --system "$GROUP"
    fi
    useradd --system --no-create-home --shell /usr/sbin/nologin \
            --gid "$GROUP" "$USERNAME"
    ;;

  Darwin)
    # Allocate a free UID/GID below 500 (the hidden/system range).
    find_free_id() {
      local key="$1" id=200
      while dscl . -list /"$key" UniqueID 2>/dev/null | awk '{print $2}' | grep -qx "$id" \
            || dscl . -list /"$key" PrimaryGroupID 2>/dev/null | awk '{print $2}' | grep -qx "$id"; do
        id=$((id + 1))
      done
      echo "$id"
    }

    if ! dscl . -read /Groups/"$GROUP" >/dev/null 2>&1; then
      GID="$(find_free_id Groups)"
      dscl . -create /Groups/"$GROUP"
      dscl . -create /Groups/"$GROUP" PrimaryGroupID "$GID"
    else
      GID="$(dscl . -read /Groups/"$GROUP" PrimaryGroupID | awk '{print $2}')"
    fi

    UID_NEW="$(find_free_id Users)"
    dscl . -create /Users/"$USERNAME"
    dscl . -create /Users/"$USERNAME" UserShell /usr/bin/false
    dscl . -create /Users/"$USERNAME" UniqueID "$UID_NEW"
    dscl . -create /Users/"$USERNAME" PrimaryGroupID "$GID"
    dscl . -create /Users/"$USERNAME" NFSHomeDirectory /var/empty
    dscl . -create /Users/"$USERNAME" IsHidden 1
    ;;

  *)
    echo "ERROR: unsupported OS '${OS}'. Create user '${USERNAME}' manually." >&2
    exit 1
    ;;
esac

echo "Created non-root user '${USERNAME}' (group '${GROUP}')."
echo "Run commands as it, e.g.:"
echo "  Exec.run(\"whoami\", sync: true, stdout: true, user: \"${USERNAME}\")"
echo "or restrict at the exec level:"
echo "  config :elixir_exec, limit_users: [\"${USERNAME}\"]"
