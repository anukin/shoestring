# Production handoff path and durable lease policy

Iteration 5, work package `iter5-prod-handoff`. Two defects on the production
cross-provider handoff path, and the durable per-transfer lease policy that
replaces the wake-shaped bounds it was granting.

Base: `733c39bcb6a8e8affc02ceac4f14fb8fc7ecc926` (1340 Elixir tests, 0
failures, 1 skipped, 6 excluded; 52 Node tests, 0 failures).

Claim labels follow this directory's `README.md`.

---

## D1 — The configured `:prod` receiver probe wedged the goal's projector

**VERIFIED** (reproduced at base; see the base-regression ledger below).

This is the defect recorded as **NOT FIXED** in
`live-cross-provider-handoff.md` §7.2 ("the production receiver probe produces
a snapshot the work goal cannot project", severity *blocking for the
production path*). That record states the choice it declined to make
unilaterally: either the ledger stays canonical owner and a work goal
references it, or *"a work goal mints its own goal-scoped snapshot identity
chained to the ledger reading"*. This branch takes the second, which is what
the brief authorizes — repair under the locked ownership rule, without
weakening it.

`config/runtime.exs` wires `:handoff_observe` for `:prod` to
`{Shoestring.Cobbler.WakeupObserve, :observe, []}`, which serves the
receiver's capacity out of the `Shoestring.Harness.Observatory` ledger. Every
snapshot in that ledger is already projected as a `CapacitySnapshotRecord`
owned by the protected observatory singleton goal.

`Shoestring.Cobbler.Handoffs.persist_snapshot/6` re-appends the reading as
`capacity.snapshot_observed` under the **user's** goal, because the receiver's
lease must chain to a snapshot its own goal owns — the locked "Strict
Same-Goal Lease Ownership" rule enforced by `Shoestring.Harness.Projector`. At
base it re-appended it under the **original** snapshot id, so the projector
found a row owned by another goal and failed:

```
{:error,
 {:harness_projection_failed, 6,
  {:capacity_snapshot_not_owned, "4eb8ff24-a6b2-4988-8615-de0818850e26"},
  %ProjectorPosition{projector: "harness", last_sequence: 5, status: "failed", ...}}}
```

### Blast radius

The failure was not confined to the handoff. The poisoned event is durable, so
the goal's `harness` projector position was left at `status: "failed"` and
every **later** projection of that goal re-read the same event and failed
again. One production handoff wedged the goal's projector permanently. The
receiver run row and the dispatch row are written directly rather than through
projection, so both still existed: the goal was left half-transferred and
unprojectable.

No test caught this because the only coverage of the production wiring was a
**file contract** — `handoff_worker_test.exs` grepped `config/runtime.exs` for
the string `"WakeupObserve"`. Every behavioural handoff test injected its own
`:observe` fun returning a freshly-minted snapshot id that nobody owned, which
is exactly the case that does not reproduce the defect.

### Fix: re-identification, not relaxation

Ownership is **not weakened**. The projector's check is untouched, no unowned
snapshot is accepted, and `Handoffs.perform/3` is still reached only through
`HandoffWorker`. Instead the goal records its **own** observation of the same
reading, under an id deterministically derived from
`(goal_id, handoff_id, observed snapshot_id)` — a UUIDv5-shaped SHA-256
digest, RFC 4122 version/variant bits set so `Ecto.UUID.cast/1` accepts it.
Every field of the reading is preserved; only the identity is goal-local.

Two properties make that safe, and both are locked by tests:

- **Deterministic** — the same handoff re-observing the same reading derives
  the same id, so a crash-retry collapses on the existing idempotency key
  instead of appending a second observation. This extends the N1 coherence
  property already documented on `append_decision/7` to the
  Observatory-backed probe.
- **Unforgeably goal-local** — the id is a function of this goal and this
  handoff, so it can only ever name a row this goal owns. It cannot collide
  with the observatory's row, another goal's, or another handoff's.

Provenance is preserved rather than dropped: the observatory's own id is
recorded in the snapshot extensions under
`cobbler.handoff:observed_snapshot_id`, so a goal-local observation can be
joined back to the ledger entry it was taken from. The observatory's row is
never rewritten or taken over — asserted directly.

---

## D2 — The receiver's lease was granted under wake-shaped bounds

**VERIFIED** (base grants a 300-second deadline; measured here, and observed
live in `live-cross-provider-handoff.md` §6.3).

The 2700-second figure is not invented for this branch. §6.3 records the live
2026-09-21 transfer: receiver leg 2 ran on the 300-second default and was
stopped mid-task by it — the durable sequence `lease.renewal_due` →
`lease.expired` → `lease.checkpoint_required` → reactive `checkpoint.created`
→ `run.pausing` → `run.suspended`, correct machinery being inconvenient — and
leg 3 completed only after the operator passed
`deadline_seconds: 2700, response_budget: 400, tool_budget: 1000,
checkpoint_cadence: 50`. That exact policy is asserted expressible through the
worker here.

The receiver's `ExecutionLease` is minted from the admit decision's
`proposed_bounds`, which are copied verbatim off the `AdmissionPolicy` handed
to `AdmissionEvaluation.evaluate/5`. The only way to influence it was the
in-process `:policy` option, and `HandoffWorker` — the only production
consumer of a handoff intent — passes none. So in production every receiver
got `AdmissionPolicy.default()`, including its **300-second deadline**.

That number was chosen for a *wake*: an already-warm provider session being
resumed. A handoff receiver is a **fresh session on a different provider** —
the supervised Elf launches the process group, the provider CLI boots,
authenticates and ingests a composed continuation prompt, and only then is a
first response possible. A 300-second deadline was routinely spent on harness
startup alone, so the transfer was admitted, granted and dispatched with a
lease already dead on arrival.

**The user explicitly relaxed this to 2700 seconds (45 minutes)** to cover
harness startup plus a useful working window.

### What did NOT move

This is a *deadline*, not a budget. `Shoestring.Cobbler.HandoffLeasePolicy`
changes the wall-clock bound and nothing else:

- response budget (10), tool budget (25), checkpoint cadence (1) and reserves
  (1/1) keep their `AdmissionPolicy.default()` values;
- `stale_after_seconds` stays at 300, so a stale observation is judged exactly
  as strictly as before — a longer lease is not a licence to admit on an older
  reading;
- the reserve percentages, the delayed-recheck interval, the capability
  vocabulary and the candidate priority are not in the allow-list at all.

`to_admission_policy/2` is asserted to replace only the five lease-bound
fields, field by field.

---

## The durable per-transfer lease policy

`run.handoff` payloads may carry an optional `lease_policy` object.

| field                | range (inclusive) | default |
|----------------------|-------------------|---------|
| `deadline_seconds`   | 60 .. 14_400      | 2700    |
| `response_budget`    | 1 .. 1_000        | 10      |
| `tool_budget`        | 1 .. 10_000       | 25      |
| `checkpoint_cadence` | 1 .. 1_000        | 1       |
| `reserves.response`  | 0 .. 999          | 1       |
| `reserves.tool`      | 0 .. 9_999        | 1       |

The 60-second floor is deliberate: a deadline shorter than a minute cannot
outlive harness startup, so accepting one would only reproduce D2.

### Allow-listed, bounded, digest-covered, durable

- **Allow-listed.** An unknown key is a *rejected command*, never a dropped
  field. This is the more dangerous half of the base behaviour: base did not
  reject unknown payload keys, it silently **dropped** them, so a caller's
  `lease_policy` was accepted and then ignored entirely — and a caller
  misspelling `deadline_seconds` would have been handed the default while
  believing they had asked for something else.
- **Bounded.** Each field has a documented inclusive range, validated at
  request time so an operator learns immediately rather than at delivery.
- **Digest-covered.** It lives on the command payload, so `Command.digest/2`
  covers it. Re-submitting the same command id with a different policy is a
  conflict, not a silent re-bounding of an intent that may already be
  executing. Verified: the conflicting request errors and the original
  intent's stored policy is unchanged.
- **Durable.** `Commands` copies the validated, **normalized** policy onto the
  resolved `handoff_requested` result, which is what `Handoffs.perform/3`
  replays against. The Oban job carries no bounds of its own (asserted:
  `refute Map.has_key?(restored.args, "lease_policy")`), so enqueue, retry,
  Oban-table loss and `HandoffReconciler` boot repair all reach the identical
  policy and cannot drift from the intent.

### Reserve rule, kept safe

`Shoestring.Cobbler.LeaseBounds` fires renewal-due one reserve **early**:
`responses >= response_budget - response_reserve`. A reserve at or above its
budget therefore makes the lease renewal-due at zero spend — a receiver
granted a lease it can never produce anything under. So a reserve must be
strictly less than its budget, validated at request time rather than
discovered at execution time. The `budget - 1` boundary is asserted to be
allowed, the `budget` and `budget + 1` cases to be refused.

### Absent stays absent

An intent carrying no `lease_policy` keeps exactly the payload shape — and
therefore exactly the digest — it had before the field existed, so an
already-submitted command id still replays. Same rule as `confirmation`.

### Fail-closed on a malformed durable policy

`from_intent/1` returns an error rather than falling back to the default. A
policy validated at request time that no longer validates means the durable
record and the code disagree, and granting a lease on a guess is how a
receiver executes under bounds nobody authorized. The reason
`:invalid_handoff_lease_policy` is registered in `@permanent_tags`, so it
settles as `handoff.failed` instead of burning five delivery attempts on a row
that will not change.

### It proposes bounds; it never lifts a refusal

Asserted twins: a confirmation-class refusal (degraded receiver) and a hard
stop (incompatible receiver, even with an attributable confirmation) both stay
refused under a maximally generous policy — no receiver run, no dispatch, and
`ExecutionLeaseRecord` count zero.

---

## Base-regression ledger

Both new files were run against base `733c39b` with the implementation
stashed. Stated precisely, because "it fails on base" and "it locks a
behaviour" are not the same claim.

### `test/shoestring/cobbler/handoff_prod_observer_test.exs` — 9 of 12 fail at base

All 9 fail on the behavioural reason `{:capacity_snapshot_not_owned, _}` inside
`{:harness_projection_failed, 6, ...}`, never on a missing module or a changed
signature. **All 9 are true behavioural locks.**

The 3 that pass at base are honestly not defect locks, and are not claimed to
be: the two fail-closed probe tests (empty ledger → `:no_observation`;
foreign-provider-only ledger → `:no_observation_for_provider`) and the
`config/runtime.exs` file contract. None of them reaches the projector.

### `test/shoestring/cobbler/handoff_lease_policy_test.exs` — 17 of 23 fail at base

**TRUE BEHAVIOURAL LOCKS (12)** — each fails on a value, or on base accepting
what should be refused:

| test | base behaviour |
|---|---|
| default deadline is 2700 | `left: 300` |
| caller policy sets bounds | `left: 300` |
| partial policy takes defaults | `left: 25` (tool budget) |
| replayed delivery keeps bounds | `left: 300` |
| boot-repaired delivery identical | `left: 300` |
| stored policy normalized + digest-covered | `left: nil` (nothing stored) |
| unknown field rejects command | base returns `{:ok, ...}` |
| unknown reserve field refused | base returns `{:ok, ...}` |
| out-of-range / non-integer bounds refused | base returns `{:ok, ...}` |
| non-object policy refused | base returns `{:ok, ...}` |
| reserve at/above budget refused | base returns `{:ok, ...}` |
| malformed policy is a permanent error | `permanent_error?/1` returns `false` |

**DOCUMENTATION, NOT LOCKS (5)** — they fail at base on
`UndefinedFunctionError` because `HandoffLeasePolicy` does not exist there.
They pin the new module's surface; they do not prove a defect, and are not
claimed to: `default/0`, `from_intent/1`, `to_admission_policy/2`,
`policy_keys/0`, and the payload-shape test that calls `from_intent/1`.

**PASSES AT BASE (5)**, correctly — guards, not defect locks: the
unchanged-bounds test (base already granted 10/25/1/1), the three
refusal/hard-stop twins, and the identical-policy replay.

---

## Gate

Command: `mix precommit` (format check, `compile --warnings-as-errors`,
`mix test`, `gate_0a.node_test`). Exit status 0.

| | base `733c39b` | this branch |
|---|---|---|
| Elixir | 1340 tests, 0 failures, 1 skipped (6 excluded) | **1375 tests, 0 failures, 1 skipped (6 excluded)** |
| Node | 52 tests, 52 pass, 0 fail | **52 tests, 52 pass, 0 fail** |

The +35 is exactly the two new files (12 + 23). No existing test was modified,
skipped, retried, slept on, or had an assertion widened.

**Hermetic**: Oban `testing: :manual`, `Shoestring.Harness.Fake`, the real
Observatory ledger inside the test repo, and injected snapshot funs. No
provider CLI, no network, no provider quota, no live run.

---

## Effect on acceptance gate 7

`live-cross-provider-handoff.md` §0 records acceptance 7 as **OPEN** and gives
exactly two reasons. This branch removes both *causes*:

1. *"The receiver observation did not come from the `:prod` probe"* — because
   a ledger snapshot could not be projected under a work goal (§7.2). Fixed
   here as D1; the `:prod`-configured MFA is now driven end to end by
   `handoff_prod_observer_test.exs`.
2. *"The completing receiver leg did not go through `HandoffWorker`"* —
   because the worker had no channel for a per-transfer policy, so leg 3
   called `Handoffs.perform/3` directly. Fixed here as D2; the policy is
   carried on the durable intent and consumed by the worker, and the exact
   live leg-3 policy is asserted expressible through it.

**The gate nevertheless stays OPEN.** Removing the reasons a live run had to
bypass the production wiring is not the same as running live on it. No live
provider run was authorized in this brief and none was performed, so nothing
here demonstrates a real cross-provider transfer on the fixed path. Per the
standing rule that file states — *"a gate is not closed by demonstrating the
thing works when the production wiring is replaced"* — the corollary holds
too: a gate is not closed by fixing the wiring and never running it. Acceptance
8 is untouched by this branch.

---

## GitHub CI: two red runs on `8ac3d71`, both pre-existing intermittents

**VERIFIED.** Both CI runs for this branch's head failed, each with **exactly
one failure out of 1375**, in two **different** tests, neither of which this
branch touches. Diagnosed rather than re-run to green: no test here was
retried, slept on, skipped, or had an assertion weakened.

| run | test | failure |
|---|---|---|
| [35688724736](https://github.com/anukin/shoestring/actions/runs/35688724736) | `Shoestring.Elves.ElfTerminalCheckpointTest` (setup, `elf_terminal_checkpoint_test.exs:37`) | `** (Exqlite.Error) Database busy` on `INSERT INTO "goals"` |
| [35688738935](https://github.com/anukin/shoestring/actions/runs/35688738935) | `Shoestring.Harness.EvalMatrix.AblationTest` (`ablation_test.exs:59`) | `assert_receive {:elf_terminal, ^run_id, terminal}` — no matching message after 10000 ms |

### Why these are not branch-caused

1. **The AblationTest failure predates this branch, provably.** The identical
   test with the identical message failed on `af43f617`
   ([run 35673479881](https://github.com/anukin/shoestring/actions/runs/35673479881)),
   and `git merge-base --is-ancestor af43f617 733c39b` **succeeds** — that
   commit is an ancestor of this branch's base, so the defect exists in code
   this branch strictly builds on. The same test with the same message also
   failed on the earlier, unrelated branch `c5763f1d`
   ([run 35475309187](https://github.com/anukin/shoestring/actions/runs/35475309187)).
2. **The suite has a standing ~10% per-run flake rate.** 6 failures in the
   last 60 runs, every one of them a single failure out of ~1300, spread over
   five distinct tests — `ElfTest`, `AblationTest` (×2), `TaskClaimRaceTest`,
   `ElfTerminalCheckpointTest`. CI runs in pairs per SHA, and several other
   branches show one of the pair red and the other green on the **identical**
   SHA (`polly/iter5-lifecycle` `942846d0`, `polly/iter45-live-verification`
   `af43f617`, `polly/iter5-goal-ui-blockers` `c5763f1d`,
   `polly/iter5-checkpoint-resume-muse` `63d1839b`). At a 10% per-run rate,
   both halves of one pair failing is ≈1% — the unlucky tail, not a signal.
3. **The two failures are different tests.** A branch-caused defect is
   reproducible and would hit the same test in both runs. Two different,
   independently-flaky tests is the signature of two independent flakes.
4. **Neither failure mode can be reached from this diff.** The `lib/` change
   is confined to four Cobbler handoff files. `ElfTerminalCheckpointTest`
   never references them. The only shared surface with `AblationTest` is
   `test/support/eval_matrix_helpers.ex`, which calls `Handoffs.perform/3`
   passing an **explicit** `:policy` — and `admission_policy/2` returns a
   caller-supplied policy unexamined, exactly as the previous
   `Keyword.get(opts, :policy, AdmissionPolicy.default())` did, so the eval
   arms' lease bounds are unchanged. The other reachable change,
   `localize_snapshot/3`, re-derives a snapshot UUID that nothing on that
   path asserts on, and is pure computation (SHA-256 plus bit operations) —
   no I/O, no lock, nothing that can make an Elf miss a 10-second terminal.
5. **This branch's own new tests start nothing.** Neither
   `handoff_prod_observer_test.exs` nor `handoff_lease_policy_test.exs`
   starts a supervisor, spawns an Elf or an OS process, sleeps, or leaves a
   process running; both restore every `Application` key in `on_exit`. They
   cannot leak the DB connection or the process-group timing that these two
   failures turn on.

### Both failure mechanisms are known, documented, pre-existing hazards

The `Database busy` run shows `Client #PID<...> (:healthy_codex_storm) is
still using a connection` — a capacity monitor from
`SupervisionStormEvalTest` still holding a sandbox connection as a later
test's setup inserts. That file already carries a long comment about exactly
this hazard ("owner exited while client still holds a connection") and its
`stop_root_synchronously/2` mitigation; what CI caught is the residual race
that mitigation narrows but does not close.

The AblationTest wait is on a **real OS process group** (`python3` launched
through `Shoestring.Elves.PortRunner`) reaching terminal inside 10 s. Both CI
runs also log `spawn: Could not cd to …` from that launcher. On a loaded
shared macOS runner that budget is genuinely tight; it is a timing
dependency in the test, not a logic error in the code under test.

Both sit in test infrastructure this packet does not own, so neither is
repaired here. Reported, not fixed — and deliberately not papered over with a
retry or a longer timeout, either of which would hide a real regression later.

### Local evidence on this branch (`8ac3d71`)

| run | result |
|---|---|
| `mix test` on the two CI-failing files, ×5 | **5 of 5 green** (7 tests each run) |
| `mix test` full suite, ×3 | **3 of 3 green** — 1375 tests, 0 failures, 1 skipped (6 excluded) |
| `mix precommit` | exit 0 |

Stated plainly: local green does not *prove* the branch is innocent of
scheduling influence — adding 35 synchronous tests does lengthen the run and
shift which test follows which. What the evidence above establishes is that
both failing mechanisms exist in code this branch builds on, that one of them
is proven to have failed identically on an ancestor commit, and that no
causal path runs from this diff to either failure.

---

## Honest limitations

- **UNVERIFIED — no live cross-provider run.** The 2700-second deadline is
  justified by the cold-start argument in D2 and by the user's explicit
  instruction; it is **not** calibrated against a measured harness startup
  time. No live provider run was authorized in the brief and none was
  performed. Whether 2700 is generous or tight in practice is not established
  here.
- **The same-goal collision is NOT repaired for the wake path.**
  `live-cross-provider-handoff.md` §7.2 names `:wakeup_observe` as wired to
  the same Observatory-backed probe, and
  `Shoestring.Cobbler.Wakeups.persist_snapshot/6` re-appends an observed
  snapshot under the user goal with the original id, exactly as the handoff
  path did (REPO-INSPECTION). That is the same shape as D1. I did **not**
  reproduce it, fix it or test it: the brief scoped this packet to the handoff
  path and to staying out of other packets' changes. Reported as an untraced
  twin, not as a confirmed finding — a wake taking its observation from the
  ledger may or may not reach the projector by the same route, and I did not
  establish which.
- **REPO-INSPECTION — goals already wedged at base are not repaired.** Nothing
  here rebuilds a projector position left at `status: "failed"` by a handoff
  performed before this change. `Projector.rebuild/2` exists, but invoking it
  is a migration/repair decision that the brief did not authorize.
- **The lease policy binds to the request, not to an authenticated operator.**
  Same limit already recorded in `live-cross-provider-handoff.md` for
  `confirmation`: this application has no accounts domain and no per-request
  authenticated principal. The policy is bounded so that an unauthenticated
  caller cannot propose anything unsafe, which is the mitigation — not
  attribution.
