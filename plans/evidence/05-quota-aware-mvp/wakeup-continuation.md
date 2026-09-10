# Wakeup continuation: leased same-provider recovery context

Second-round finding 3: the admitted wake dispatched a continuation run with
`continuation: nil`, a blanket `Fake.identity()` default (including
production worker calls), and no lease for the new run — the old run's lease
was renewed while the newly dispatched run received nothing. This slice
closes that gap on `main`, directly, no PR.

## What changed (`lib/shoestring/cobbler/wakeups.ex` only, + tests)

1. **Projected continuation.** `dispatch_continuation` now resolves the
   recovery context before dispatch: `Continuation.for_goal` scoped to the
   suspended run (goal fallback per T4), or — when neither run nor goal has
   a checkpoint — a deterministic fallback checkpoint is written first
   (`CheckpointFallback` + `Checkpoints.record`, wakeup-derived id, actor
   `"wakeup"`, fail-closed on write failure) and then projected. The
   dispatched request carries the triple; the prompt is preserved for
   same-provider session reconcile.
2. **Provider identity.** Dispatch identity resolves from the suspended
   run's `provider_id` (both adapter-id and short-name forms;
   codex/claude/fake), unknown → fail-closed `{:unknown_provider, id}`.
   An explicit `:identity` opt still wins (tests pinning Fake). Production
   wakes no longer record Fake identities for real-provider runs.
3. **New-run lease.** After the run row is requested and before delivery,
   a lease is built from the fresh admit decision (bounds mapping mirrors
   `LeaseGrant`: ISO8601 deadline parse, string-keyed reserves, initial
   `:none`, extensions carrying `cobbler.lease:admission_decision_id` +
   `cobbler.lease:wakeup_id`) and granted via `Leases.grant`. The grant is
   idempotent across retries by run scope (existing grant for the new run
   row is reused — each wake perform mints a fresh evaluation, so
   decision-scoped replay cannot converge retries).
4. **Pipeline order.** Request → grant → `enqueue_for_run` (was:
   enqueue-then-nothing): no dispatch record exists for an unleased run,
   closing the crash window structurally rather than by neutralization.
5. **Claim gate preserved.** The wake path authorizes the exclusive claim
   explicitly (`DispatchGate.authorize`, read-only) before dispatch; a lost
   claim fails the wake as `{:wakeup_claim_lost, reason}`.
6. **Retry convergence.** A lease already `:renewed` (crash between renewal
   and the woken mark) is recognized and re-chained to the current fresh
   snapshot instead of re-driving `ensure_due` — the machine has no
   renewed→renewal_due edge, so without this every post-renew crash retry
   fails (verified: base errors `{:lease_not_renewable, "renewed"}`).

## Fail-on-base (VERIFIED, `lib/` stashed, tests kept)

All 6 new tests in `wakeup_continuation_test.exs` fail on the pre-fix tree
for the right behavioural reasons: nil continuation where populated
asserted (×2), Fake-default provider where codex asserted, dispatched
success where `unknown_provider` refusal asserted, dispatched success
where claim-loss refusal asserted, and `lease_not_renewable "renewed"` on
the retry path. No `NameError`/missing-module failures: true locks.

## Claim labels

- `VERIFIED`: gate figures below; fail-on-base runs this session; push
  state via `git ls-remote`.
- `REPO-INSPECTION`: code paths cited by file (no line pins — line numbers
  drift; function names are stable).
- Fixtures: synthetic UUIDs + `ManualClock`; no secrets, no real paths.
