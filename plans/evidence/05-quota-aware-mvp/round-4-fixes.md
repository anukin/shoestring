# Round-4 loop fixes (third-review BLOCKERs, all VERIFIED)

A third review blocked iteration 5 with seven findings against `612bf14`.
Each was re-verified against the tree and fixed below. No timeout was
widened, no sleep added, no retry wrapped, no assertion softened to make
anything pass; every behavior change fails on the pre-fix tree for the
stated reason (lock ledger per section).

## R4.1 — Fresh safety decisions win over stale admissions (`wakeups.ex`)

Wake decisions were idempotent per wakeup id, so a retry re-observing
refused capacity revived the first attempt's admission. Decisions are now
idempotent per (wakeup, snapshot): a retried observation mints a new
decision, and defer/reject branches neutralize a still-pending
continuation dispatch from the earlier attempt (`effect_deferred` /
`effect_failed`; terminal rows untouched — executed work cannot be
un-executed). Adjacent gap found by the new test: `expire_lease` rejected
`renewed` leases although the machine allows expiring them; the guard now
mirrors the machine's expire-from set. Locks: fresh-refusal retry defers
with a new decision id and a neutralized dispatch; same-snapshot retry
still converges.

## R4.2 — Session lookup by dispatch id, both providers (`elf.ex`, `claude_headless/session.ex`)

Sessions register under `request.dispatch_id`, which differs from the run
row id on dispatched continuation runs — lookup tried the run id only and
missed. Resolution now tries dispatch id first, run id second, Codex
table then Claude table. Claude sessions gained a `request_safe_stop/1`
protocol (deferred kill while tools are in flight, immediate reap when
idle; replies mirror Codex). The deadline path keeps its LeaseBoundary
for Codex and requests Claude directly; virtual stop preserved when
nothing resolves. Locks: dispatch-keyed Codex double, Claude-table
double.

## R4.3 — Interrupted runs resume; full decline sequence tested (`run_state_machine`, `projector`, `wakeups`)

New machine edges `interrupted → resume/begin → starting` (an
interruption at a safe boundary pauses work cleanly rather than ending
it) plus the missing `"interrupted"` projector atom the recovery path
needs. `resume_run` accepts interrupted runs like suspended ones. The
decline → safe-stop → interrupted verdict → restart → wake sequence runs
in one test: session double stopped, terminal interrupted durable,
scheduled wake admits on fresh capacity and dispatches. The sleep card's
countdown source (wake row) is exercised, not mocked.

## R4.4 — Failed resume falls back with context (`elf.ex`)

`start_adapter`'s fresh-start fallback sent the stale original prompt.
It now composes from the request continuation (checkpoint sections when
the record loads by id, pointer + next action otherwise); requests
without a continuation are untouched. Lock: fallback start carries the
checkpoint marker, never the original prompt alone.

## R4.5 — Epoch-keyed renewal evidence (`lease_renewal.ex`)

Renewal markers were grant-keyed, so every epoch replayed the first
epoch's events. Due/renewed/expired/checkpoint-required markers now key
per (grant, snapshot); each renewal persists its snapshot
(`snapshot_observed` + projection, fixing the chain FK that previously
required pre-existing rows) and its evaluation (`admission.decided`).
New machine edge `renewed → renewal_due` plus load-gate acceptance lets
every exhaustion re-fire; renewal errors are logged with run/dispatch
context. Multi-epoch tests now assert per-epoch pairs instead of
collapsed singletons (intended change, documented in-test).

## R4.6 — UI manual runs carry leases (`run_new_live.ex`, `leases.ex`)

`gated_dispatch` went claim → enqueue with no grant. It now goes
claim → grant → deliver through `claim_and_gate` with the operator's own
prompt/workspace/policy/capabilities/dispatch/run/identity, against an
explicitly recorded manual observation snapshot (unknown-state,
operator-declared bounds mapped onto the lease contract: envelope
budgets, lease-seconds deadline, zero reserves — documented in-code, no
fabricated provider readings). `issue_request` forwards caller
extensions (the manual timeout keys were dropped). Lock: admitted submit
yields an active grant chained to the manual snapshot; fail-on-base is a
clean match failure (no lease row pre-fix).

## R4.7 — Quota-interrupted leg A (`semantic_fixture_test.exs`)

Leg A now ingests a scripted quota refusal (durable error event +
failed terminal) instead of only a failing check; the checkpoint
references it. Found while doing this: leg-A invoked `./leg_a.sh` by
relative path, which port spawn resolves against the BEAM cwd — every
prior leg-A terminal was a spawn failure, never the fixture. Absolute
path fixed it; the quota-persistence assertion guards the regression.
Recognition scoring stays prompt-text (labeled residual); turns/capacity
stay mechanical.
