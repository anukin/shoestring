# Final admission and wake/dispatch recovery

Four crash windows in the admission → grant → dispatch pipeline, each of
which could leave the system in a state no retry could recover from, plus
one fabricated capacity reading that two policies consumed as evidence.

Base: `6fd0ecd2e6929fcc7f393ac6e3f7166fc7a6b57d`.
Gate: `mix precommit` — **1207 tests, 0 failures, 1 skipped (6 excluded)**
plus `gate_0a.node_test` **52/52**, exit 0 (VERIFIED, this run).
Baseline on the same base in the same worktree: `mix test` — **1193 tests,
0 failures, 1 skipped (6 excluded)** (VERIFIED, this run).

No timeout was widened, no sleep added, no retry wrapped, no assertion
softened. One pre-existing assertion was deliberately reversed; it is
called out in full in §3.

---

## 1 — A confirmation retry no longer leaves unadmitted work executable

`lib/shoestring/cobbler/wakeups.ex`, `confirm_branch/7`.

`defer_branch` and `reject_branch` both neutralize a still-pending
continuation dispatch left by an earlier, since-superseded attempt.
`confirm_branch` did not. The window: an attempt admits and enqueues the
continuation dispatch, then dies before the `woken` mark (the branch runs
under no enclosing transaction, so its effects are already committed); the
retry re-observes and now demands confirmation. The dispatch row stayed
`requested`, so `DispatchWorker` would still execute it — unadmitted work
running behind an operator surface reporting "waiting for approval".

`confirm_branch` now flips a `requested` dispatch to `effect_deferred`,
matching the defer branch. Explicit approval is unchanged and unaffected:
the goal stays `sleeping` with `operator_action: :confirmation_required`,
and nothing is granted, renewed, or resumed. A dispatch past `requested`
is left exactly as it is — an executed effect cannot be un-executed, and
the fresh refusal decision is the audit trail (the residual the defer and
reject branches already document).

**Locks** (`test/shoestring/cobbler/admission_recovery_test.exs`):
`"a retry that now requires confirmation neutralizes the superseded
continuation"` (VERIFIED fails on base: base returns `branch: :admitted`);
twin `"a continuation whose effect already began is not rewritten by the
confirmation retry"` (VERIFIED fails on base, same reason).

## 2 — Wake decision replay: freshness and verdict agreement

`lib/shoestring/cobbler/wakeups.ex`, `record_decision/8` and helpers.

Decisions were idempotent per `(wakeup, snapshot_id)` through the
trajectory writer's key collapse. That is not sufficient: an adapter may
reuse a snapshot id (§4 — the Codex adapter did, for every unmonitored
probe), and even a genuinely unique reading goes stale as `now` advances.
An admit recorded at T0 was therefore replayable at T0+1h, when the fresh
evaluation of that same reading demands confirmation.

A recorded decision is now replayed only when it **agrees** with the fresh
evaluation's `result` **and** is still **fresh** — evaluated within the
snapshot's own declared `max_age_seconds`, measured against this perform's
`now`. A snapshot declaring no usable window is never replayable (unknown
freshness is not evidence of freshness). Otherwise a new decision is
appended under a decision-id-suffixed key; the superseded decision is
retained, never overwritten.

The converse still holds, and is asserted: an immediate retry re-observing
the same reading inside its window and reaching the same verdict converges
on the first decision rather than fanning out decisions — and therefore
runs.

**Locks**: `"a stale snapshot id mints a fresh decision instead of
replaying the admit"` (VERIFIED fails on base: base returns
`branch: :admitted` from the replayed admit).
`"an immediate retry on the same fresh reading replays one decision and
one run"` is **documentation, not a lock**: it does fail on base, but only
because its query helper filters on the new key format base never writes.
The substantive claims (one decision id, one continuation run, two
dispatch records) hold on base too. Stated in the test itself.

### 2b — `dispatch_id_conflict` recovery

`lib/shoestring/cobbler/wakeups.ex`, `request_run/5` → `recover_wake_run/3`.

Continuation `decision_refs` are projected from the goal's
`admission.decided` history, so a retry that legitimately mints a fresh
decision (above) rebuilds a request whose continuation no longer
byte-matches the run the first attempt persisted, and `Runs.request/3`
reports `dispatch_id_conflict`. The wake failed — and, because the
mismatch is permanent, failed again on every subsequent retry.

Recovery re-adopts the single run already bound to this wakeup's dispatch
id (the dispatch id **is** the wakeup id, so that row is unambiguously this
wake's own prior attempt). It is narrow by construction:

- it **never creates a run**, so at-most-one is preserved by construction;
- every identity field except `continuation` must already match
  (mirroring `Runs.request_identity_matches?/2` minus `:provider_id`,
  which `Runs` matched before raising); any other mismatch is a genuine
  conflict and still errors;
- the continuation is refreshed only while the run is still `requested`.
  A run whose effect has begun is live execution, not an absent one: it is
  adopted as-is and its intent is never rewritten underneath it.

Refreshing is not cosmetic. `Continuation.validate_resume/3` refuses a
resume whose `decision_refs` are superseded (`:decision_superseded`), so
re-adopting the first attempt's stale refs would hand the Elf a run it
must refuse.

**Locks**: `"a retry on a newer reading recovers its own run instead of
conflicting"` (VERIFIED fails on base with
`{:wakeup_run_failed, %Error{code: "dispatch_id_conflict"}}`); twin
`"a genuinely different run bound to the dispatch id is still a conflict"`
(VERIFIED fails on base — base cannot distinguish the two cases at all).

**Residual (UNVERIFIED impact, stated plainly).** The refresh updates the
`harness_runs` row; the `run.requested` event appended by the first
attempt still carries the earlier continuation, so row and event disagree
on `decision_refs` for a recovered run. Correcting the ledger would need a
new event type and is outside this slice's scope. The disagreement is
confined to `decision_refs` on a run that has not started.

## 3 — A grant that never reached enqueue is now recoverable

`lib/shoestring/cobbler/leases.ex` (`issue_replay/7`,
`undelivered_granted_run/3`), `lib/shoestring/cobbler/dispatcher.ex`
(comment only), `lib/shoestring/harness/dispatches.ex`
(`run_only_reconciliation_candidates/1`).

`Leases.issue_for_claim/6` persists the run row, the `run.requested` event,
and the grant; `Dispatcher` enqueues durable delivery only afterwards. A
crash in between leaves a granted, projected, `requested` run with no
`harness_dispatches` row. Two mechanisms should have recovered it and
neither could:

1. the replay branch reported `run: nil` ("replays create zero new rows"),
   so `dispatch_granted/2` skipped enqueue — and every retry skipped it
   again;
2. the reconciler's repair query required `run.projection_sequence == 0`,
   which excludes precisely this run, because appending `run.requested`
   projects it.

The grant was therefore stranded permanently.

Both are fixed, and both keep the same guard:

- `issue_replay/7` returns the run **only** while it is still `requested`
  **and** carries no dispatch row at all. An already-delivered or
  already-executing grant is still reported as `nil`, so the ordinary
  replay stays a zero-row replay and an execution under way is never
  re-enqueued nor treated as absent. Delivery itself goes through the
  idempotent `Dispatches.enqueue_for_run/2`.
- the repair query drops the projection filter and keeps
  `run.status == "requested"` as the guard that matters: any run whose
  effect has begun has already left `requested`. The projection concern the
  old filter stood for is preserved where it belongs —
  `Runs.reconcile_run/2` re-checks `projection_sequence == 0` itself before
  repairing a missing `run.requested` event.

**Deliberate reversal of a pre-existing assertion.** Commit `563e88a`
("Harden Oban dispatch recovery") flipped
`test/shoestring/harness/dispatches_test.exs`'s
`"restart reconciliation repairs a requested run whose projection already
advanced"` from asserting repair to asserting *no* repair, with no recorded
rationale; `570629c` had originally asserted repair. This change restores
the original assertion and adds the twin that states the invariant the
filter was presumably standing in for:
`"restart reconciliation leaves a run whose effect already began alone"`.
Flagged here because reversing a locked decision is a reportable deviation,
not a judgement call.

**Locks**: `"the retry delivers the stranded grant exactly once"`
(VERIFIED fails on base: `retry.dispatch` is `nil`); twin `"a grant that
already has delivery stays a zero-row replay"` PASSES on base — a
preservation test, stated as such in the test.

## 4 — The Codex probe no longer invents a reading

`lib/shoestring/harness/codex_app_server.ex`, `do_probe/1`.

With no `CodexMonitor` running — or with a monitor that answered with
anything other than a snapshot, including the ordinary "running, nothing
read yet" case — the probe returned `capacity_state: :observed`,
`confidence: :high`, `support_tier: :proactive`, and a single `five_hour`
window at `used_percent: 25.0`, under the constant snapshot id
`00000000-0000-4000-8000-000000000088`. The adapter owns no independent
quota source; that reading was fabricated.

Two policies consumed it as evidence:

- **admission** treats `:observed` + `:high` as automatically admissible,
  so a missing monitor silently authorized execution against invented
  headroom;
- **renewal** chains a lease to `admitted_snapshot_id`, and the constant id
  made every fabrication indistinguishable from the one before it, so a
  renewal could bind to a "fresh" observation never re-read — and §2's
  decision replay guard keys on that same id.

The absent/error paths now return an honest unknown: `capacity_state:
:unknown`, `confidence: :none`, `support_tier: :reactive_only`, `event:
:none`, a per-probe UUID snapshot id, and a `reason` carrying the cause
(`"monitor_not_running"`, or `"monitor_error:<atom-or-code>"` — a bounded
token, never a raw provider string, which could carry account detail into a
durably persisted snapshot). This matches the existing `ClaudeHeadless`
twin, which was already honest.

`windows` stays **empty**, not zeroed. `AdmissionEvaluation` reads a
missing or `:unknown` weekly window as `require_confirmation` ("missing
evidence stays unknown; never manufactures 0 usage"); a fabricated
`used_percent: 0.0` would instead read as abundant headroom. Missing weekly
therefore continues to require confirmation.

Real monitor readings pass through untouched.

**Locks** (`test/shoestring/harness/codex_probe_honesty_test.exs`, all
VERIFIED fail on base): `"the probe reports unknown rather than a
fabricated observation"`; `"two probes are distinguishable observations,
not one constant id"`; `"admission requires confirmation and records the
absence of evidence as such"` (base records `observed`/`high` in the
durable decision payload); `"a monitor that has no observation yet yields
unknown carrying the error reason"`. Preservation (PASSES on base):
`"a genuine monitor observation passes through untouched"` — without it the
honesty fix could "succeed" by making the adapter blind.

**Residual (REPO-INSPECTION).** `ClaudeHeadless.build_unknown_snapshot/0`
and `build_incompatible_snapshot/0` still use a constant snapshot id
(`...089`), as does `CodexAppServer.build_incompatible_snapshot/0`. Same
id-collision class as above; `claude_headless.ex` is outside this slice's
file scope and was not touched.

---

## Test inventory

| File | Tests | Fail on base |
| --- | --- | --- |
| `test/shoestring/cobbler/admission_recovery_test.exs` | 8 | 7 (1 preservation, 1 of the 7 for a non-behavioural reason — see §2) |
| `test/shoestring/harness/codex_probe_honesty_test.exs` | 5 | 4 (1 preservation) |
| `test/shoestring/harness/dispatches_test.exs` (1 added twin) | +1 | n/a (new twin) |

Base verification was run in a separate throwaway clone at
`6fd0ecd2e6929fcc7f393ac6e3f7166fc7a6b57d`; neither the user's source
checkout nor any other worktree was modified. Combined result there:
**13 tests, 11 failures** — the 2 passes are the two preservation tests.

All tests are hermetic: `Shoestring.Harness.Fake` identity, in-memory
snapshots, `Shoestring.Harness.Capacity.Codex.FakeTransport`, and recorded
Gate 0A fixtures. No provider CLI, no network, no live quota was spent.
