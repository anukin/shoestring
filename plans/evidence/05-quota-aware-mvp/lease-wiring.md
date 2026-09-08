# Milestone 05: Lease Control Wired to Admission (Work Package C)

- **Status**: Work package C (Milestone 05, stacked on `e7c0b9a`: goal
  lifecycle + gated dispatch consumer + projector fix).
- **Scope**: Grant gate (admit-only issuance through the post-claim
  dispatcher hook), pure bound advancement over the live normalized-event
  buffer, renewal at the safe boundary with a Codex quota fast path, and
  hermetic ExUnit tests. Checkpoint contents (T3), projection/resume/handoff,
  and the web layer are untouched.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. Executive Summary

1. **Grant gate** (`VERIFIED`): `Shoestring.Cobbler.LeaseGrant` (pure) admits
   only `decision.result == :admit`; `defer_until` / `require_confirmation` /
   `reject` refuse with the decision reason, and a nil `admitted_snapshot_id`
   (including `confirmed_*` admits) refuses fail-closed. Admission reference
   equivalence is delegated to `Commands.validate_admission_reference/3`,
   never reimplemented.
2. **Accountant store** (`VERIFIED`): `Shoestring.Cobbler.Leases` (context, no
   process) creates the run row via `Harness.Runs.request/3` *before* any
   grant append, persists `lease.proposed → lease.granted → lease.active`
   through the trajectory writer, and reuses `ExecutionLease.new/1`,
   `EventPayload.execution_lease/1`, and `LeaseStateMachine` pre-validation.
3. **Bound advancement** (`VERIFIED`): `Shoestring.Cobbler.LeaseBounds`
   (pure) counts 1 response per `:output` message completion and 1 tool per
   `:tool` event or `:command` START→END completion over the run-id-keyed
   normalized buffer; delta frames, STARTs alone, and
   `:lifecycle`/`:artifact`/`:capacity`/`:error`/`:result` never spend.
   Renewal-due fires one reserve early (D7), edge-triggered.
4. **Renewal at the safe boundary** (`VERIFIED`):
   `Shoestring.Cobbler.LeaseRenewal` requires an already-requested safe stop
   (it never restops — it accepts no session) and the `item.completed`
   boundary before appending anything; re-evaluates against a *fresh*
   snapshot with explicit `now` + claim occupancy; `:admit` →
   `lease.renewed` chained to the new `admitted_snapshot_id`, else
   `lease.expired` → `lease.checkpoint_required` (transitions only).
5. **Quota fast path** (`VERIFIED`): Codex `:quota_refused` (from
   `usageLimitExceeded`/`rateLimitExceeded`) signals immediately with zero
   spend and re-observes + re-evaluates at once; Claude `:task_failed`
   errors spend nothing and never signal quota (by design).

---

## 2. Modules and Boundary

| Module | Role |
| :--- | :--- |
| `Shoestring.Cobbler.LeaseGrant` | Pure grant gate: admit-only, reference delegation, bounds mapping, namespaced decision refs. |
| `Shoestring.Cobbler.Leases` | Accountant store: replay lookup, run-first issuance, `lease.*` appends, snapshot chaining (`:from`-aware machine pre-validation). |
| `Shoestring.Cobbler.LeaseBounds` | Pure bound advancement: `new/1`, `advance/2`, `drain/3`, `due?/1`. |
| `Shoestring.Cobbler.LeaseRenewal` | Safe-boundary renewal: `maybe_renew/3`, `handle_quota_refusal/3`. |
| `Shoestring.Cobbler.Dispatcher` | Minimal post-claim hook: new private `maybe_grant_lease/5` + delegation to `Leases.issue_for_claim/6`; `dispatch/3` strips the opt and keeps exact old semantics. |
| `Shoestring.Cobbler` | Facade delegations: `build_lease_grant`, `grant_lease`, `renew_lease`, `handle_lease_quota`, `lease_bounds`. |

`goal_lifecycle.ex` was not touched (`REPO-INSPECTION`: no diff).
`LeaseWatcher`, `LeaseBoundary`, and session semantics are untouched — no
evaluation or effects were added there (`REPO-INSPECTION`: no diff).
`require_cobbler_command` handling is unchanged (`REPO-INSPECTION`).

### Pinned decisions — conformance

- **D1** (`VERIFIED`): `grant_id` is a fresh UUID per grant (asserted:
  two builds differ). Replay lookup reads canonical `lease.proposed`
  events first (projection-independent — events commit synchronously in the
  writer), then projected rows; replays return the existing grant with zero
  new rows/events and (on the dispatcher path) zero new runs.
- **D2** (`VERIFIED`): the run row is created via `Harness.Runs.request/3`
  before any grant append. The pure grant check runs against a provisional
  run id first, so *refused* grants create zero rows (stronger than required;
  asserted: 0 run rows + 0 lease rows on every refusal test).
- **D3** (`VERIFIED`): accountant is a context (pure `LeaseGrant` +
  transactional `Leases`); no process was added (`REPO-INSPECTION`:
  `application.ex` untouched); machine pre-validation gates every append.
- **D4** (`VERIFIED`): counting rules implemented exactly as pinned,
  including START-alone-never-counts, delta-frames-never-counted, and
  no-spend kinds. Redeliveries (same `source_event_id`) never double-spend.
- **D5** (`VERIFIED`): nil `admitted_snapshot_id` refuses fail-closed with
  `admitted_snapshot_missing` (tested with a `confirmed_*` admit).
- **D6** (`VERIFIED`): extensions carry `cobbler.lease:admission_decision_id`,
  `cobbler.lease:admission_event_id`, `cobbler.lease:candidate`
  (`"provider/adapter"`), `cobbler.lease:scope` (asserted on the built lease).
- **D7** (`VERIFIED`): due fires at `responses >= budget − reserve.response`
  OR `tools >= budget − reserve.tool` OR cadence reached; edge-triggered
  (asserted: marker once, then silence while due).

No deviations from pinned decisions.

---

## 3. Ordering Assumptions (documented limitations)

1. **Projection lags appends.** Chained transitions (`renewal_due → renewed`,
   `expired → checkpoint_required`) pre-validate with an explicit `:from`
   logical predecessor because the stored row still shows the older status
   until `Projector.project/2` runs. Appends within one flow are ordered by
   trajectory sequence (asserted: `expired.sequence < checkpoint.sequence`).
2. **Snapshot chain needs a projected row.** `chain_snapshot/3` updates
   `admitted_snapshot_id` after the `lease.renewed` append (the registry
   schema carries only the grant id), so the fresh snapshot row must already
   be projected; otherwise the FK fails and the error is returned with the
   transitions standing (events canonical, retry `chain_snapshot/3`).
3. **Checkpoint contents are T3's.** Renewal appends transitions only; T3
   consumes `checkpoint_required` and writes checkpoint contents before any
   further grant.
4. **Renewal triggers live in a future slice.** `maybe_renew/3` does not
   watch budgets or deadlines itself; the caller invokes it on due/deadline
   (deadline-triggered renewal normalizes through `renewal_due` first, so
   the audit trail shows due before renewed). No timer, poller, or backfill
   was added.
5. **Refused grants leave the claim standing.** A refusal changes no claim
   or command state; the goal stays claimed and an operator may re-decide.
   Refusals also leave zero run/lease rows (D2 ordering).

---

## 4. Verification

Gate: `mix precommit` in `$WORKSPACE` (exact command and counts in the
accompanying report).

New hermetic tests (`VERIFIED`), all using `Shoestring.Harness.Fake`
idioms, synthetic UUID fixtures (`01950000-0000-7000-8000-0000000000xx`),
or trivial local state — no provider CLI, no network:

- `test/shoestring/cobbler/lease_grant_test.exs` (7 tests) — dispatcher
  issuance with committed `proposed→granted→active` + zero Oban jobs;
  `defer_until` / `require_confirmation` / `reject` refusals with the
  decision reason and zero rows; nil-snapshot fail-closed; replay returns
  the existing grant; pure mapping (documentation).
- `test/shoestring/cobbler/lease_bounds_test.exs` (14 tests) — Fake
  sequences (normal completion, sudden quota refusal), Claude-error-not-quota,
  Codex-quota-blocks-renewal with zero spend, due-one-reserve-early on both
  axes, cadence due, run scoping + redelivery idempotence, fresh-renew vs
  refused-expire through the renewal path.
- `test/shoestring/cobbler/lease_renewal_boundary_test.exs` (6 tests) — stop
  precedes any expired append (nothing appended without
  `stop: :already_requested`); boundary wait appends nothing; non-renewable
  status rejected; fresh-snapshot chaining; expire-before-checkpoint
  ordering; immediate quota path appending only lease transitions.

Fail-on-base verification (lib/ reverted to the base commit `e7c0b9a` in
the working tree with the new test files kept, `MIX_ENV=test mix test` per
file, then lib/ restored byte-identical to the slice commit):

- `lease_grant_test.exs`: 6 dispatcher-level tests **fail on base for the
  right behavioural reason** (`{:error, {:execution_disabled, _}}` where
  `{:ok, leased}` / `{:error, {:lease_refused, _}}` is asserted, with zero
  lease/run rows) — true regression locks. The pure-mapping test errors on
  the missing module (documentation, labeled as such).
- `lease_bounds_test.exs`: all 14 tests error on base via the missing
  `LeaseBounds`/`LeaseRenewal` modules — **documentation, not locks**
  (stated in the file's moduledoc per the standing contract).
- `lease_renewal_boundary_test.exs`: all 6 tests fail on base at the
  `granted_lease` setup (`execution_disabled` where `{:ok, leased}` is
  asserted — the right upstream behavioural reason: no issuance exists on
  base), so the boundary assertions themselves are **documentation, not
  locks** (stated in the file's moduledoc).
- Pre-existing suites stay green under the full gate (dispatcher,
  lease_boundary, lease_watcher, projector, Fake suites all pass).

Fixtures use format-valid synthetic identifiers only (UUIDv7-shape
`01950000-…` for bounds/run ids, `Ecto.UUID.generate/0` for DB rows);
no credentials, tokens, paths, or machine identifiers are committed.

No live provider runs were made; no run budget was authorized.
