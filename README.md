# Shoestring

Shoestring is a local-first control plane for supervising coding-agent work.
It gives a goal durable state, bounded execution, recovery, and a history that
does not depend on any one model conversation.

The short version:

> Shoestring is an agent supervisor, not an agent harness.

It owns goals, tasks, trajectory events, projections, artifacts, recovery, and
event-driven UI. Harness adapters are the boundary where it will later launch
and observe external coding agents such as Claude Code or Codex. Shoestring
does not itself provide a model, a coding-agent CLI, or a vendor API.

## What is implemented

The current application contains the first durable trajectory slice:

- Phoenix and LiveView provide a local control-plane UI and health endpoint.
- SQLite through Ecto stores goals, tasks, canonical trajectory events,
  artifacts, and projector positions.
- One registered writer serializes appends for each active goal. Database
  uniqueness remains the final ordering and idempotency boundary.
- Events use UUIDv4 binary IDs, UTC microsecond timestamps, and positive
  per-goal sequence numbers.
- The versioned event registry currently supports `goal.created`,
  `task.created`, `decision.recorded`, and `task.completed` at schema version
  1.
- Deterministic goal/task projectors can resume from a persisted sequence or
  rebuild derived state from canonical events.
- Artifacts are bounded, content-addressed, atomically written, and verified
  by containment, size, and SHA-256 before reads.
- JSONL export/decode is versioned, ordered, redacted, and intentionally
  non-canonical. It can replay fixtures through pure projection transitions.
- A local timeline route renders replayed events and projection status:
  `/goals/:goal_id/timeline`.

The timeline is currently a development/demo surface. The repository does not
yet contain an authentication plug, authenticated `live_session`, or
`on_mount` current-scope convention. Do not expose the timeline to untrusted or
shared users until that boundary is established.

## Architecture

```text
Phoenix LiveView timeline
          │  replay + PubSub hints
          ▼
Shoestring trajectory boundary
          │
          ├── per-goal append writers
          ├── canonical SQLite event stream
          ├── deterministic goal/task projectors
          ├── bounded artifact store
          └── ordered, redacted JSONL fixtures

Future harness adapters
          │
          └── Claude Code, Codex, and other external executors
```

This makes Shoestring closer to a supervisor/control plane than a “meta
harness.” It may supervise multiple harnesses, but the harnesses remain
replaceable execution providers. The longer-term product vocabulary is:

- **Cobbler**: a per-goal supervisor that plans, dispatches, waits, verifies,
  and replans.
- **Elf**: a bounded worker run performed through a harness adapter.
- **Harness adapter**: the provider-specific launch, observation, cancellation,
  and resume integration.
- **Trajectory**: the append-only durable record that survives restarts,
  provider changes, and model-conversation loss.

## Local development

### Requirements

The verified development environment is macOS arm64 with Elixir 1.19, Erlang/
OTP 28, and SQLite 3.43. Other platforms may work, but are not currently a
release claim. Node.js is not required by the application runtime; the checked
in asset bundle and JavaScript gate are part of development verification.

Install Elixir and Erlang, then prepare dependencies, the state directory, and
the SQLite database:

```sh
mix setup
```

Start the loopback development server:

```sh
mix phx.server
```

Open <http://127.0.0.1:4000> for the health screen. The machine-readable
health endpoint is <http://127.0.0.1:4000/health>; it returns HTTP 503 when a
required local component is unavailable.

### Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix precommit
```

Tests use isolated SQLite state and do not require vendor executables,
provider credentials, or network access.

To recreate the test database explicitly:

```sh
MIX_ENV=test mix ecto.reset
```

## Durable state

`Shoestring.State` is the single path resolver. A state root contains:

```text
<state root>/
  shoestring.db
  artifacts/
  worktrees/
  logs/
  run/
```

Defaults are environment-specific:

- Development: `<repository>/.shoestring/dev`
- Test: a unique directory under the system temporary directory
- macOS production: `~/Library/Application Support/Shoestring`
- Other Unix production: `$XDG_STATE_HOME/shoestring`, or
  `~/.local/state/shoestring`

`SHOESTRING_STATE_DIR` overrides development and production. Tests use only
`SHOESTRING_TEST_STATE_DIR`, so a real development or production state root
cannot be selected accidentally.

Artifact storage uses the configured bounded root and falls back to the
`artifacts/` directory under this same state root. Provider credentials and
authentication state are not persisted by Shoestring.

## Durable trajectory boundary

The canonical event stream is `trajectory_events`. It is append-only and
ordered by a positive sequence unique within each goal; wall-clock order is not
used for replay. Public appends assign event identity, ownership, relationships,
and sequence at the domain boundary. Raw callers cannot forge those fields.

The public domain APIs are exposed under `Shoestring.Trajectory`:

- `append/3` validates and commits one event, with bounded retry and
  idempotency behavior.
- `replay/2` returns a goal's canonical history in sequence order.
- `stream/2` returns an ordered replay-backed stream.
- `Shoestring.Trajectory.Projector` applies or rebuilds derived goal/task
  state.
- `Shoestring.Trajectory.ArtifactStore` writes and verifies bounded artifacts.
- `Shoestring.Trajectory.JSONL` exports, decodes, and replays portable
  fixtures.

Unknown event types, schema versions, malformed envelopes, incompatible
projection history, sequence gaps, and artifact integrity failures are visible
errors. Canonical history is never rewritten to make a projection or export
appear successful.

## Roadmap

The next milestone adds the execution side of the control plane:

- runs and durable run ownership;
- harness contracts and deterministic fakes;
- bounded execution leases and checkpoints;
- Oban-backed delivery and reconciliation;
- capacity observations for supported providers;
- Cobbler/Elf supervision and worktree coordination;
- Claude Code and Codex integrations;
- authenticated local UI sessions.

Capacity, harness execution, provider integrations, model-generated summaries,
embeddings, and distributed sequence allocation are deliberately outside the
current trajectory slice.

## Production release

Build assets and a self-contained release:

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

Choose a writable state directory and generate the endpoint cookie secret
while the development toolchain is available:

```sh
export SHOESTRING_STATE_DIR="$PWD/.state"
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
```

Initialize or migrate SQLite without starting the endpoint:

```sh
_build/prod/rel/shoestring/bin/shoestring eval "Shoestring.Release.migrate()"
```

Start the loopback endpoint:

```sh
export PHX_SERVER=true
_build/prod/rel/shoestring/bin/shoestring start
curl --fail http://127.0.0.1:4000/health
```

Runtime settings include `PORT`, `PHX_HOST`, `POOL_SIZE`, and
`DNS_CLUSTER_QUERY`. `SHOESTRING_BIND` can select another bind address; the
default is loopback. Keep `SECRET_KEY_BASE` outside source control.

## License

Shoestring is released under the [MIT License](LICENSE).
