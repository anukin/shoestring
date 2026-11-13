# Concepts

You can use Shoestring without this page. Read it when the CLI, the UI or a
log uses a word you do not recognise, or before you change the code.

## The idea

Shoestring is an **agent supervisor, not an agent harness**. It does not
think, write code or call a model API itself. It decides what may run, runs
agent CLIs as bounded workers, checks what they produce, and keeps a durable
record that does not depend on any one model conversation. The agent CLIs are
replaceable execution providers.

## Words you will meet

**Goal** — something you want done in one repository, recorded at a base
commit. `shoestring do` creates one per request.

**Plan, revision, task** — a goal's plan is a list of tasks, each with a
contract: what to change, which files it may touch, and which checks decide
it. Plans are immutable revisions; you approve an exact revision.

**Execution** — the run of an approved plan revision: admission, workers,
checks, review, acceptance, and the final verified commit.

**Elf** — one bounded worker run: one agent CLI, in one private Git worktree,
under a sandbox, with a time limit. Cancelling an Elf terminates its whole
process group.

**EXTERNAL** — a dispatch whose work is done outside Shoestring's guarantee,
by a person or a program Shoestring does not run, in a private Git worktree
Shoestring makes. It always waits for the person to start it; only a person
completes or abandons it, and its checks decide acceptance, as for an Elf.

**Harness adapter** — the provider-specific code that launches, observes,
cancels and resumes an agent CLI (Claude Code, Codex, opencode) and
normalizes its output into events.

**Cobbler** — the per-goal supervisor that plans, dispatches Elves, waits,
verifies and, within limits, replans.

**Check (gate)** — a command with a versioned specification (argv, kind,
timeout, output limit) that runs in its own sandbox on a worker's commit.
Checks, not the worker, decide acceptance.

**Cross-review** — a model from another vendor than the worker's reviews the
task's diff, contract and check results, with no tools, and returns
structured findings. Code decides what counts as blocking.

**Admission, reserves** — before a provider call or worker run, Shoestring
checks that provider's latest usage reading. Fresh and under 80% of the
five-hour window and 90% of the weekly window: admitted. Over a reserve:
deferred until reset. Unknown or stale: you are asked.

**Coordinator** — an agent you chat with (`shoestring chat`) that plans with
you and hands work to Shoestring. In the native chat screen it is read-only
in your checkout.

**Session, grant** — a coordinator session is bound to one repository and a
grant: the allowance you approve for it (models, purposes, number of
dispatches, how many at once, total and per-dispatch time, coordinator
turns). A coordinator cannot grant itself anything.

**Dispatch** — one unit of work a coordinator sends: **EXPLORE** (a read-only
question answered with a cited report), **IMPLEMENT** (a change, run as an
ordinary goal with checks and optional review) or **REVIEW** (another
vendor reviews a completed IMPLEMENT). States include `queued`, `running`,
`waiting`, `held` (needs your confirmation), `needs_you` and `completed`.

**Agent, team, role** — an agent is one job (Coordinator, Explorer,
Implementer, Reviewer) on one model, with its limits and sandbox
permissions. A team assigns an agent to each role. Edits create new
immutable revisions.

**Ask** — a worker's request, mid-run, to run one command outside its
sandbox (or reach a network host). It waits for you; nothing answers it on a
timer.

**Lesson** — a short rule for working in one repository, proposed by an agent
and approved by the coordinator or you, shown to later agents in that
repository only.

**Trajectory** — the append-only, per-goal event stream in SQLite that
records everything above. Projections (the current state of goals, tasks and
runs) are rebuilt from it; history is never rewritten.

## Architecture map

```text
lib/
  shoestring/
    trajectory/        append-only event stream, projectors, artifact store, JSONL export
    cobbler/           goals, intake, planning, plan executor, checks, review
    elves/             worker runs: process groups, watchdog, staleness, reconciliation
    harness/           adapters for Claude Code, Codex, opencode; usage (capacity) readings
    worktrees/         private Git worktrees and storage
    coordinator/       coordinator instructions, MCP tools, tool tokens
    conversations/     the chat screen's coordinator conversation engine
    dispatches/ grants/ lessons/ permission_asks/ agents/ agent_profiles/
    release/           doctor, bootstrap, backup, provider probes, license notices
    cli/               the `shoestring` command (shared by the checkout and releases)
  shoestring_web/      Phoenix LiveView UI, health endpoint, MCP endpoint, chat channel
  mix/tasks/           `mix shoestring.*` equivalents of each CLI command; build tasks
native/
  terminal_helper/     Rust PTY helper for interactive terminals
  chat_client/         Rust terminal chat screen (`shoestring chat`)
priv/
  coordinator/         instructions given to coordinators
  repo/migrations/     SQLite schema
rel/                   release launcher (`shoestringctl`) and bundled license texts
tools/                 release packaging, live evaluation scripts, screenshot tooling
plans/                 milestone plans and evidence records (project history)
```

The design rules that hold across the code are listed in
[AGENTS.md](../AGENTS.md) (for example: the user's checkout is never
modified; staleness is evidence, never a trigger to kill work; oversized
output fails a run rather than being truncated).

## Durable trajectory boundary

The canonical event stream is `trajectory_events`, ordered by a positive
sequence unique within each goal; wall-clock order is not used for replay.
One registered writer per active goal serializes appends, and database
uniqueness is the final ordering and idempotency boundary. Public appends
assign event identity, ownership and sequence; callers cannot forge them.

`Shoestring.Trajectory` exposes `append/3`, `replay/2` and `stream/2`;
`Shoestring.Trajectory.Projector` applies or rebuilds derived state;
`Shoestring.Trajectory.ArtifactStore` writes bounded, content-addressed,
SHA-256-verified artifacts; `Shoestring.Trajectory.JSONL` exports versioned,
redacted, non-canonical fixtures.

Unknown event types or schema versions, malformed envelopes, sequence gaps
and artifact integrity failures are visible errors. Canonical history is
never rewritten to make a projection or export appear successful.
