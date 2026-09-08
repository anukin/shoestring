# Milestone 05: Durable Cobbler Commands, State, and Replay Foundation

- **Status**: Foundation PR (Milestone 05 Slice 2, stacked on the admission policy slice)
- **Scope**: Durable goal-scoped command ids with identical-replay / conflicting-reuse semantics, a validated command state machine with recoverable `needs_user` outcomes, atomic intent/transition/result persistence, trajectory rebuild, and a SQLite-enforced exclusive global MVP task claim. Execution remains disabled.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree), `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. Executive Summary

This slice adds the durable command foundation for Cobbler without enabling any execution:

1. **Durable goal-scoped command ids** (`VERIFIED`): `cobbler_commands` enforces
   `(goal_id, command_id)` uniqueness in SQLite. The id, type, normalized
   payload, and digest persist together with the outcome.
2. **Identical replay, conflicting reuse** (`VERIFIED`): re-submitting the same
   command id with an identical digest returns the originally recorded result
   and appends **no events**; the same id with a different digest is rejected
   as `{:command_conflict, ...}`. `respond/4` applies the same rule to user
   responses (`:replayed` vs `{:response_conflict, ...}`).
3. **Validated legal transitions** (`VERIFIED`): the pure
   `Shoestring.Cobbler.Command` machine admits `pending -> needs_user |
   resolved | rejected` (accept) and `needs_user -> resolved | rejected`
   (respond); terminal states accept nothing. Illegal transitions are rejected
   and never persisted.
4. **Recoverable needs_user** (`VERIFIED`): a command that requires an
   operator decision is recorded as `needs_user` with its reason and offered
   options. An unoffered response changes nothing, so the command stays
   recoverable; a validated response resolves it.
5. **Atomic intent/transition/result** (`VERIFIED`): the command row, any
   claim row, and all canonical trajectory events commit in ONE immediate
   SQLite write transaction or not at all. A persisted command row always
   carries its transition and result — a bare `pending` intent cannot be
   persisted (enforced by the `cobbler_commands_status_valid` check
   constraint). Rollback behavior is tested by forcing a mid-transaction
   event-insert failure: no claim, no command row, and no events survive.
6. **Trajectory rebuild** (`VERIFIED`): `Shoestring.Cobbler.Commands.rebuild/2`
   recomputes command and claim state purely from canonical `cobbler.*`
   events, validates the history through the event registry, fails loudly on
   illegal histories, and reports divergence from stored rows without
   mutating anything.
7. **Exclusive global MVP claim** (`VERIFIED`): claim acquisition inserts a
   `cobbler_task_claims` row covered by a partial unique index
   (`scope = 'global'` restricted to `status = 'active'`) inside an immediate
   write transaction. SQLite rejects the second concurrent writer on the
   index; commands never count claims first. The race is proven against a
   scratch database with real concurrent connections.
8. **No timed release** (`VERIFIED`): an active claim leaves `active` only
   through an explicit release command against the owning goal. There is no
   expiry column, no staleness trigger, and no release on ambiguous restart.
   A claim predating any plausible timer horizon remains active and refuses
   competing goals.
9. **Pending intents are inert and inspectable** (`VERIFIED`): `needs_user`
   commands are listed by `pending/2`; nothing consumes them; the full
   command flow enqueues zero Oban jobs.
10. **Execution disabled** (`VERIFIED`): submitting, responding to, or
    inspecting commands never spawns a process, enqueues a job, or dispatches
    at startup. No application child was added for commands.

---

## 2. Command Model and Boundary API

### 2.1 Modules

| Module | Role |
| :--- | :--- |
| `Shoestring.Cobbler.Command` | Pure model: validation, canonical SHA-256 digest, legal transition table, `needs_user` option/resolution tables. |
| `Shoestring.Cobbler.CommandRecord` | Ecto row for `cobbler_commands` (intent + transition + result). |
| `Shoestring.Cobbler.TaskClaimRecord` | Ecto row for `cobbler_task_claims` (the exclusive global claim). |
| `Shoestring.Cobbler.Commands` | Store boundary: `submit/3`, `respond/4`, `get/3`, `list/2`, `pending/2`, `active_claim/1`, `rebuild/2`, `validate_admission_reference/3`. |
| `Shoestring.Cobbler` | Facade delegations: `submit_command/3`, `respond_command/4`, `command/3`, `list_commands/2`, `pending_commands/2`, `active_claim/1`, `rebuild_commands/2`. |

### 2.2 Command types (MVP, execution-free)

- `task.claim` — payload: `intent`, `scope`, `candidate {provider_id,
  adapter_id}`, `admission_event_id`. Acquires the exclusive global claim when
  no active claim exists and the referenced admission decision validates.
- `task.release` — payload: `reason`. Releases the active claim when the
  releasing goal owns it.

### 2.3 Outcomes

| Status | Result kinds | Meaning |
| :--- | :--- | :--- |
| `resolved` | `claimed`, `released`, `no_active_claim`, `abandoned` | The command recorded its outcome. |
| `needs_user` | reason `claim_held` (options: `["abandon"]`) | Recoverable operator decision; inert until a response. |
| `rejected` | reason codes below | Terminal; the same command id cannot be retried. |

Claim rejection reason codes (`VERIFIED`): `admission_event_not_found` (also
covers a reference from a different goal — the lookup is goal-scoped),
`admission_event_type_invalid`, `admission_event_schema_unsupported`,
`admission_decision_id_missing`, `admission_intent_mismatch`,
`admission_scope_mismatch`, `admission_candidate_mismatch`,
`claim_owned_by_other_goal`.

---

## 3. Admit Reference Validation Before Claim

Before any claim is attempted, `validate_admission_reference/3` loads the
referenced trajectory event **within the claiming goal** and requires
(`VERIFIED`):

1. The event exists in the same goal (a cross-goal reference is
   `admission_event_not_found`).
2. `type == "admission.decided"` and `schema_version == 1`.
3. The event payload carries a `decision_id`.
4. `requested_capability` equals the command `intent`.
5. `scope` equals the command `scope`.
6. The event `candidate {provider_id, adapter_id}` equals the command
   candidate.

Only then is the claim insert attempted inside the same immediate write
transaction, so the admission reference and the claim are atomic with the
command outcome.

---

## 4. SQLite Concurrency Model

- Claim acquisition runs in `Repo.transaction(..., mode: :immediate)` — the
  write lock is taken at `BEGIN IMMEDIATE`, so the read of the active claim
  and the insert share one serialized writer window
  (`REPO-INSPECTION`: `deps/exqlite` issues `BEGIN IMMEDIATE TRANSACTION`
  for `mode: :immediate`).
- The partial unique index `cobbler_task_claims_scope_index`
  (`WHERE status = 'active'`) makes the second concurrent claim insert fail
  on the index — never through a count-then-act read (`VERIFIED` by racing
  six concurrent immediate transactions on a scratch database: exactly one
  insert succeeds).
- If the index ever rejects an insert the store degrades to the recoverable
  `needs_user` outcome (the claim demonstrably exists) instead of failing the
  command.
- Concurrent competing goal commands race deterministically: exactly one
  `resolved` claim and one `needs_user` `claim_held` outcome, one active row
  (`VERIFIED`).

## 5. Event Appends Inside the Store Transaction

The store constructs canonical event identity (sequence, id, actor) itself,
inside the same immediate transaction as the command and claim rows, because
the per-goal `Shoestring.Trajectory.Writer` process owns a separate
transaction and would deadlock against this one. This is a deliberate,
documented deviation from the writer-only trusted-identity boundary
(`REPO-INSPECTION`):

- Payload validation still goes through
  `Shoestring.Trajectory.EventRegistry.validate_payload/4` (the same write
  boundary the writer uses).
- Inserts go through `Shoestring.Trajectory.TrajectoryEvent.changeset/2`, so
  sequence and idempotency-key uniqueness remain database-enforced.
- Sequence assignment is safe: SQLite serializes write transactions; a
  concurrent writer append retries on the busy lock and re-reads the
  sequence.
- Idempotency keys: `cobbler-command-accepted:<goal>:<command>`,
  `cobbler-command-resolved:<goal>:<command>`,
  `cobbler-claim-acquired:<claim>`, `cobbler-claim-released:<claim>`.
- After commit the store broadcasts `{:trajectory_event_committed, event}`
  on the goal's trajectory topic (best-effort; a PubSub failure never fails
  a durably recorded command).

## 6. Trajectory Integration

Registered event types (`VERIFIED` in `EventRegistry` and exercised through
the standard `Trajectory.append` writer path):

| Type | Required payload fields |
| :--- | :--- |
| `cobbler.command.accepted` v1 | `command_id`, `command_type`, `command_digest`, `command_payload`, `from_status`, `to_status`, `result`; optional `claim_id` |
| `cobbler.command.resolved` v1 | `command_id`, `command_type`, `response`, `response_digest`, `from_status`, `to_status`, `result` |
| `cobbler.claim.acquired` v1 | `claim_id`, `command_id`, `intent`, `provider_id`, `admission_decision_id`, `admission_event_id` |
| `cobbler.claim.released` v1 | `claim_id`, `command_id`, `reason` |

`cobbler.` payloads are scanned for secrets and raw transcripts by the
normalized-event safety boundary (`VERIFIED`: a payload embedding an
`sk-…`-shaped credential is rejected).

## 7. Schema

`priv/repo/migrations/20260907234724_add_cobbler_commands.exs`
(`REPO-INSPECTION`, exercised by `mix test` which migrates the test
database):

- `cobbler_commands`: unique `(goal_id, command_id)`; status restricted to
  `needs_user | resolved | rejected` (a bare pending intent cannot persist);
  `result` non-null; `response` and `response_digest` paired; type and
  version checks.
- `cobbler_task_claims`: `scope = 'global'` check; `active | released`
  status; release fields consistent with status (`(status = 'active') =
  (released_at IS NULL)`) and attributed (`released_by_command_id`,
  `release_reason` required when released); **partial unique index on
  `scope` over `status = 'active'`** — the exclusivity boundary.

## 8. Honest Limitations

- **Direct run paths are not protected.** Elves, harness adapters, and the
  dispatch scheduler do not route through commands. This slice records
  intent and outcome only; it does not gate, intercept, or observe those
  paths. Nothing in this slice should be read as protecting manual or
  direct execution.
- **The goal_task projector halts on `cobbler.*` events.** Like the
  pre-existing `admission.decided` and `elf.*` families, `cobbler.*` events
  are not in the goal/task projector's known transition list, so
  `Shoestring.Trajectory.Projector` halts visibly at the last good sequence
  for goals carrying them. Command state rebuilds through
  `Shoestring.Cobbler.Commands.rebuild/2` instead. This is unchanged
  pre-existing projector behavior, not something this slice fixes.
- **One option per `needs_user` reason.** MVP offers `["abandon"]` for
  `claim_held`; the resolution table is data-driven and small. Additional
  recovery flows are future work.
- **No consumers.** Nothing reads `cobbler_commands` rows to drive behavior;
  the rows are inert by design until a later slice adds a gated consumer.
- **Publish is best-effort.** A PubSub failure after commit is logged and
  swallowed; the durable outcome stands.

## 9. Verification

- Gate: `mix precommit` (format --check-formatted, compile
  --warnings-as-errors, test, gate_0a.node_test) run in the foreground with
  stdin closed; exact counts recorded in the accompanying report.
- New hermetic tests (`VERIFIED`):
  - `test/shoestring/cobbler/command_test.exs` — pure model, digests,
    transitions, response options.
  - `test/shoestring/cobbler/commands_test.exs` — replay/conflict, atomic
    rollback, competing goals, recoverable needs_user, inert pending
    intents, stale-claim non-release, Oban-zero, rebuild/divergence, facade.
  - `test/shoestring/cobbler/task_claim_race_test.exs` — real concurrent
    connections on a scratch SQLite database: one winner per global claim,
    index rejects second active row, explicit release then re-acquire.
  - `test/shoestring/cobbler/commands_integration_test.exs` — registry
    validation, standard writer append path, safety scanning, migration
    schema checks (tables, indexes, partial unique index, check
    constraints).
- No live provider calls were made; all tests use `Shoestring.Harness.Fake`
  idioms or trivial local databases.
