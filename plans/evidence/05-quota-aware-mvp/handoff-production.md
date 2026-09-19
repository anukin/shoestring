# Milestone 05: Production Cross-Provider Handoff

- **Status**: Iteration-5 production slice, stacked on `01f2a54`
  (origin/main, PR #71 merged).
- **Scope**: `Shoestring.Cobbler.Handoffs` (new), the `run.handoff` durable
  Cobbler command type, and the twin session-lookup fix in
  `Shoestring.Elves`. UI, `Shoestring.Elves.Elf`, `TerminalCheckpoint` and
  the checkpoint/resume suites are untouched.
- **Evidence labels**: `VERIFIED` (command output from this run),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. What was actually wrong (`REPO-INSPECTION`, verified before changing anything)

The prior slice built the handoff **projection** and stopped there.
`Shoestring.Elves.resume_run/2` validated the continuation, appended
`handoff.created`, created a receiver run and called `adapter.start/2`
directly. Compared against the production pattern the wake path already
established (`Shoestring.Cobbler.Wakeups.perform_wakeup/2`), four things
were missing and one was wrong:

| Gap | Base behaviour (`01f2a54`) | Consequence |
| :--- | :--- | :--- |
| No explicit production command | `resume_run/2` is a direct API call; no durable intent row | A crashed handoff had no intent to replay against |
| No receiver admission | Zero `capacity.snapshot_observed`, zero `admission.decided` for the receiver | The receiver was transferred to without anyone asking whether it had capacity, was compatible, or was supported |
| No receiver lease | `handoff.created` carried `latest_lease_id` of the **sender** | The receiver executed unbudgeted, on an allowance granted to a different run |
| No durable supervised dispatch | `adapter.start/2` called inline | No `harness_dispatches` row, no Oban delivery, no supervised Elf — the receiver ran outside the pipeline that owns process groups and cancellation |
| Session lookup keyed wrong | `live_receiver_session?/2` looked the receiver up by `stored_run.id` only | See §4 — duplicate receiver sessions |

`RunRequest`, `Continuation`, the `handoff.created` registry entry and both
projector arms were already correct and are unchanged.

---

## 2. What this slice adds (`REPO-INSPECTION`)

| Module | Role |
| :--- | :--- |
| `Shoestring.Cobbler.Command` | `run.handoff` joins the closed type set; payload normalization for `run_id`, `checkpoint_id`, the authorized `decision_refs`, `to_provider_id`, `to_adapter_id`, `scope`, `reason`, and the attributable `requested_by`. |
| `Shoestring.Cobbler.Commands` | `evaluate/4` clause recording the handoff intent, plus `validate_handoff_reference/3` (run goal-owned, checkpoint goal-owned, checkpoint belongs to that run, receiver differs from sender). Execution stays disabled: the store records intent and stops. |
| `Shoestring.Cobbler.Handoffs` (new) | `request/3` (durable intent + delivery attempt), `perform/3` (authorize → identity → Elf guard → idempotency guard → boundary → observe → admit → create → grant → point → dispatch), and `reconcile/1` (startup repair of lost delivery attempts). |
| `Shoestring.Cobbler.HandoffWorker` (new) | Oban `handoff`-queue consumer of the delivery attempt. |
| `Shoestring.Cobbler.HandoffReconciler` (new) | One `reconcile/1` pass at boot, mirroring `WakeupReconciler`. No timers. |
| `Shoestring.Elves` | Cross-provider handoff **removed** and refused (`:handoff_requires_cobbler_command`); same-provider resume unchanged. `resolve_session/2` probes dispatch id before run row id. |
| `config/config.exs`, `config/runtime.exs`, `lib/shoestring/application.ex` | `handoff` queue, prod `:handoff_observe` MFA, boot reconciler child. |
| `priv/repo/migrations/20260919034454_widen_cobbler_command_types.exs` | SQLite table rebuild widening `cobbler_commands_type_valid`. |

### Ordering, and why

`request/3` writes the intent and nothing else. `handoff_id` **is** the
command row id, so every effect in `perform/3` is keyed off durable
identity — not wall-clock time, not randomness — matching the `Wakeups`
idempotency rule. The receiver's `dispatch_id` is the same id, so
`Runs.request/3` recovers a row a crashed attempt already inserted instead
of creating a second one.

`perform/3` runs, and the order is load-bearing:

1. **authorization** — `DispatchGate.authorize/2`;
2. **receiver identity** — fail-closed on an unknown provider/adapter;
3. **one active Elf** — a live `Elves.whereis/1` pid or a
   `starting`/`running` run row refuses; nothing is cancelled, interrupted
   or signalled from here;
4. **idempotency guard** — an existing `handoff.created` under
   `handoff:<handoff_id>` converges instead of re-deciding;
5. **boundary** — the named checkpoint must still be the run's latest
   projected checkpoint (`:stale_continuation` otherwise), and the
   authorized `decision_refs` must still match projection
   (`:decision_superseded` otherwise);
6. fresh receiver observation → `capacity.snapshot_observed`;
7. `AdmissionEvaluation.evaluate/5` → `admission.decided`; non-admit
   refuses with the decision persisted;
8. re-check authorization and sender liveness, then receiver run (bounded
   transcript-free prompt) → receiver lease grant → `handoff.created` →
   `Dispatches.enqueue_for_run/2` → `Projector.project/2`.

Steps 1–3 precede step 6 deliberately: **observing a provider is itself an
effect.** It reaches a CLI and writes an auditable capacity claim into the
goal's history, so an unauthorized or unidentifiable transfer must not get
that far.

Step 4 precedes step 5 deliberately too. `perform/3` appends its own
`admission.decided`, so the refs projected after a successful transfer
necessarily differ from the ones the operator authorized against;
re-checking them on a retry would report `:decision_superseded` for every
completed handoff and a crash between pointer and dispatch could never
converge. `converge/5` decides nothing — it re-ensures the receiver's
dispatch delivery, which is idempotent.

### Honest-admission detail worth naming

`AdmissionEvaluation.normalize_candidate/1` defaults an undeclared
candidate to `support_tier: :proactive, compatibility_state: :compatible`.
That default is fail-open. `Handoffs.admit/8` therefore sources both fields
from the fresh observation, so the receiver's **measured** state decides.
A test guards exactly this (`"the receiver candidate takes its tier and
compatibility from the observation"`): if the sourcing regresses to the
defaults, a degraded observation would admit instead of asking for
confirmation, and that test fails.

`:incompatible` / `:unsupported` stay hard stops no override can lift;
degraded, unknown-capacity, stale or future-dated observations ask for an
attributable `:override`. All of that is `AdmissionEvaluation`'s existing
policy — this slice routes the receiver through it rather than
reimplementing it.

---

## 3. Deviations and limits (stated, not softened)

- **The brief named `plans/milestones/05-quota-aware-mvp.md`. That file does
  not exist** (`plans/milestones/` holds only `00a-capacity-feasibility.md`
  and `02-harness-contracts-fake.md`). The production pattern was taken from
  the committed code instead — `Shoestring.Cobbler.Wakeups`'s admit branch —
  and from this directory's existing evidence. `REPO-INSPECTION`.
- **`Elves.resume_run/2`'s cross-provider arm is removed, not gated.** A
  caller inventory (`REPO-INSPECTION`, §7) found **zero** production callers;
  every caller was a test or an eval. The arm now refuses with
  `{:error, {:handoff_requires_cobbler_command, detail}}` and the
  unsupervised implementation is deleted, because a flag would have left the
  same bypass one keyword away. Same-provider resume is untouched.
- **A refused handoff is settled and is not retried automatically.** The
  operator answers a refusal with a NEW command. `reconcile/1` deliberately
  leaves refused intents alone: re-observing and re-deciding behind the
  operator would turn an auditable refusal into a silent retry loop.
- **`reconcile/1` cannot repair a pointer whose receiver row is gone.**
  `converge/5` reports `{:handoff_receiver_missing, run_id}` rather than
  re-creating the row, because re-creating it would need a fresh admission
  that branch deliberately does not run. Since the pointer is appended after
  the row is created, this is corruption rather than a crash window; it is
  classified permanent and settles durably (§8, C2). `UNVERIFIED` in
  practice: no test forces that exact corruption.
- **The `|| :unknown` fallbacks in `admit/8` are unreachable today**:
  `CapacitySnapshot` requires `support_tier` and `compatibility_state`. They
  exist so a future nil can never become a fail-open default.
- **No live provider run.** Cross-provider handoff against a real CLI is
  `UNVERIFIED`: no live run was made, no provider quota was spent, and no run
  budget was authorized. All coverage is Fake-to-Fake.
- **Both delivery legs ARE executed end to end** in
  `test/shoestring/cobbler/handoff_worker_test.exs`: the `handoff` job, then
  the `dispatch` job, then a real supervised Elf that runs the receiver to
  `run.completed` with exactly one `run.running`. Oban stays `testing:
  :manual`, so jobs are performed explicitly rather than by a live queue —
  the queue configuration itself is asserted as a file contract, not by
  booting production.
- **UI is untouched**, per the brief. No surface renders `run.handoff`
  commands yet.

---

## 4. The session-lookup twin (R4.2's unfixed other side)

`round-4-fixes.md` R4.2 fixed this defect in `Shoestring.Elves.Elf`:
sessions register under `RunIdentity.run_id`, which
`CodexAppServer.start_session/2` and `ClaudeHeadless` set from
`request.dispatch_id` — not the run row id — so lookup must try dispatch id
first. `Elf.lookup_session_ids/2` carries that fix and the comment
explaining it.

The twin in `Shoestring.Elves` was not fixed. `live_receiver_session?/2`
probed `stored_run.id` only. Against a real adapter that lookup **always**
missed, so the handoff replay decision tree fell through to its "no evidence
the effect ran" arm and called `adapter.start/2` again — a second live
provider session for one receiver run. `resolve_session/2` (the safe-stop
path) had the same single-id lookup and now takes the run record so it can
try both.

The existing `HandoffCorrectionTest.LiveSessionStubAdapter` registers its
session under the **run row id**, which is why that suite passed green while
production duplicated. The new
`test/shoestring/harness/handoff_session_lookup_test.exs` registers under the
**dispatch id**, the way the real adapters do, and asserts
`refute receiver.dispatch_id == receiver.id` so the test cannot pass
vacuously.

---

## 5. Verification

### Gate (`VERIFIED`, review round 3)

Command, run in the worktree with a dropped-and-remigrated test database:

```
MIX_ENV=test mix ecto.drop --quiet && mix precommit
```

Exit status **0**.

- `format --check-formatted`: clean.
- `compile --warnings-as-errors`: clean.
- Elixir: **1259 tests, 0 failures, 1 skipped (6 excluded)**, 91.5s.
- Node (`gate_0a.node_test`): **tests 52, pass 52, fail 0, skipped 0**.

Run once, with a fresh platform-native state directory
(`SHOESTRING_TEST_STATE_DIR=$(mktemp -d)`, resolving under
`/var/folders/...` on this machine) and a dropped-and-remigrated database.
Not re-run to obtain a better result.

Two expected log lines appear in the gate output and are not failures: a
pre-existing sandbox-ownership warning from the capacity-storm test
(`:healthy_codex_storm`, unrelated to this slice), and one
`Exqlite.Connection ... disconnected` from the deliberate raise in
`HandoffCrashWindowTest`, which is what injecting a crash inside a sandboxed
process looks like.

Counts across the three rounds, measured each time rather than carried:

| Head | Elixir tests | Failures |
| :--- | ---: | ---: |
| `01f2a54` (origin/main, measured) | 1207 | 0 |
| `335b56a` (this PR, round 1) | 1230 | 0 |
| `640f6be` (this PR, round 2) | 1245 | 0 |
| this head (round 3) | 1259 | 0 |

1245 → 1259 is **+14**: +13 in the new `handoff_crash_window_test.exs` and
+1 in `handoff_production_test.exs` (the stale-refs test split into a
request-time rejection and a perform-time drift twin).

### Baseline (`VERIFIED`, measured — not carried forward)

The brief quoted 1207 tests as the previous gate and noted it was not rerun
on merge. It was rerun here. With this slice's tracked and untracked changes
stashed (`git stash push -u`), at `01f2a54`, after a database drop:

```
MIX_ENV=test mix test
→ 1207 tests, 0 failures, 1 skipped (6 excluded)
```

1207 → 1230 is **+23**, exactly the 19 + 4 tests this slice adds. No
existing test was deleted; one was edited (see below).

### Fail-on-base (`VERIFIED`)

**Session-lookup lock.** `lib/shoestring/elves.ex` reverted to `01f2a54`
(`git checkout 01f2a54 -- lib/shoestring/elves.ex`), new test file kept:

```
MIX_ENV=test mix test test/shoestring/harness/handoff_session_lookup_test.exs
→ 4 tests, 1 failure

1) "a receiver session registered under the dispatch id is recognized on replay"
   assert RequestLog.count(log) == 1
   left:  2
   right: 1
```

Left 2 IS the defect: base started a **second** adapter session for the same
receiver run. This is a TRUE behavioural lock — the failure is the duplicate
session, not a missing module. `lib/shoestring/elves.ex` was then restored
and confirmed byte-identical (`diff` clean), and the suite re-ran 4/4 green.

The other three arms (run-row-id registration, dead session, no session)
pass on base: DOCUMENTATION, pinning behaviour the fix must preserve.

**Production handoff suite.** All `lib/` changes stashed
(`git stash push -- lib/`):

```
MIX_ENV=test mix test test/shoestring/cobbler/handoff_production_test.exs
→ 19 tests, 19 failures
```

Representative failure, the right behavioural reason — base has no
`run.handoff` command type, so no production handoff intent can be recorded
at all:

```
1) "the command row exists; no handoff, run, lease or dispatch does"
   right: {:error, #Ecto.Changeset<
             errors: [type: {"must be one of task.claim, task.release", []}] >}
```

Honest strength ledger: because `Shoestring.Cobbler.Handoffs` is new
surface, these 19 are DOCUMENTATION in the sense the standing contract uses
— they fail on base because the surface does not exist, not because base
does the wrong thing at the same surface. Their value as locks is forward:
they assert against the durable pipeline (dispatch rows, lease rows keyed to
the receiver run, handoff-scoped `admission.decided`, refusal-with-no-effect)
that base's `resume_run/2` path never produced.

### Edited existing test (`VERIFIED`)

`test/shoestring/cobbler/command_test.exs:40` asserted the literal enum
message `"must be one of task.claim, task.release"`, which the new type
changes. It now derives the expected message from `Command.types/0` **and**
asserts the exact type list, so it remains a lock on the closed set rather
than on a frozen string. It is the only pre-existing test this slice edits.

### New tests (`VERIFIED`, hermetic — Fake adapter and local state only)

`test/shoestring/cobbler/handoff_production_test.exs` (19 tests)

- intent before effects: command row written, zero handoff/run/lease/
  dispatch/job; identical re-request replays with no new events; same-provider
  target rejected; foreign checkpoint rejected as a boundary;
- production transfer: observation + decision + receiver run + receiver-owned
  granted lease + pointer (`from`/`to`/`contract_version`/`prior_run_id`/
  `lease_grant_id`/`decision_refs`/`requested_by`) + exactly one dispatch row
  and one `dispatch`-queue job; the receiver row rests at `requested` (no
  adapter was started);
- idempotence: two performs → one handoff, one receiver, one dispatch, one
  lease, one decision, one snapshot, second outcome `:converged`;
- claim gate: a released claim refuses with zero effects;
- admission: degraded refuses with the decision persisted and no effect;
  attributable override admits and persists `override.confirmed_by`/`valid`,
  unattributed does not; incompatible is a hard stop an override cannot lift;
  unobservable and unconfigured-observer both fail closed with no decision;
  the candidate's tier/compatibility come from the observation;
- boundary/Elf: superseded checkpoint → `:stale_continuation`; `running`
  sender → `{:sender_run_active, "running"}`; live Elf →
  `{:sender_elf_active, run_id}`; revoked sender lease →
  `:lease_not_resumable` **before** any observation;
- privacy both directions: required present (checkpoint id, `next_action`
  marker, decision refs, exactly the three continuation keys) AND sensitive
  gone (sender transcript marker absent, sender session id absent from prompt,
  `provider_session_id` and extensions; `wakeup:resume_prior_session_id`
  stripped so the Elf cannot prefer `adapter.resume`; pointer payload passes
  `Contract.safe_term?/1` and carries no forbidden key).

`test/shoestring/harness/handoff_session_lookup_test.exs` (4 tests) — see §4.

Fixtures use `Ecto.UUID.generate/0` and format-valid synthetic identifiers.
No credentials, tokens, absolute paths or machine identifiers are committed.

---

## 6. Review round 2 — finding map

Independent review of `335b56a` returned REQUEST_CHANGES. What each finding
was, and what changed.

### B1 — the intent had no durable consumer

`request/3` wrote a command row and nothing read it. There was no queue, no
worker and no reconciliation, so a handoff intent could never become an
execution and a crash between request and scheduling stranded it forever.

Added: a `handoff` Oban queue, `Shoestring.Cobbler.HandoffWorker` (delivery
attempt → `perform/3`), `Handoffs.reconcile/1` (re-enqueue for every
unsettled intent with no live job), `Shoestring.Cobbler.HandoffReconciler`
(one pass at boot), and the prod `:handoff_observe` wiring. `request/3` now
commits the row and *then* inserts the job, so a failure between them leaves
a standing intent that reconcile repairs — the row is the authority, the job
is only delivery.

"Settled" is derived from canonical events, not a hidden row flag: a
`handoff.created` **plus** the receiver's dispatch row, or a recorded
non-admit decision. A pointer without its dispatch row is NOT settled and is
re-delivered; a refusal IS settled, because retrying it would re-observe and
re-decide behind the operator.

`test/shoestring/cobbler/handoff_worker_test.exs` drives **both** legs and a
real supervised Elf: request → `handoff` job → `perform/3` → `dispatch` job
→ `ElfEffect` → `run.completed` with exactly one `run.running`. Duplicate
delivery converges (one pointer, one receiver, one dispatch, one lease, one
Elf), and a restart with the job deleted still executes through
`reconcile/1`.

### B2 — the legacy unsupervised bypass

**Caller inventory** (`REPO-INSPECTION`): `Elves.resume_run/2` had **zero**
production callers. `Wakeups` has a private `resume_run/6` of a different
arity; everything else was a test or an eval.

So the arm was removed rather than gated: cross-provider now returns
`{:error, {:handoff_requires_cobbler_command, detail}}`, and
`resume_handoff/4`, `check_handoff_intent/3`, `replay_stored_receiver/7`,
`receiver_terminal?/2`, `live_receiver_session?/2`, `handoff_effect/6`,
`run_handoff_effect/7`, `append_handoff_created/5`, `replay_identity/1`,
`handoff_request/4`, `invoke_start/3`, `handoff_transition/1`,
`adapter_identity/1` and `latest_lease_id/2` are deleted. A flag would have
left the same bypass one keyword away, so there is no flag; a test asserts
that none of the old options re-opens it.

Same-provider resume is byte-for-byte unchanged, and the continuation
validation still runs FIRST, so a stale or superseded continuation reports
its own precise reason rather than being masked by the refusal.

Tests and evals were moved onto the production path rather than weakened.
`ablation_test`, `demo_test` and `semantic_fixture_test` now drive
`Eval.production_handoff!/4` — a durable command, a real receiver
observation, a persisted admission decision, the receiver's own lease and a
durable dispatch — which is *stronger* eval evidence than the previous
inline adapter start. Their leg-B evidence moved from "what the Fake
recorded" to "what was persisted", and `drive_leg_to_terminal!/2` gained a
`:request_log` so leg-B adapter tax is still observed, now inside the Elf
where the start actually happens.

Two eval consequences worth naming, both real rather than cosmetic:

* the receiver now holds a lease, so the Elf also writes a lease-boundary
  checkpoint. The ablation's terminal-checkpoint assertion now selects by
  KIND instead of by position, which is what it always meant;
* the evals pass a larger lease budget so renewal does not fire mid-leg.
  The lease is still granted, still bound to the receiver run and still
  carried on `handoff.created`; only the budget changed, and the reason is
  recorded in the helper.

### B3 — effects before authorization

`perform/3` observed the provider, persisted `capacity.snapshot_observed`,
evaluated admission and persisted `admission.decided` **before** checking
the claim or resolving the receiver identity. Observing a provider is an
effect: it reaches a CLI and writes an auditable capacity claim.

Authorization and identity now run first, and both are re-validated
immediately before the receiver row — the first irreversible step — so a
claim lost or a sender Elf started *during* admission is caught.

The tests assert absence with a **counting probe**, not only event absence:
event absence alone cannot distinguish "never observed" from "observed but
the append failed". A twin test asserts the normal admitted path still
reaches the provider exactly once and dispatches, so the reordering did not
make the happy path unreachable.

### B4 — `:decision_superseded` was unreachable

`boundary/5` projected the refs and then validated the projected refs
against themselves, so `match_decisions/2` compared a list with itself. An
admission decided between request and perform rode along silently.

The authorized refs are now frozen into the durable command payload at
request time and compared against projection at perform time. The refusal is
conservative: a changed set means the authorization no longer describes the
transfer, so it refuses and the operator re-authorizes with a new command.
Nothing re-authorizes on the operator's behalf and no "divergence accepted"
is recorded.

Because the refs are digest-covered, re-submitting the same command id with
different refs is a `:command_conflict`, not a silent widening — asserted,
along with the durable payload being the only input the perform side reads
(the Oban job args carry `goal_id`, `command_id`, `handoff_id` and nothing
else), so a restart reconstructs the authorized set from the row.

### N1 — incoherent observation/decision identity

The snapshot key carried the fresh snapshot id while the decision key
carried only the handoff id. On a retry that observed something new, the
observation appended and the decision collapsed onto the first one, leaving
a history that showed a new reading beside a verdict never taken on it.

Both keys now share `(handoff_id, snapshot_id)`. A crash-retry that
re-observes the same reading collapses BOTH appends; a retry that genuinely
observes something new appends a new observation AND the decision taken on
it. Freshness semantics are unchanged — the pairing is what was fixed.

### N2 — overclaimed lock ledgers

`handoff_production_test.exs` claimed every test was a true baseline lock.
Corrected: against `01f2a54` these are **DOCUMENTATION** (missing module,
rejected command-type enum — a missing surface is not evidence that base did
the wrong thing at that surface). The genuine behavioural locks are stated
against `335b56a`, group by group, with their exact failure output in §7.
`handoff_correction_test.exs` got the same treatment.

### N3 — vacuous guard

`session_ids(stored_run) != [] and Enum.any?(...)` — `Enum.any?/2` on an
empty list is already `false`. Removed with the whole of
`live_receiver_session?/2` under B2.

### N4 — check-then-act on sender status

The guard is a check, not a lock, and the moduledoc now says so instead of
implying otherwise. It runs before the observation and again immediately
before the receiver row. That narrows the window; it does not close it,
because nothing here holds a lock on the Elf registry or the claim row.

What backstops the residual window is named explicitly and is not this
module: `Dispatches.prepare_for_effect/2` claims the dispatch row, and
`Elves.start_elf/3` registers by run id and returns
`{:ok, :already_running, pid}` rather than starting a second Elf. Two Elves
for one run are prevented there. This module still never pauses or cancels
the sender — a handoff requested while the sender is live is refused, not
forced.

---

## 7. Fail-on-prior-head proof (review round 2) (`VERIFIED`)

`lib/` reverted to `335b56a` (`git checkout 335b56a -- lib/`), new tests
kept, then restored and re-run green (50/50 across the four files).

`handoff_production_test.exs` → **32 tests, 16 failures**. Representative,
one per finding:

```
B3  "a lost claim refuses BEFORE the provider is observed"
    assert probe.count.() == 0       left: 1   right: 0
B3  "an unknown receiver provider refuses BEFORE the provider is observed"
    right: {:ok, ... reason_code: "snapshot_provider_mismatch"}
B4  "a decision recorded between request and perform refuses as superseded"
    left: {:error, :decision_superseded}   right: {:ok, ...}
B4  "non-UUID refs are refused at request time"
    left: {:error, changeset}              right: {:ok, ...}
B1  "the command row exists; no handoff, run, lease or dispatch does"
    assert [job] = Repo.all(Job)   left: [job]   right: []
B1  "an intent whose delivery attempt was lost gets one back"
    ** (UndefinedFunctionError) Shoestring.Cobbler.Handoffs.reconcile/0
```

Left 1 on the probe counter IS the defect: the prior head reached the
provider before checking authorization. `snapshot_provider_mismatch` is the
same defect for identity — it observed and admitted a provider it could not
even identify.

`handoff_worker_test.exs` → **6 tests, 5 failures**, all because no delivery
attempt exists to perform (`{:ok, %{job: handoff_job}}` does not match, and
`reconcile/0` is undefined). The sixth is the config file contract, which
passes at both heads (DOCUMENTATION).

`handoff_correction_test.exs` → **6 tests, 3 failures**. All three
cross-provider refusal tests fail with `right: {:ok, ...}` — the prior head
returned success and started a Fake session. That is the bypass itself.

`safe_stop_session_lookup_test.exs` → **6 tests, 2 failures** at BOTH
`335b56a` and `01f2a54`:

```
"a session registered under the dispatch id is reachable"
    left: {:ok, :stop_requested}   right: {:error, :session_not_found}
"the run row's own ids are what get probed, in dispatch-first order"
    assert_receive {:safe_stop_requested, ^dispatch_session}
```

This is the R4.2 twin, still a TRUE behavioural lock. The round-1 commit
fixed `resolve_session/2` for the default Codex lookup but still handed a
custom `:session_resolver` only the run row id; a test registry therefore
could not behave like the real one. Both now probe dispatch id first, run
row id second.

The four remaining tests in that file (run-row-id registration, no session,
explicit `:session_pid`, deduplicated probe) pass at both heads —
DOCUMENTATION.

---

## 8. Review round 3 — finding map

Independent review of `640f6be` returned two blockers.

### C1 — the handoff refused itself forever after a crash

`transfer/10` commits its own `admission.decided` BEFORE the receiver row,
the lease and the pointer. A crash in that gap leaves a committed decision
and no pointer, so the retry misses the idempotency guard and lands back on
the boundary check — where `boundary/5` compared the frozen authorized refs
against an *unfiltered* `Continuation.decision_refs/2`, and therefore showed
the handoff its own decision as an external change.

That is permanent, not transient: every retry re-reads the same committed
decision and returns `:decision_superseded`. Combined with C2, the intent
was also re-enqueued forever. The handoff could never complete and could
never be repaired — only abandoned by hand.

Fixed by giving `Continuation.decision_refs/3` an `:exclude_key_prefix`
option and having `boundary/6` pass this handoff's own decision-key prefix.
The exclusion is scoped to one handoff id, and a handoff can only ever write
under its own prefix, so it **cannot** hide an external change: a decision
from an operator, a wake, or a different handoff keeps a different key,
stays in the comparison, and still supersedes. That is asserted directly
(`"a GENUINELY external decision in the same window still refuses"`).

The same filtered set feeds `project_latest/2`, which is what makes the
receiver's continuation byte-identical across retries — the property
`Runs.request/3` needs to recover the row a crashed attempt inserted instead
of reporting a dispatch-id conflict against a drifted request.

**Injection, not simulation.** `perform/3` documents `:repo`, so the crash
goes through that real seam: `CrashingRepo` delegates to `Shoestring.Repo`
except for the receiver-run insert, where it raises. The decision is
appended through the trajectory writer (global repo) and genuinely commits
before the raise, so the test reproduces the window rather than
reconstructing it. The proof asserts the wreckage (decision present, no
pointer, no run, no lease, no dispatch), then that the retry completes into
**exactly one** receiver, lease, pointer and dispatch, and separately that
the repaired delivery runs end to end into one supervised Elf with exactly
one `run.running`. A two-crashes-in-a-row case is covered too.

### C2 — permanent errors never settled

`:stale_continuation`, a genuinely superseded authorization, an unnameable
receiver and the receiver-missing converge case all returned an error that
no retry could clear — while the worker burned its five attempts and
`reconcile/1` re-enqueued the intent on every boot, forever.

Fixed with a durable, explained terminal record on the **trajectory**, not a
row flag and not a log line: a new `handoff.failed` v1 event
(`handoff-failed:<handoff_id>`), carrying the machine-readable `reason`, a
bounded human `detail`, the run and checkpoint it concerned, and the
requesting identity. Registry entry plus the trajectory projector's no-op
set; the harness projector already ignores unknown types, and no row is
written.

Three consequences, all required rather than incidental:

* `settled?/2` reads it, so `reconcile/1` never resurrects a failed intent —
  not on the next pass, not after a restart, not after the job table is
  cleared. That last case is why cancelling the Oban job alone is
  insufficient, and it is asserted explicitly by deleting every job and
  reconciling three times plus booting `HandoffReconciler`;
* `HandoffWorker` cancels instead of retrying, via the public
  `Handoffs.permanent_error?/1`;
* the reason is operator-visible next to the `handoff.created` that would
  have been there had it succeeded — no row-only hidden truth.

**Receiver-missing, assessed rather than assumed.** The pointer is appended
*after* the receiver row is created, so a pointer with no row is not a crash
window — the row was removed underneath. `converge/5` cannot rebuild it
without a fresh admission it deliberately does not run, so this is classified
permanent and settles. Stated as an assessment, and still `UNVERIFIED` in
practice: no test forces that exact corruption.

**The classification is the load-bearing part**, so the transient side is
asserted as hard as the permanent side. A live sender, an unreachable probe
and a crash mid-flight each record no `handoff.failed`, are retried rather
than cancelled by the worker, and are re-enqueued by `reconcile/1` — and the
live-sender case then completes once the sender parks, proving the intent
was genuinely still alive and not merely un-settled.

### Nits

* **`session_resolver` semantics** — it replaces the registry lookup, not the
  id list, so it is now called once per candidate id in dispatch-first order.
  Documented at the call site: it must be a pure lookup returning a pid or
  nil and is safe to call more than once. The previous single call was an
  accident of the single-id bug, not a contract. Nothing else calls it.
* **Duplicated `32`** — `Command`'s `@max_decision_refs` now reads
  `Continuation.max_decision_refs()` at compile time instead of restating the
  literal, so the authorized ref cap and what projection can produce cannot
  drift.
* **Request-time refs failed slow** — taken. `validate_handoff_reference/3`
  now rejects an authorization that is already stale on arrival
  (`handoff_decision_refs_stale`), so the operator is told at request time
  instead of after the intent is recorded, queued, delivered and permanently
  failed. This does **not** replace the perform-time check: a request valid
  when written and superseded afterwards still refuses at perform, and both
  halves are asserted.

---

## 9. Fail-on-prior-head proof (review round 3) (`VERIFIED`)

`lib/` reverted to `640f6be` (`git checkout 640f6be -- lib/`), the new test
file kept, then restored and re-run green (13/13).

`handoff_crash_window_test.exs` → **13 tests, 10 failures**:

```
C1  "a crash after admission recovers into ONE receiver, lease, pointer and dispatch"
    left: {:ok, %{outcome: :dispatched, run: receiver}}
    right: {:error, :decision_superseded}
C1  "recovery runs end to end: the repaired delivery starts one supervised Elf"
    assert :ok = perform_delivery(handoff_job)
    left: :ok   right: {:error, :decision_superseded}
C1  "two crashes in a row still recover to exactly one transfer"
    (the second attempt refuses before reaching the insert, so no raise)
C2  "reconcile NEVER resurrects a permanently failed intent, on any pass"
    left: {:ok, %{repaired_count: 0, failures: []}}
    right: {:ok, %{repaired_count: 1, failures: []}}
C2  "the worker cancels rather than retrying an error no retry can clear"
    left: {:cancel, :stale_continuation}   right: {:error, :stale_continuation}
C2  "a moved boundary records handoff.failed with an operator-visible reason"
    assert [failure] = failure_events(...)   left: [failure]   right: []
```

`right: {:error, :decision_superseded}` where a completed transfer is
asserted IS C1 — the handoff refusing itself. `repaired_count: 1` where 0 is
asserted IS C2 — reconcile resurrecting a failure that can never succeed.

The three that PASS at `640f6be` are DOCUMENTATION and are labelled as such:
the external-change twin, the live-sender transient twin, and the
crash-is-transient case. They pin behaviour the repair must not break, and
their passing is the evidence that the C1 exclusion did not simply disable
the supersede check.

`handoff_production_test.exs` → **1 failure** at `640f6be`: `"an intent
authorizing refs that never existed is rejected at request time"`, which
that head accepted and queued.

---

## 10. Twin checks performed

- **Session lookup**: `live_receiver_session?/2` is gone with the
  unsupervised path; `resolve_session/2` was fixed for BOTH its lookup
  shapes — the default Codex table and a caller-supplied
  `:session_resolver`, which round 1 had left probing the run row id only.
  `Elf.lookup_session_ids/2` already held the correct form and is untouched
  (Elf-owned, PR72).
- **Capability mapping**: `Handoffs.receiver_capabilities/1` is the third
  copy of the same string→atom mapping (`Elves.resume_capabilities/1`,
  `Wakeups.wake_capabilities/1`). Kept local for the same file-ownership
  reason `Wakeups` records, and noted in the code so the triplet is visible.
- **Refusal twins**: every "refuses with no effect" test has an admitted
  twin asserting the normal path still works — the reordering in B3 and the
  supersede check in B4 are each covered in both directions.
- **Delivery twins**: `request/3`'s enqueue and `reconcile/1`'s re-enqueue
  build the same job through one `delivery_changeset/1`, so the two paths
  cannot drift apart.
- **Migration up/down**: `down/0` narrows the check back. Rows of the new
  type would then violate it; none exist pre-MVP. Stated in the migration.
