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
`planner_prompt_test.exs`/`planner_safety_test.exs`. Two
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
