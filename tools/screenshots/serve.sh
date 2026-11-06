#!/bin/sh
# Prepares a throwaway state directory, seeds it with synthetic data and runs
# the development service against it, with a PATH that holds no provider CLI.
#
#     tools/screenshots/serve.sh /path/to/new/empty/dir
#
# The service it starts can still pick up the seeded dispatches. With no
# `claude`, `codex` or `opencode` on PATH those fail to start instead of
# reaching a provider; this script refuses to run if one is reachable.
set -eu

root=${1:?usage: serve.sh NEW_EMPTY_DIRECTORY}
if [ -e "$root" ] && [ -n "$(ls -A "$root")" ]; then
  echo "refusing: $root is not empty" >&2
  exit 1
fi
mkdir -p "$root"

elixir_bin=$(dirname "$(command -v elixir)")
erl_bin=$(dirname "$(command -v erl)")
PATH="$elixir_bin:$erl_bin:/usr/bin:/bin"
export PATH

for cli in claude codex opencode; do
  if command -v "$cli" >/dev/null 2>&1; then
    echo "refusing: $cli is on PATH ($(command -v "$cli")); screenshots must not reach a provider" >&2
    exit 1
  fi
done

SHOESTRING_STATE_DIR="$root/state"
SHOESTRING_AUTOMATION=off
ELIXIR_ERL_OPTIONS="+fnu"
export SHOESTRING_STATE_DIR SHOESTRING_AUTOMATION ELIXIR_ERL_OPTIONS

mix shoestring.state.prepare
mix ecto.create
mix ecto.migrate
mix run tools/screenshots/seed.exs
exec mix phx.server
