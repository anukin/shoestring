# Iteration 6 — plan contract and approval foundation

Branch: `polly/iter6-plan-foundation-recovery`
Base: `13ac5f056d51cbf43554adb740e6971a8d35d3aa` (merge of PR #87)

Identifier and redaction conventions for this directory are recorded in its
`README.md`. Every plan fixture here is synthetic: the base revision
`0a1b2c3d4e5f60718293a4b5c6d7e8f901234567` is a fabricated hexadecimal
string and not a commit in this repository, and identities are `human:`
placeholders. No credential, provider-generated identifier, machine
identifier, absolute home path, or hidden model reasoning appears in the
fixtures or in this document.

## Scope delivered

Work package A (goal and task contracts) plus the durable
revision/approval/rejection foundation and its event replay. Deliberately
**not** delivered: the sequential executor, the model planner boundary,
amendment/replan orchestration, and the approval UI.

| Module | Role |
| --- | --- |
| `Shoestring.Cobbler.PlanGate` | closed registry of named trusted acceptance gates |
| `Shoestring.Cobbler.PlanGraph` | DAG validation, deterministic ordering, structured errors |
| `Shoestring.Cobbler.PlanContract` | strict versioned plan value, canonical rendering, digest |
| `Shoestring.Cobbler.PlanRevisionRecord` | immutable revision row |
| `Shoestring.Cobbler.PlanDecisionRecord` | terminal human decision row |
| `Shoestring.Cobbler.Plans` | durable propose/approve/reject/read/rebuild |
| `Shoestring.Cobbler` | facade: `build_plan/1`, `propose_plan/3`, `approve_plan/3`, `reject_plan/3`, `plan_revision/3`, `list_plan_revisions/2`, `list_plan_decisions/2`, `plan_authority/2`, `rebuild_plans/2` |

Migration `20261001014010_add_cobbler_plan_revisions` creates
`cobbler_plan_revisions` and `cobbler_plan_decisions`. Event registry
entries added: `cobbler.plan.revision.created` v1, `cobbler.plan.approved`
v1, `cobbler.plan.rejected` v1. Narrative contract: `docs/plan-contract.md`.

## Gate

VERIFIED — baseline, run in `$WORKTREE` at base `13ac5f0` before any change:

```
$ mix precommit
```

exit 0; ExUnit `4 doctests, 1528 tests, 0 failures, 1 skipped (6 excluded)`.
The baseline ExUnit counts were captured from a separate `mix test` run of
the same tree (the gate's own output had already scrolled); the gate itself
exited 0.

VERIFIED — final, run in `$WORKTREE`:

```
$ mix precommit
```

exit 0; ExUnit `4 doctests, 1650 tests, 0 failures, 1 skipped (6 excluded)`;
`gate_0a.node_test` `tests 52 / pass 52 / fail 0`; `ui.node_test`
`tests 7 / pass 7 / fail 0`.

1650 − 1528 = **122 new tests**, which is exactly the sum of the new files
below. No existing test was modified, deleted, or skipped.

| Test file | Tests |
| --- | --- |
| `test/shoestring/cobbler/plan_contract_test.exs` | 46 |
| `test/shoestring/cobbler/plans_test.exs` | 34 |
| `test/shoestring/trajectory/plan_event_registry_test.exs` | 18 |
| `test/shoestring/cobbler/plan_graph_test.exs` | 12 |
| `test/shoestring/cobbler/plan_replay_test.exs` | 9 |
| `test/shoestring/cobbler/plan_approval_race_test.exs` | 3 |

## Deterministic digest

VERIFIED — `mix run --no-start` against the committed fixture plan:

```
digest=a8691128227193fe389448ab68b6457d1441de2b0944f88f9a46359265ba0c57
order=["survey", "widen", "narrow", "verify"]
bytes=3759
roundtrip_digest=a8691128227193fe389448ab68b6457d1441de2b0944f88f9a46359265ba0c57
roundtrip_identical=true
```

The canonical rendering round-trips to a byte-identical document and to the
same digest. `plan_contract_test.exs` additionally asserts that two
structurally identical plans written with different key orders produce the
same digest, and that changing a single dependency edge changes it.

## Acceptance mapping

### 1. Validation fails closed; ordering is deterministic; gates are named and trusted

| Requirement | Where it is enforced | Where it is proved |
| --- | --- | --- |
| bounded goal and task fields | `PlanContract` per-field bounds | `plan_contract_test.exs` "fail-closed input handling", "bounded tasks and budgets" |
| stable task ids | `@task_id_pattern` | "rejects a task id that is not a stable slug" |
| dependency references by id | `PlanGraph.validate/1` | `plan_graph_test.exs`, "stable task ids and dependency references" |
| duplicates, self-edges, cycles | `PlanGraph` | `plan_graph_test.exs` "structured validation failures" |
| constraints / non-goals / acceptance | `normalize_goal/1`, `normalize_acceptance/1` | "a valid plan", "named trusted acceptance gates" |
| execution and budget bounds | `normalize_execution/1`, `check_budget/2` | "bounded tasks and budgets" |
| malformed / unknown / oversized fails closed | `strict_keys/3`, `bound_input/1`, `bound_encoded/1` | "fail-closed input handling" |
| deterministic DAG ordering | Kahn, ready set broken by declared index | `plan_graph_test.exs` "deterministic ordering" |
| structured errors | tagged tuples, cycle witness | every error assertion matches a tagged tuple |
| named trusted gates only | `PlanGate` closed registry | "named trusted acceptance gates" |
| no arbitrary model commands | `scan_forbidden_keys/1` over the whole document | "no embedded commands" |
| model success is never acceptance | every task must cite >= 1 registry gate | "rejects a task that cites no gate at all" |

The cycle witness is asserted to be an *actual* cycle: the test walks the
returned ids against the fixture's edges and checks each consecutive pair
is a real edge and that the walk closes.

### 2. Immutable revisions, digest-bound approval, durable authority

| Requirement | Where it is proved |
| --- | --- |
| creation and editing both create new revisions | `plans_test.exs` "editing creates a new immutable revision" |
| the earlier revision is preserved byte for byte | "preserves the earlier revision byte for byte" |
| approval binds exact revision + digest | "approval binds an exact revision and digest" |
| stale digest rejected | "refuses an approval carrying the digest of a superseded edit" |
| bounded rejection reason | "rejection" — required, and >500 chars refused rather than truncated |
| events, not UI or process state, establish authority | `plan_replay_test.exs` |
| proposals are inert | "the slice is inert" — zero Oban jobs, runs, claims, commands |

### 3. Domain entrypoints, idempotency, concurrency, inert-slice invariants

| Requirement | Where it is proved |
| --- | --- |
| reachable outside LiveView | "the domain entrypoint is reachable without a LiveView" drives the whole lifecycle through `Shoestring.Cobbler` |
| cross-goal references rejected | "refuses a revision number that belongs to a different goal"; "rejects a parent that belongs to a different goal" |
| stale / conflicting transitions rejected | "refuses to approve a revision older than the one holding authority"; "refuses a revision that already carries a decision" |
| repeated requests cannot double-authorize | "replays an identical approval without a second event or a second decision" |
| concurrency cannot double-authorize | `plan_approval_race_test.exs`, real connections, no sandbox |
| superseded revisions cannot authorize | `Plans.authority/2` only returns `approved`; superseded status asserted |
| supersession never cancels active work | "approving a newer revision supersedes the older authority and nothing else" asserts zero jobs and zero runs |
| stable completed task identities cannot disappear | "approved task identities are stable" |
| later obligations documented | `Plans` moduledoc "Not in this slice"; `docs/plan-contract.md` closing section |

Two SQLite-enforced invariants carry the authority rules, so concurrency
loses on an index rather than on a read-then-write race:

- a partial unique index over `goal_id` where `status = 'approved'` — at
  most one approved revision per goal;
- a unique index on `plan_revision_id` in `cobbler_plan_decisions` — at
  most one terminal decision per revision.

### 4. Replay reproduces revisions, decisions, authority, contents, and digest

`plan_replay_test.exs` seeds a goal with revision 1 approved, revision 2
approved (superseding 1), and revision 3 rejected, then rebuilds purely
from `cobbler.plan.*` events. It asserts the rebuilt digest is
**recomputed from the rebuilt content** rather than copied from the event,
that the rebuilt content equals the stored content exactly, that rebuild
still converges after `Shoestring.Trajectory.Projector.rebuild/2` resets
and replays goal/task projections, that rebuild reports divergence rather
than hiding it, and that rebuild never writes.

Existing task / run / lease / recovery behaviour stays green: the final
gate ran the whole suite with zero failures and no existing test file was
touched.

## Design notes worth review

**The event carries canonical JSON, not a nested object.**
`cobbler.plan.revision.created` carries the plan as its canonical JSON
rendering. Two reasons. First, what replay reads back is then byte-identical
to what the digest was taken over; a nested object re-serialized by the JSON
column could not make that promise. Second, `Contract.safe_term?/1` bounds
nesting at depth 4, and a nested plan document exceeds it — embedding the
rendering keeps the whole-payload secret scan intact instead of weakening a
global safety check to fit one new event.

`EventRegistry.validate_plan/4` re-validates that rendering through the full
plan contract on every write and every replay, and refuses an event whose
declared digest, version, ordering, task count, or author kind disagrees
with its own content. A plan that could not be proposed today cannot be
resurrected from history.

**Contention is a structured outcome.** `mode: :immediate` can be refused
the SQLite write lock under contention, and Exqlite raises rather than
returning. `Plans.run_transaction/2` converts that into
`{:error, {:database_busy, message}}` so no exception escapes the API; the
transaction rolled back whole, and the same `proposal_id` or `decision_id`
may be retried because idempotency makes the retry converge. The race test
accepts "busy" as an outcome but never accepts two committed authorities.

**Author and decider must be `human:`.** This slice records human-authored
revisions only. A planner may be recorded inside the plan as provenance
(`planner.identity`, `planner.version`, `planner.source_context_refs`) and
authorizes nothing; `Plans` refuses a non-`human:` identity for both
`authored_by` and `decided_by`, which makes "a planner cannot approve
itself" a property of the API rather than a convention.

## Deviations and limitations

- **UNVERIFIED — spec vocabulary alignment.** The milestone's work package A
  asks for "deterministic gates" and "bounded acceptance contract" without
  fixing their representation. This implementation reads "deterministic
  gates" as references into a closed trusted registry and "bounded" as
  explicit numeric `execution.max_attempts` / `max_duration_seconds` per
  task plus a plan-level budget that must cover their sum. Both are
  judgement calls the reviewer should confirm; neither is stated verbatim in
  the milestone.
- **SCHEMA-ONLY — `PlanGate.argv/1`.** The trusted argv a gate name resolves
  to is defined and tested for resolution, but nothing in this slice
  executes a gate. The execution package owns actually running them.
- **Scope reduction has no representation.** Because an edit may not drop a
  task id that approved lineage introduced, a genuine scope reduction cannot
  be expressed yet. This is deliberate for an inert slice and is recorded as
  an obligation on the amendment package in `Plans`' moduledoc and in
  `docs/plan-contract.md`; it is **not** a relaxation the reviewer should
  expect to find here.
- **Supersession is silent by design.** It removes future authority and does
  nothing else. The dispatch package must therefore re-read the approved
  revision and its digest at dispatch time; holding a revision struct from
  earlier is not sufficient. Recorded in the same two places.
- **No planner, no executor, no UI, no amendment.** Work packages B, C, D,
  and E remain open, as does the milestone's deterministic eval matrix,
  semantic planner eval, and demo.
- **Base-revision strictness.** `goal.repository.base_revision` must be a
  resolved hexadecimal revision; `main`, `HEAD`, and `origin/main` are
  refused. A plan approved against a moving ref would silently mean
  something else tomorrow and its approval digest would stop describing the
  work. This is stricter than the milestone text and may warrant review.
