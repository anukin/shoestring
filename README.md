# Shoestring

Shoestring is a local-first supervisor for coding-agent subscriptions. The
Iteration 0 application is deliberately small: Phoenix LiveView provides the
local control plane, Ecto uses SQLite for durable state, and no Claude, Codex,
API credential, or external service is required.

## Supported development environment

Iteration 0 was verified on macOS 15.7.7 arm64 with Elixir 1.19.5, Erlang/OTP
28, and SQLite 3.43.2. Other operating systems and architectures are not yet a
release claim.

Node.js is not required at build time or runtime. The current static CSS and
JavaScript are checked in; `mix assets.deploy` only creates Phoenix digests.

## Setup and development

Install dependencies, prepare the local state root, create SQLite, and run the
empty migration set:

```sh
mix setup
```

To prepare only the database:

```sh
mix db.setup
```

Start the loopback-only development endpoint:

```sh
mix phx.server
```

Open http://127.0.0.1:4000 for the LiveView health screen. Machine-readable
readiness is available at http://127.0.0.1:4000/health and returns HTTP 503
when any required local component is unavailable.

## State paths

`Shoestring.State` is the application-facing path resolver. The state layout
is:

```text
<state root>/
  shoestring.db
  artifacts/
  worktrees/
  logs/
  run/
```

Only the root and database are needed in Iteration 0; later features create
their reserved directories on demand.

Environment defaults are intentionally separate:

- Development: `<repository>/.shoestring/dev`
- Test: a unique directory below the system temporary directory
- Production on macOS: `~/Library/Application Support/Shoestring`
- Production on other Unix systems: `$XDG_STATE_HOME/shoestring` when set,
  otherwise `~/.local/state/shoestring`

`SHOESTRING_STATE_DIR` overrides development or production. Tests ignore that
variable deliberately and accept only `SHOESTRING_TEST_STATE_DIR`, preventing a
developer's real state directory from being selected by the test suite.

## Checks

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix precommit
```

The tests use isolated SQLite state and require no vendor executables,
credentials, Node.js, or network access.

## Production release

Build assets and a self-contained release:

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

Choose a writable state directory and generate the cookie-signing secret while
the development toolchain is available:

```sh
export SHOESTRING_STATE_DIR="$PWD/.state"
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
```

Initialize or migrate SQLite without starting the endpoint:

```sh
_build/prod/rel/shoestring/bin/shoestring eval "Shoestring.Release.migrate()"
```

Start the endpoint, which binds to `127.0.0.1:4000` by default:

```sh
export PHX_SERVER=true
_build/prod/rel/shoestring/bin/shoestring start
curl --fail http://127.0.0.1:4000/health
```

Stop or restart it without Mix, Elixir, Rust, Node.js, or an external database:

```sh
_build/prod/rel/shoestring/bin/shoestring stop
_build/prod/rel/shoestring/bin/shoestring restart
```

Optional runtime settings are `PORT`, `PHX_HOST`, `POOL_SIZE`, and
`DNS_CLUSTER_QUERY`. `SHOESTRING_BIND` may explicitly select a different IP
address; the default remains loopback. Keep `SECRET_KEY_BASE` outside source
control.

Iteration 0 intentionally contains no trajectory, capacity, run, checkpoint,
or vendor-integration tables. Those contracts belong to later milestones.
