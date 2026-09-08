# Milestone 05: Continuation Projection + Resume/Handoff (Work Package F)

- **Status**: Work package F (Milestone 05, stacked on `d3ca088`: T1 goal
  lifecycle + T2 lease wiring + T5 UI merged).
- **Scope**: `handoff.created` v1 registry entry with secret scan, both
  projector arms (Harness pure + persisted, Trajectory goal/task),
  `Shoestring.Harness.Continuation` (pure projection + validation + thin
  reader), `Elves.resume_run/3` (validate → Cobbler gate → adapter resume
  → `handoff.created` for the cross-provider case), and hermetic ExUnit
  coverage wired to the `same_session_resume` / `handoff_target` Fake
  scenarios. The checkpoint WRITER (parallel T3 slice) is untouched:
  checkpoints are read only via `CheckpointRecord`.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. Modules and Boundary (`REPO-INSPECTION`)

| Module | Role |
| :--- | :--- |
| `Shoestring.Harness.Continuation` (new) | Pure `project_latest/2` (caps: history 50, `next_action` 2000 + `…[truncated]` marker, refs 32; order `projection_sequence` DESC, `id` ASC; empty → `:no_checkpoint`), `validate_resume/3` (checkpoint → decisions → confirmation → lease allowlist → session, fail-fast), `for_goal/2` / `latest_checkpoint/3` / `decision_refs/2` (bounded `CheckpointRecord` queries, run-scoped with goal fallback), `validate_attrs/1` (forbidden-key guard), `handoff_payload/1` (secret-free pointer builder). |
| `Shoestring.Trajectory.EventRegistry` | `handoff.created` v1 schema (required `handoff_id`/`run_id`/`checkpoint_id`/`from_provider_id`/`to_provider_id`/`contract_version`/`next_action`/`decision_refs`/`reason`/`extensions`; optional `prior_run_id`/`lease_grant_id`; `decision_refs` `{:array, :string}` + UUID/≤32 validator; `contract_version == 1`), plus the `handoff.` normalized prefix so `Contract.safe_term?/1` secret scanning applies. |
| `Shoestring.Harness.ProjectorTransition` | Explicit `:handoff` action: pure pointer transition, no derived-state mutation, envelope linkage checked. |
| `Shoestring.Harness.Projector` | `persist_handoff/2`: pointer guard — checkpoint must be goal-owned with `projection_sequence <= handoff sequence`, run must be goal-owned; no row written. |
| `Shoestring.Trajectory.ProjectorTransition` | `handoff.created` joins the no-op harness set, so goal/task projection advances past it. Projectors stay v1. |
| `Shoestring.Elves.resume_run/3` | Same-run resume or cross-provider handoff (mode derived from `opts[:to_provider_id]` vs the run's provider). Refusals precede any adapter call. |

`RunRequest` stays closed (no change, `REPO-INSPECTION`: no diff).
`GoalLifecycle` and `LeaseStateMachine` are called read-only (no diff).
T3-owned files (`checkpoint_fallback.ex`, `checkpoints.ex`, `wakeups.ex`,
`wakeup_worker.ex`, wakeups migration), `shoestring_web/`, eval-matrix
files, and Oban queues are untouched.

---

## 2. Pinned Decisions — Conformance

- **P1** (`VERIFIED`): `Continuation` is a new pure module; `RunRequest`
  unchanged; `Projector` untouched except the `handoff` persist arm.
  Caps are module attributes with test-visible accessors
  (`max_history/0` == 50, `max_next_action_chars/0` == 2000,
  `max_decision_refs/0` == 32).
- **P2** (`VERIFIED`): refs come only from `admission.decided` payloads
  (`decision_id`), goal-correlated, latest 32 chronological; no decided
  events → `[]`. Checkpoint free-text `decisions` never become ids
  (asserted: fixture checkpoints carry free text while refs track only
  decided events).
- **P3** (`VERIFIED`): registry schema carries exactly the pinned
  required/optional fields; unknown keys (including `transcript`,
  `raw_transcript`, `raw_output`, `stdout`, `stderr`, `messages`,
  `model_response`) are rejected as unsupported, and `safe_term?/1`
  rejects secret-bearing values. The persisted guard additionally
  requires a goal-owned checkpoint at `projection_sequence <= handoff
  sequence` (foreign/missing checkpoint fails visibly).
- **P4** (`VERIFIED`): both projector arms ship in this slice; without
  them the Trajectory projector halts on the unknown non-cobbler type
  (fail-on-base proof below). Handoff is a pointer: durable effect is the
  new run's `run.requested` with continuation (asserted in the handoff
  wiring test).
- **P5** (`VERIFIED`): stale checkpoint → `:stale_continuation`;
  superseded refs → `:decision_superseded` (exact-set match, no
  fallback); unresumable lease → `:lease_not_resumable` (allowlist
  `granted`/`active`/`renewed`; unknown future statuses refuse —
  unit-covered); confirmation pending → `:confirmation_pending`;
  same-run different session → `:session_mismatch` unless
  `:adapter_migrates_session` is true. All refusals precede the adapter
  call (`RequestLog.count == 0` asserted on every refusal test).
- **P6** (`VERIFIED`): `handing_off` untouched (terminal). Resume is
  strictly same-run (`:cross_run_resume` otherwise); handoff creates a
  NEW run of the SAME goal (`prior_run_id` recorded); cross-goal handoff
  is out of scope (no API for it).
- **P7** (`VERIFIED`): every forbidden key in continuation attrs →
  `{:error, _}` (atom and string forms); `RunRequest` struct keys
  enumerated against continuation attrs (closedness lock passes on base
  and is labeled as pre-existing); handoff payload asserted both ways
  (forbidden keys + `scan_term` clean AND required pointer fields
  present); `Contract.safe_term?/1` sweep on clean payloads.

No deviations from P1–P7.

---

## 3. Verification

Gate: `mix precommit` in `$WORKSPACE` (`VERIFIED`, exit 0):

- `format --check-formatted` clean, `compile --warnings-as-errors` clean.
- Elixir: **996 tests, 0 failures, 1 skipped (6 excluded)**.
- Node (`gate_0a.node_test`): **52 tests, 52 pass, 0 fail, 0 skipped**.

New hermetic tests (`VERIFIED`), Fake + RequestLog + fixtures only, no
provider CLI, no network (40 tests total):

- `test/shoestring/harness/continuation_test.exs` (14 tests) —
  DOCUMENTATION (new module; missing on base). Bounds, determinism,
  tie-break, empty, truncation marker, 32-ref cap, forbidden-key lock,
  struct-key enumeration, run-scope + goal fallback, decided-only refs.
- `test/shoestring/harness/continuation_resume_test.exs` (10 tests) —
  DOCUMENTATION (new module + `resume_run`). Match (exact-key
  continuation + forbidden-term sweep on adapter receipt),
  stale/superseded/stale-lease/confirmation/session-mismatch/gate
  refusals with empty logs, unknown-status unit refusal,
  migration-allowed resume, Fake `handoff_target` wiring (new run +
  `run.requested` + pointer), terminal-state handoff refusal.
- `test/shoestring/harness/handoff_privacy_test.exs` (7 tests) —
  DOCUMENTATION, except the `RunRequest` closedness test which locks
  pre-existing behaviour (passes on base, labeled in-file). Required
  present + sensitive gone, builder/registry secret refusal, payload
  sweep both directions.
- `test/shoestring/trajectory/handoff_event_test.exs` (9 tests) — 5
  TRUE REGRESSION LOCKS (exact-reason), 2 rejection-shape locks, 2
  `handoff.future_probe` SPECIFICATION locks, plus registry unit pins.

Fail-on-base verification (`VERIFIED`): `lib/` reverted to `d3ca088`
(stash, untracked `continuation.ex` included) with the new test files
kept, `MIX_ENV=test mix test` per file, then `lib/` restored
byte-identical (stash pop; the 4 suites re-run green, 40/40):

- `handoff_event_test.exs`: **9 tests, 5 failures**, each failing with
  `{:error, {:unknown_event_type, "handoff.created"}}` — the right
  behavioural reason (no registry entry on base). The other 4 pass on
  base (2 rejection-shape tests pass vacuously via unknown-type, 2
  `future_probe` specification tests pin halt-visible behaviour).
- `continuation_test.exs` + `continuation_resume_test.exs` +
  `handoff_privacy_test.exs`: fail exclusively with
  `UndefinedFunctionError` (`Continuation` module / `resume_run/2` not
  available) — DOCUMENTATION per the T1 new-surface precedent.

Fixtures use format-valid synthetic identifiers (`01950000-…` UUIDv7
shape for fixed ids, `Ecto.UUID.generate/0` for rows); no credentials,
tokens, paths, or machine identifiers are committed.

Cross-provider LIVE handoff is explicitly `UNVERIFIED`: no live runs
were made and no run budget was authorized. Hermetic coverage is
Fake-to-Fake only.

---

## 4. Twin-Check Note

`resume_capabilities/1` (resume path) twins `capabilities_from_run/1`
(Oban effect path): both map string capability items back to atoms and
drop unrecognized entries. The twin is unit-covered through every
resume/handoff test asserting adapter receipt.
