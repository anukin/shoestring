# Iteration 6 — bounded, quota-aware planner boundary

Branch: `polly/iter6-planner-boundary-recovery`
Base: `df62479` (merge of PR #89)

Identifier and redaction conventions for this directory are recorded in its
`README.md`. Every plan fixture here is synthetic: the base revision
`0a1b2c3d4e5f60718293a4b5c6d7e8f901234567` is a fabricated hexadecimal
string and not a commit in this repository, and identities are `human:`
placeholders. No credential, provider-generated identifier, machine
identifier, absolute home path, or hidden model reasoning appears in the
fixtures or in this document.

## Scope delivered

Work package B (planner boundary): a real domain planner boundary
callable outside LiveView, proposals only, integrated with the merged
package-A contracts and the existing admission/lease accounting. No
dependency on unmerged PR90/package D. Deliberately **not** delivered:
the approval UI (C), the sequential executor (D), and amendment/replan
orchestration (E).

| Module | Role |
| --- | --- |
| `Shoestring.Cobbler.Planner` | claim, admit, invoke (at most twice), validate, settle, replay, rebuild |
| `Shoestring.Cobbler.PlannerAdapter` | behaviour: `identity/0`, `plan/2`, closed transport/refusal/invalid errors |
| `Shoestring.Cobbler.PlannerFixture` | deterministic scripted fixture planner (default) |
| `Shoestring.Cobbler.PlannerHttp` | configured OpenAI-compatible production adapter boundary |
| `Shoestring.Cobbler.PlannerPrompt` | bounded prompt/projection from the durable goal contract |
| `Shoestring.Cobbler.PlannerSafety` | unsafe-directive rejection before contract validation |
| `Shoestring.Cobbler.PlannerRequestRecord` | durable row: idempotency token plus attempt budget |
| `Shoestring.Cobbler` | facade: `request_plan/3`, `cancel_plan_request/4`, `planner_request/3`, `list_planner_requests/2`, `rebuild_planner/2` |

Migration `20261002183326_create_cobbler_planner_requests` creates
`cobbler_planner_requests`. Event registry entries added:
`cobbler.planner.requested` v1, `cobbler.planner.resolved` v1. Narrative
contract: `docs/planner-boundary.md`.

## Chosen API and configuration

VERIFIED — `lib/shoestring/cobbler/planner.ex`, `planner_adapter.ex`,
`planner_fixture.ex`, `planner_http.ex` as committed on this branch.

- `Cobbler.request_plan/3` takes `request_id`, a `human:` `requested_by`,
  `goal_statement`, `repository` (`base_revision` plus optional
  `remote_ref`), `acceptance` (trusted gates plus evidence), optional
  `constraints`/`non_goals`/`context_refs`/`proposal_id`/
  `parent_revision_number`/`confirmation`, and opts. Returns
  `{:ok, %{request:, revision:, outcome:, events:}}` or a structured
  `{:error, ...}` from the closed table in `docs/planner-boundary.md`.
- `config :shoestring, :planner` supplies `adapter` (default
  `PlannerFixture`, so an unconfigured node can never spend quota or
  touch the network), `model`, `provider_id`, `candidate`, and `policy`;
  per-call opts override them. `PlannerHttp` additionally reads
  `:endpoint` plus `:api_key`/`:api_key_env`, `:timeout_ms`, `:max_body`.
  Missing endpoint or credential is `:planner_not_configured` before any
  admission: zero quota consumed.
- Model-visible evidence is recorded by reference/summary only: the
  `requested` event carries goal statement, base revision, constraint
  texts, gate names, evidence texts, and `{ref, summary}` context
  references — never a transcript, never raw model output, never a
  credential, never an absolute machine path (enforced at the registry
  write boundary).

## Event and accounting path

VERIFIED — planner tests assert the exact event counts below.

- One `admission.decided` event per evaluation (one per invocation on the
  admit path; one for the blocked evaluation on the quota path), plus the
  durable two-attempt budget on the request row. Execution leases are not
  used: planning never runs an Elf. The admission gate plus the budget is
  the reservation; the settled row plus the `resolved` event is the
  release.
- Valid result: `requested` → `admission.decided` → `plan.proposed`
  (package A, human-authored, still `proposed`) → `resolved`
  (`proposed`/`valid_plan`) carrying `revision_number` and `plan_digest`.
- Quota blocked: `requested` → `admission.decided` →
  `resolved` (`manual_required`/`quota_blocked` or
  `manual_required`/`confirmation_required`) with zero invocations.
- Repair exhausted: two `admission.decided` events, `resolved`
  (`manual_required`/`repair_exhausted`) carrying the validation errors
  for user edit; the original approved state is unchanged throughout.
- Transport/refused/unsafe: `resolved` (`failed`/`transport_error`,
  `failed`/`refused`, `failed`/`unsafe_proposal`); unsafe proposals are
  never repaired.
- Cancellation settles an in-progress row to `cancelled`; a late
  settlement converges on the stored outcome. Terminal rows never move.

## Eval mapping (milestone lines 137–148)

VERIFIED — `test/shoestring/cobbler/planner_test.exs`,
`planner_concurrency_test.exs`, `planner_prompt_test.exs`,
`planner_safety_test.exs`, `planner_http_test.exs`, all hermetic
(fixture planner, scripted snapshots, scratch SQLite; no provider CLI,
no network).

| Eval | Result |
| --- | --- |
| Valid DAG | durable revision, still unapproved, human approval closes the loop |
| Cycle | validation failure after exactly 2 invocations, no revision, manual path with errors |
| Missing criterion | validation failure, manual path, 2 invocations |
| Unsafe instruction | rejected terminally (`failed`/`unsafe_proposal`), 1 invocation, no repair, no revision |
| Invalid JSON/schema | bounded repair (second attempt carries the error summaries) or manual path; never a third attempt |
| Restart | `rebuild_planner/2` reconverges on stored rows from canonical events; replayed outcomes invoke zero times |
| Quota blocked planner | `manual_required`/`quota_blocked` with zero invocations; stale capacity needs an attributable human confirmation, which then admits |
| Premature completion | N/A (executor, package D) — covered structurally: invalid output never creates an executable/persisted plan |
| Plan edit / Replan | N/A (packages C/E) — lineage rule (parent required for a second revision) enforced and tested |

Redaction is asserted in both directions: a credential anywhere in the
inputs refuses the request before claim, while the stored request keeps
the statement, revision, and context references the prompt was built
from. Absolute machine paths are refused in committed artifacts.

## Recovery notes

This worktree started clean at `df62479`. The predecessor's uncommitted
changes were supplied as the ignored scratch file `.planner-partial.patch`
(never committed) and were applied selectively with `git apply
--exclude=mix.exs --exclude=mix.lock`:

- The patch's `mix.exs`/`mix.lock` hunk adds a `Req` dependency. The
  initial recovery scope forbade new dependencies, so the first submission
  used OTP's built-in `:httpc` instead — which violated the standing rule
  that HTTP must use `Req`. A dependency check then VERIFIED `Req` is
  absent from this tree (`mix.exs` lists 15 deps without it, `mix.lock`
  has zero matches, `deps/` has no Req/Finch/Mint, and
  `Code.ensure_loaded?(Req)` is `false`). The follow-up brief explicitly
  lifted the constraint for `:req` alone, so `{:req, "~> 0.5"}` was added
  (resolved to 0.7.4 with only its required transitive deps: finch, mint,
  nimble_options, nimble_pool — no unrelated dependencies) and the
  production transport now runs entirely through `Req`. No `:httpc` use
  remains. The hermetic `plan/2` path runs the real `Req` client against
  a loopback stub (2xx decode, non-2xx transport error, invalid JSON,
  oversized-body rejection, refused connection); a real endpoint is never
  contacted.
- The patch's `Planner.consume_admission/4` returned a double-wrapped
  `{:ok, {:ok, ...}}` against the `repo.transaction/2` convention; fixed
  to the bare tuple (20 of 24 planner-test failures traced to this one
  defect — resolve behavior, tests unchanged).
- Transport/refused adapter errors previously escaped unsettled (row left
  `in_progress`); they now settle as `failed` with distinct reasons.
- Blocked settlements previously discarded the admission facts
  (`reason_code`, explanation, deferral); the public error now merges them
  over the durable replay detail, and the blocking decision id is
  attached to the row.
- The lineage check ran before the claim and masked idempotent replays
  and conflicts; it now defers to the claim when the request id was
  already claimed, and still refuses fresh silently-branching ids before
  any admission or invocation.
- The stale-snapshot helper built a snapshot the capacity contract
  rejects (`observed` + stale); it now follows the existing degraded
  convention (`degraded`/`medium`/`stale_observation`).
- Two test-setup defects were corrected without weakening any assertion:
  `claim_changeset/4` → the existing `claim_changeset/3`, and the rebuild
  test's blocked request now names its parent revision as the lineage
  rule (tested elsewhere in the same file) requires.

## Independent review findings (head 39159e6)

Review evidence: `.shoestring/review/39159e6-verdict.md` (Codex gpt-6-sol,
REQUEST_CHANGES, static review only). Each finding was traced against the
reviewed head; confirmed blockers were fixed with hermetic regressions
proven to fail at 39159e6 for the intended behavioral reason.

- **Finding 1 (aggregate quota across requests) — CONFIRMED on
  re-brief, fixed with existing mechanisms only (no new infrastructure,
  no new tables, no package-A changes).** `planner_occupancy/2` reads the
  authoritative request rows — any other `in_progress` planner request
  (any goal) occupies the shared account scope — and supplies it as the
  existing admission evaluation's explicit `:occupancy` evidence, an
  unbypassable hard stop (`scope_occupied`; confirmation cannot override
  it; snapshot reserves still evaluated when free). The requesting row is
  excluded so a bounded repair re-admits; terminal rows release; explicit
  human cancellation releases a stuck row (fail-closed with operator
  release). Blocked requests settle to the manual path with zero
  invocations and balanced accounting (`admission.decided` + `resolved`
  events, settled row, `attempts_used` 0). Prior round REPO-INSPECTION
  stands for context: no durable cross-request quota balance exists in
  the merged tree (reserves are policy thresholds, never decrementing
  balances), which is why the reservation is derived from the request
  rows rather than a new ledger.
  Regressions (proven to fail at a9a08a7 for the intended reason): a
  pre-seated occupant blocks one request with `scope_occupied` and zero
  invocations (at a9a08a7 it admitted and invoked); two concurrent
  distinct requests against a pre-seated occupant both settle blocked
  with zero invocations and zero revisions (at a9a08a7 both invoked and
  both proposed — over-admission demonstrated); an uncoordinated
  distinct race keeps accounting balanced (calls == recorded ==
  revisions, blocked attempts == 0); a cancelled occupant releases the
  scope and the next request admits with one invocation. Existing repair
  tests (no foreign occupant) guard the self-exclusion.

- **Finding 2 (unconfigured planner admitted) — CONFIRMED, fixed.**
  `request_plan/3` now validates the adapter boundary
  (`check_adapter_config/2`, via the adapter's `configured/1` where one
  exists) before claim, admission, or invocation; an unconfigured
  planner returns `:planner_not_configured` with zero rows, zero
  admission events, and zero invocations. At 39159e6 the same call
  settled a `failed`/`transport_error` row after spending an admission
  and an attempt. Regression:
  `planner_test.exs` "an unconfigured production planner is refused with
  zero accounting".
- **Finding 3 (cancel/proposal race) — CONFIRMED, fixed.** Proposal
  persistence and request settlement now commit in one immediate
  transaction (`propose_and_settle/5`); `Plans.propose/3` runs with
  publication suppressed inside it and every event publishes only after
  the outer commit. A cancellation that lands first rolls the whole
  thing back (no orphan revision, no proposal event); one that lands
  after converges on the settled request. No package-A code changed.
  Regression: `planner_test.exs` "cancellation racing a valid proposal
  leaves no orphan revision", deterministic via a cancelling
  `publish_fun` — at 39159e6 it returns cancelled with an orphan
  revision and proposal event; fixed, the proposal commits atomically
  with its settlement.
- **Finding 4 (digest omits semantic identity) — CONFIRMED, fixed.**
  `PlannerPrompt.digest_inputs/1` now binds `requested_by`,
  `proposal_id`, `parent_revision_number`, and `confirmation`
  (model-visible rendering unchanged). Another initiator's identical
  bytes are a conflict with zero invocations, never a replay of someone
  else's attribution. Regression: `planner_test.exs` "the same content
  from a different initiator is a conflict, not a replay" — at 39159e6
  the second call replayed the first initiator's recorded proposal.
- **Finding 5 (goal/base not bound) — CONFIRMED, fixed.** Validated
  output now passes `check_output_binding/2`: the returned goal
  statement and base revision must echo the request inputs exactly, else
  a `plan_goal_mismatch` contract failure routed to the single bounded
  repair. Invalid output still never persists. Regression:
  `planner_test.exs` "a plan answering a different goal or base is
  rejected, never persisted" — at 39159e6 the mismatched plan persisted
  a revision; fixed, both attempts mismatch and the request settles on
  the manual path with exactly two invocations.
- **Finding 6 (destructive wording) — CONFIRMED, fixed.**
  `PlannerSafety` gains `remov(e|ing) + branch|worktree|database` (and
  `delete + database`) phrase patterns. Regression:
  `planner_safety_test.exs` "rejects ordinary destructive wording for
  protected targets" — at 39159e6 "Remove the worktree" scanned clean;
  the companion preservation test ("Remove unused imports…") passes
  before and after.
- **Finding 7 (choice-level refusal) — CONFIRMED, fixed.**
  `PlannerHttp.decode_response/1` now also reads `finish_reason` on the
  choice (where OpenAI-compatible endpoints put it) and tolerates a
  non-map message. A content-filter refusal with empty content is
  `refused` (terminal upstream, never repaired), not
  `invalid_response`. Regression: `planner_http_test.exs` "a
  choice-level content-filter refusal is terminal, never repaired" — at
  39159e6 it decoded as `invalid_response`/`missing_content`, which
  would have triggered a repair.

## Gate

VERIFIED — baseline, run in `$WORKTREE` at base `df62479` with the work
stashed (clean tree):

```
$ mix test
```

Run twice on the clean tree: both runs `4 doctests, 1660 tests,
1 failure, 1 skipped (6 excluded)`. The failure, identified in the
second run, is `PlanApprovalRaceTest` "the same approval replayed
concurrently records one decision and one event" with outcomes
`error::database_busy, error::database_busy, error::rollback,
ok:recorded` under full-suite load. That same file in isolation:

```
$ mix test test/shoestring/cobbler/plan_approval_race_test.exs
```

`3 tests, 0 failures` (1 of 1 file-only runs).

REPO-INSPECTION — suspected pre-existing package-A contention flake
(four concurrent writers on scratch SQLite under full-suite load),
untouched by this slice. Root cause is UNVERIFIED: the
`{:rollback, _}`-shaped error escape was not traced to a source line,
and no package-A code was changed here. Stated exactly: failed in 2 of
2 full-suite baseline runs, passes in 1 of 1 file-only runs.

Update after the evidence-wording correction: a further full-suite run
on this branch (`mix precommit`, exit 2 at the ExUnit phase) failed with
the identical signature (`error::database_busy, error::database_busy,
error::rollback, ok:recorded`; all planner tests passed in that run).
Full-suite totals are now 3 failures in 4 runs with one clean pass (the
prior final gate: exit 0, 0 failures), all failures sharing the
identical signature in the same package-A test. File-only runs of that
test pass. The suspected-pre-existing characterization stands;
confirmation would require tracing the `{:rollback, _}` escape, which
is package-A work outside this slice.

VERIFIED — final, run in `$WORKTREE` on this branch:

```
$ mix precommit
```

exit 0; ExUnit `4 doctests, 1722 tests, 0 failures, 1 skipped
(6 excluded)`; `gate_0a.node_test` `tests 52 / pass 52 / fail 0`;
`ui.node_test` `tests 7 / pass 7 / fail 0`.

1722 − 1660 = **62 new tests**: 24 in `planner_test.exs`, 15 in
`planner_http_test.exs` (10 pure plus 5 Req loopback transport), 1 in
`planner_concurrency_test.exs`, and the remainder across
`planner_prompt_test.exs`/`planner_safety_test.exs`.

VERIFIED — review-fix gate, run in `$WORKTREE` on this branch after the
finding fixes:

```
$ mix precommit
```

exit 2; ExUnit `4 doctests, 1729 tests, 1 failure, 1 skipped
(6 excluded)`; `gate_0a.node_test` `tests 52 / pass 52 / fail 0`;
`ui.node_test` `tests 7 / pass 7 / fail 0`. The single failure is the
same suspected pre-existing `PlanApprovalRaceTest` contention flake
with the identical signature
(`error::database_busy, error::database_busy, error::rollback,
ok:recorded`) — the fourth full-suite occurrence overall (2 baseline,
2 branch), file-only runs of that test pass, and every one of the 69
planner-boundary tests passed in this run. Per gate honesty the failure
is reported as observed, not rerun past. 1729 − 1660 = **69 new tests**
in total: the 62 above plus 7 review regressions (4 planner boundary, 2 safety wording/preservation, 1 choice-level refusal).

TARGETED GATE for the shared-reservation change (no full-suite run this
round: Codex is separately diagnosing PlanApprovalRaceTest): `mix
compile --warnings-as-errors` clean; `mix format --check-formatted`
clean; `mix test` over the five planner files plus the three admission
files: **114 tests, 0 failures**. The three new shared-reservation tests
were proven to fail at a9a08a7 for the intended behavioral reasons (see
Finding 1 above); the pre-existing occupied-free repair tests guard the
self-exclusion. Full `mix precommit` deferred until the independent race
diagnosis lands.
2 safety wording/preservation, 1 choice-level refusal). Two
pre-existing test setups were corrected without weakening any assertion
(`claim_changeset/3` arity; the rebuild test's blocked request now names
its parent revision as the lineage rule requires). No existing test was
deleted or skipped, and the baseline intermittent race failure did not
recur in the final run. `mix.exs` gains exactly one dependency
(`{:req, "~> 0.5"}`); `mix.lock` gains exactly its five entries (req
0.7.4 plus required transitive finch, mint, nimble_options,
nimble_pool). Nothing else in the dependency set changed.

## Limitations

- The live transport path is implemented but UNVERIFIED against a real
  endpoint: validating it would spend provider quota, which this slice
  forbids. Only the wire to a real endpoint is untested; everything else
  in the path runs hermetically against a loopback stub.
- Repair carries bounded field-level summaries; deeply nested contract
  failures may need a human edit after the single repair.
- Dispatch, approval UI, and amendment orchestration remain later
  packages; proposals are inert until a human approves.
