# Iteration 5: admission, checkpoint, sleep, resume, and handoff

**Status:** proposed  
**Hard dependencies:** iteration 4 complete  
**Unlocks:** quota-aware product MVP and iteration 6


---

> ## Provenance of this tracked copy — read first
>
> **The body below is the original milestone document, copied verbatim.** It is
> **not** a reconstruction.
>
> This file was not lost. `plans/milestones/*` is ignored by `.gitignore`
> (lines 45–49), which allowlists only `00a-capacity-feasibility.md` and
> `02-harness-contracts-fake.md`, so this milestone was simply never tracked.
> The original was recovered — read-only — from the untracked working copy in
> the user's source checkout at
> `plans/milestones/05-quota-aware-mvp.md` (11539 bytes, mtime 2026-08-29).
> **The source checkout was not modified.**
>
> Two deliberate changes were made to the tracked copy, and nothing else:
>
> 1. **This provenance note** was inserted.
> 2. **The `## Completion record` section at the end was filled in.** In the
>    original its fields are an empty template; here they carry the measured
>    integration result. Every other section — mission, required outcomes,
>    preflight, locked decisions, work packages A–G with the state diagram, the
>    deterministic eval matrix table, the semantic evaluation, the demo, the
>    acceptance gate, out of scope, and likely blockers — is byte-for-byte the
>    original.
>
> To make the file trackable, one allowlist line
> (`!/plans/milestones/05-quota-aware-mvp.md`) was added to `.gitignore`,
> following the existing convention used for the two already-tracked
> milestones. That is a deviation from the "docs only" scope of the task that
> restored this file, and is reported as such.
>
> Graded against in
> `plans/evidence/05-quota-aware-mvp/integration-closeout.md` §4.

## Mission

Deliver Shoestring's core product: a deterministic Cobbler admits bounded work
against honest subscription observations, declines lease renewal before a known
reserve, creates a recoverable checkpoint on planned or unexpected stops,
sleeps without inference, and resumes or hands off without giving the receiver
the first harness transcript.

## Required outcomes

- A durable Cobbler state machine for one user goal and one active task.
- Explainable static-reserve admission and bounded execution leases.
- Persisted queue/reset wakeups that survive restart.
- Deterministic checkpoint fallback for every stop path.
- Same-provider resume and cross-provider handoff at checkpoint boundaries.
- A repeatable continuation evaluation and trajectory ablation.

## Preflight

- Read iteration 4's completion record and rerun both adapters' contract suites.
- Verify capacity support tiers and stale/unknown policy from iteration 3.
- Run fake sudden-limit, safe-boundary, restart, and handoff scenarios.
- Select default five-hour/weekly reserves conservatively and mark them as policy
  defaults, not empirically optimal predictions.
- Decide what manual override is allowed for unknown/reactive-only modes. It
  must be explicit, attributable, and never described as automatic safety.
- Prepare one fixture repository/task with scripted interruption points and
  mechanical acceptance tests.

## Locked decisions

- Admission is deterministic and policy-versioned.
- MVP admission uses observed capacity, freshness, support tier, static reserves,
  maximum lease bounds, and uncertainty. It does not estimate semantic
  checkpoint distance.
- A capacity snapshot is never a provider-enforced reservation.
- Leases renew only at safe harness boundaries.
- Unknown/stale is never unlimited; automatic behavior follows the documented
  support tier.
- Waiting for provider reset consumes no model inference.
- A checkpoint never depends on a final model call.
- The next harness receives a compact projection, not the prior raw transcript.
- Scheduled Oban jobs deliver wake requests; persisted Cobbler intent and the
  trajectory remain authoritative about whether waking may dispatch work.

## Work package A: Cobbler state machine

Implement one deterministic process per active goal, reconstructable from the
trajectory. A suggested lifecycle is:

```text
created -> evaluating -> queued -> dispatching -> working
                         ^             |             |
                         |             |             v
                         +------ sleeping <--- checkpointing
                                           \-> handing_off -> working
                                           \-> completed
                                           \-> needs_user
                                           \-> failed
```

- Define legal events/transitions and terminal states.
- Record state-change intent before dispatch, wakeup, and handoff side effects.
- Reconcile incomplete intents idempotently after restart.
- Allow at most one active implementation Elf for this milestone.
- Keep UI actions as commands to the Cobbler, not direct database mutation.

## Work package B: admission policy

Represent every decision as a durable object/event containing:

- policy version and requested capability;
- candidate provider and adapter compatibility/support tier;
- five-hour/weekly observations, ages, confidence, and reset times;
- configured reserves and permitted manual override;
- proposed lease response/time/checkpoint bounds;
- result: admit, defer-until, require-confirmation, or reject;
- machine-readable reason codes and concise human explanation.

Evaluate candidates consistently. At minimum:

1. required execution capabilities are supported;
2. adapter/CLI compatibility is acceptable;
3. observation freshness satisfies its support policy;
4. known used capacity is below configured reserves;
5. no known hard block extends past the proposed lease;
6. only one MVP run/reservation is active for the account/provider scope;
7. manual unknown/reactive-only execution requires explicit confirmation.

Do not fabricate a percentage cost for a proposed task.

## Work package C: lease control and safe preemption

- Grant a lease with fixed response count, deadline, and checkpoint cadence.
- Persist grant before allowing execution.
- Decrement/advance bounds only from normalized events.
- Mark renewal due at the configured boundary or deadline.
- At the next safe boundary, refresh observable capacity and evaluate renewal.
- Renew, checkpoint/sleep, or request user confirmation with a durable reason.
- If allowance is exhausted in-flight, enter the reactive checkpoint path.
- Ensure wall-clock timers only request non-renewal; they do not interrupt an
  incomplete tool mutation.

## Work package D: deterministic checkpoint builder

Build a checkpoint from durable Shoestring/OS/repository evidence:

- goal, task, acceptance contract, and current Cobbler/run state;
- repository identity, base/current commit, worktree, branch, dirty diff, and
  changed files;
- important inspected files when recorded;
- explicit decisions, constraints, rejected approaches, and source event IDs;
- commands/tests with exact exit status, commit/diff context, and artifacts;
- known failures and unresolved questions;
- last completed safe boundary;
- exact planned next action or deterministic recovery instruction;
- provider session identity/capability if resumable;
- stopping snapshot, lease, reason, and reset/wakeup information.

The minimum fallback may say to inspect a precise last failure/event and rerun a
specific verification command; it must not invent semantic certainty absent
from the trajectory.

## Work package E: sleep, reset, and recovery

- Persist wakeup intent and absolute reset time before scheduling an Oban job.
- Reconcile overdue/future wakeup intents and repair missing scheduled jobs at
  application start.
- Recheck capacity when waking; do not assume the provider reset successfully.
- Prevent duplicate wake/dispatch through durable command identifiers.
- Provide manual wake/recheck without duplicating a queued task.
- Keep sleeping Cobblers cheap: durable state plus scheduled jobs, no model
  loop.

## Work package F: continuation projection and handoff

- Generate a bounded, deterministic projection from the checkpoint and selected
  recent/high-value trajectory evidence.
- Include references or snippets required to act, not every output token.
- Explicitly state completed work, current failure, constraints, verification,
  and next checkpoint condition.
- Resume the original provider session when supported, while reconciling its
  conversational state against Shoestring's durable checkpoint.
- For cross-provider transfer, start a fresh session with the projection and
  prove no raw prior transcript is supplied.
- Record `handoff.created`, source/receiver identity, projection version, and
  outcome.

## Work package G: UI and explanation

Show one goal's:

- Cobbler state, active/queued provider, and worktree;
- capacity evidence and reserves used for the last decision;
- lease bounds, next boundary, and renewal status;
- checkpoint contents and artifacts;
- sleep/reset countdown and manual recheck;
- handoff source/receiver and explanation;
- explicit degraded/manual mode warnings.

## Deterministic eval matrix

| Eval | Injection | Required result |
| --- | --- | --- |
| Reserve refusal | Usage at threshold | No automatic dispatch |
| False-zero defense | Missing/malformed window | Unknown/manual or defer |
| Lease decline | Capacity crosses reserve | Checkpoint at next safe boundary |
| Sudden exhaustion | Refusal before refresh | Fallback checkpoint, no model call |
| Reset restart | Restart while sleeping | One wakeup and fresh recheck |
| Dispatch crash | Crash after intent | No duplicate Elf |
| Handoff privacy | Inspect receiver request | No raw sender transcript |
| Same resume | Supported session fixture | One reconciled continuation |
| Incompatible update | CLI/schema changes mid-goal | Pause/degrade visibly |
| UI explanation | Each reason fixture | Inputs and policy reason match |

## Semantic continuation evaluation

Use a fixture task where Elf A has:

1. inspected relevant and irrelevant files;
2. recorded a constraint and rejected approach;
3. partially implemented the change;
4. run a test exposing a second failure;
5. been interrupted by a scripted quota refusal.

Elf B receives only the worktree and checkpoint projection. Score:

- acceptance tests and final artifact;
- preservation of constraints and rejected approach;
- recognition of completed/current work;
- repeated commands/files/investigation;
- turns to useful forward progress;
- additional observed capacity consumed.

Run the same fixture with worktree-only, naive-summary, and trajectory-projection
inputs. Record this trajectory ablation manually at first; deterministic final
tests remain authoritative.

## Demo

Demonstrate the complete MVP with fakes, then one live path if capacity permits:

1. submit a task;
2. show admission evidence and lease grant;
3. perform partial work;
4. inject/encounter quota exhaustion;
5. create a deterministic checkpoint;
6. restart Shoestring while sleeping;
7. wake after simulated reset or choose the other provider;
8. continue without the first transcript and pass fixture tests.

## Acceptance gate

- Automatic dispatch never violates configured known reserves.
- Unknown/stale/reactive-only modes follow documented policy.
- All planned and failure stops create a minimum structural checkpoint.
- Checkpoint fallback performs no model inference.
- Wakeups and dispatches remain idempotent across restart.
- Same-provider resume and fake-backed cross-provider handoff work.
- At least one real cross-provider handoff is evaluated when both subscriptions
  are safely available; otherwise it remains explicitly live-unverified.
- The semantic eval shows receiver behavior and handoff tax, not only final pass.
- Every decision is explainable from persisted policy inputs.

## Out of scope

- Learned task consumption or checkpoint-distance estimation.
- Planner-generated task DAGs and parallel workers.
- Automated semantic judge as the sole acceptance mechanism.
- Cross-provider review and autonomous merge.
- Interactive terminal takeover.

## Likely blockers and response

- **No proactive Claude signal in headless mode:** allow documented
  reactive/manual support; retain deterministic recovery as the guarantee.
- **Provider reset time changes:** wake to re-observe, never dispatch solely from
  the old timestamp.
- **Checkpoint lacks semantic next action:** use precise deterministic recovery
  instruction and improve event capture; never spend a forbidden final call.
- **Handoff succeeds only with transcript:** treat as failed continuation eval
  and improve projection/event coverage.

## Completion record

*Filled from the integration measured at `9ecd6ed` on the branch
`polly/iter5-integration-closeout` (PR #75). Full working in
`plans/evidence/05-quota-aware-mvp/integration-closeout.md`.*

- **Final status:** **Hermetic implementation complete; milestone acceptance
  INCOMPLETE.** Work packages A–F are implemented and green, all ten
  deterministic eval-matrix rows pass, both adapter contract suites pass, and
  the scripted demo passes against fakes. The acceptance gate is **not**
  fully met: no real cross-provider handoff was evaluated, the semantic eval
  is fixture-authored, and work package G carries two audited acceptance
  blockers (checkpoint artifacts are never rendered; no next boundary is
  rendered or computed). The hard dependency (iteration 4 complete) is
  **not** satisfied.
- **Completed on:** *Not completed.* Integration measured 2026-09-19.
- **Policy version/default reserves:** policy version `1`
  (`Shoestring.Cobbler.AdmissionPolicy.version/0`); defaults
  `five_hour_reserve_percent: 20` (refuses automatic admission at ≥ 80 % used)
  and `weekly_reserve_percent: 10` (≥ 90 % used); delayed-recheck default
  60 s. These are operational reserve margins, not empirical predictions of
  task cost.
- **Cobbler/lease/checkpoint events:** `admission.decided`;
  `cobbler.command.accepted`, `cobbler.command.resolved`,
  `cobbler.claim.acquired`, `cobbler.claim.released`; `lease.proposed`,
  `lease.granted`, `lease.active`, `lease.renewal_due`, `lease.renewed`,
  `lease.decline`, `lease.checkpoint_required`, `lease.expired`,
  `lease.revoked`; `checkpoint.created`; `handoff.created`, `handoff.failed`;
  run lifecycle `run.requested`, `run.starting`, `run.running`,
  `run.pausing`, `run.suspended`, `run.interrupted`, `run.handoff`,
  `run.cancelling`, `run.cancelled`, `run.completed`, `run.failed`.
- **Schemas/configuration:** `AdmissionPolicy`, `AdmissionDecision`,
  `AdmissionEvaluation`, `LeaseBounds`, `LeaseGrant`, `LeaseRenewal`,
  `WakeupRecord`, `CommandRecord`, `TaskClaimRecord`, `Handoffs`,
  `Harness.Checkpoint`; Oban queues `dispatch: 5`, `wakeup: 5`, `handoff: 5`
  with `Oban.Lifeline` (rescue after 5 min) and `Oban.Pruner` (1 day). One
  migration in this milestone's integrated range:
  `20260919034454_widen_cobbler_command_types.exs`.
- **Deterministic eval results:** all ten matrix rows pass
  (`test/shoestring/harness/eval_matrix/matrix_test.exs`); the eval-matrix
  directory is 15 tests, 0 failures, reproduced at a second seed (4242).
- **Semantic/ablation results:** four arms (`worktree_only`,
  `naive_summary`, `trajectory_projection`, `fallback_template`) run on one
  shared fixture through the real handoff path, recording turns-to-progress
  and capacity consumed per arm as handoff-tax metrics. **The receiver's
  semantic behavior is fixture-authored and the scoring uses
  harness-synthesized normalization; per this milestone's own instruction,
  this is not real semantic evaluation and is not presented as one.**
- **Live handoff result or reason skipped:** **Skipped — explicitly
  live-unverified.** No live budget was authorized for the integration task
  and no provider process was started. This satisfies the acceptance gate's
  escape clause only; the preferred branch (a real cross-provider handoff)
  is unmet.
- **Verification commands:** `mix precommit` (format check,
  `compile --warnings-as-errors`, test, `gate_0a.node_test`) with a fresh
  state directory under `System.tmp_dir!()` → exit 0, `1288 tests, 0
  failures, 1 skipped (6 excluded)`, Node `tests 52 / pass 52 / fail 0`. The
  1 skip is the capability-appropriate `:resume` skip for `ClaudeHeadless`;
  the 6 exclusions are `@tag :live` provider smokes, which were not run.
  Targeted suites and their counts are tabulated in the closeout evidence §3.
- **Demo result:** passes against fakes
  (`eval_matrix/demo_test.exs`): submit → admission/lease → partial work →
  exhaustion → checkpoint → restart while sleeping → reset wake / provider
  switch → continue without the transcript and pass acceptance. The "then one
  live path" half was not performed.
- **Deviations and remaining risks:** the one-active-Elf guard is
  check-then-act rather than a lock, backstopped by the dispatch-row claim and
  run-id registration; a deliberate audited expert/test hatch remains the one
  production `start_run` caller; "all stops checkpoint" is proven per
  exercised path, not by exhaustive enumeration; PR #72 was developed against
  a pre-#71 base and this integration is the first gate covering the
  combination; UI was code-audited and test-verified but never visually
  inspected at any viewport. Work package G was audited bullet by bullet
  (closeout evidence §4.7, 65 goal-page tests executed, 0 failures): five of
  seven bullets fully met, two acceptance blockers (G-BLOCK-1 checkpoint
  artifacts never rendered; G-BLOCK-2 no next boundary rendered or computed)
  and one nit (G-NIT-3 sleep/reset shown as absolute times, not a countdown),
  each with a bounded proposed fix and none applied. Full list in the closeout
  evidence §6–§7.
- **Instructions for iteration 6:** **Do not start iteration 6 on this
  result.** This milestone's own condition — iteration 4 complete and the eval
  gates met — is unsatisfied on both counts: iteration 4 carries an open
  UNVERIFIED second Codex live turn after its normalization fix, and the eval
  gate's real-cross-provider and real-semantic halves are unmet. To unlock
  iteration 6: close the iteration-4 live turn, evaluate at least one real
  cross-provider handoff under an authorized budget, obtain semantic evidence
  that is not fixture-authored, and close package G's two audited blockers
  (G-BLOCK-1 checkpoint artifacts, G-BLOCK-2 next boundary), each of which has
  a bounded fix specified in the closeout evidence §4.7.

### Completion-record addendum — bounded live verification (2026-09-21)

*Measured on `polly/iter45-live-verification`, base `6f1653f`. Full working in
`plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md` and the
2026-09-21 addendum in
`plans/evidence/04-single-elf/harness-live-verification.md`. The bullets above
are the earlier measurement and are left exactly as written; this addendum
records only what changed, and only where the change was actually verified.*

- **Live handoff result — a real transfer ran; acceptance 7 stays OPEN.** A
  real Codex → Claude handoff was evaluated live under explicit operator
  authorization, through the durable `run.handoff` intent, a real receiver
  capacity observation, a real `admission.decided`, the receiver's own lease
  grant, the canonical `handoff.created` pointer and the durable dispatch
  pipeline. Sender terminal `completed` (374 normalized events); receiver
  terminal `completed` (52 normalized events).
  **The acceptance gate is NOT closed by it.** Two parts of the run were not
  the production-configured path: the receiver observation bypassed the
  `:prod` probe (`WakeupObserve` → Observatory ledger), because a
  ledger-owned snapshot cannot be projected under a work goal — an open
  defect; and the completing receiver leg bypassed `HandoffWorker`'s
  decision step, because the worker has no per-transfer policy channel and
  the default 300-second lease deadline stopped the first leg mid-task. A
  gate is a statement about the production path, and a workaround does not
  close one.
- **Receiver semantic behavior — one real arm; acceptance 8 stays OPEN.**
  Real receiver behavior on the trajectory-projection input is now evidenced
  from canonical normalized events, committed redacted under
  `plans/evidence/05-quota-aware-mvp/fixtures/live/`: the receiver read the
  sender's package before writing, reused it rather than reimplementing it,
  and repaired its own violation of an acceptance clause carried in the
  checkpoint. **The three-arm ablation and the handoff-tax metrics remain
  fixture-authored**; nothing here measures one arm against another, so the
  gate is not closed.
- **Terminal classification and cancellation.** An explicit
  `Elves.cancel_run/1` on a live Codex run with an observed-alive owned
  process group produced terminal class `cancelled`, exactly one
  `run.cancelled`, a dead process group, a deregistered adapter session, and
  `{:ok, :already_terminal}` on a second call. No timer, lease deadline,
  heartbeat or staleness signal was involved.
- **Hard dependency (iteration 4).** The specific gap the closeout named —
  the open UNVERIFIED second Codex live turn after the normalization fix — is
  **closed**: two post-fix live Codex turns ran, both terminal `completed`,
  both showing the file-change completion durably recorded with a scalar
  `changes[].kind` and contiguous, duplicate-free normalized ordinals. This
  addendum does not audit iteration 4 as a whole and makes no claim about it
  beyond that one item.
- **Package G blockers.** G-BLOCK-1 and G-BLOCK-2 were closed in the base by
  PR #77 (`adf8269`, REPO-INSPECTION). This run did not re-audit them.
- **One production defect fixed here.** The durable `run.handoff` intent had
  no channel for the operator's confirmation, and `HandoffWorker` — the only
  production consumer — passes none. Because the Claude capacity source
  declares `support_tier: :conservative_partial` unconditionally, every
  Claude receiver was confirmation-class and the transfer was unreachable in
  production. The confirmation now travels on the intent, validated where the
  intent is recorded. The caller supplies only an allow-listed `intent`;
  `confirmed_by` is **derived from the goal's durable `owner_id`** and the
  target provider/scope from the same payload's receiver, so no identity is
  caller-authored, and a goal with no usable owner is refused. The confirmed
  intent must be the capability admission is deciding, and every hard stop
  stays a hard stop. Locked by
  `test/shoestring/cobbler/handoff_confirmation_test.exs` (27 tests; 14 fail
  at base `6f1653f` for the right behavioural reason).
  **Honest limit:** this application has no accounts domain and no
  per-request authenticated principal, so the attribution names the goal's
  owner, not the individual who acted. Recorded as an open item rather than
  claimed as an authentication guarantee.
- **A second production defect fixed.** An Elf launch failure occurring
  before `run.starting` committed `run.failed`, an illegal
  `requested → fail` transition that wedged the goal's projection
  permanently — every later run, checkpoint and lease of that goal stopped
  projecting too. Its twin, `Shoestring.Elves.cancel_run/2` on a run with no
  live Elf, wedged a goal the same way through `requested → cancel`. Both
  edges were added to `Shoestring.Harness.RunStateMachine` and locked by
  `test/shoestring/harness/run_terminal_before_start_test.exs` (6 tests; 5
  fail at base `6f1653f` with `run_transition_rejected`).
- **Defects found and NOT fixed, each keeping something open.** (1) The
  `:prod`-configured receiver probe serves Observatory-ledger snapshots,
  which the work goal's projector refuses under its deliberate same-goal
  ownership boundary, failing the handoff after its effects have committed
  and leaving the projector position `failed`. (2) `HandoffWorker` has no
  per-transfer policy channel, so the default lease deadline cannot be
  answered for a specific transfer. (3) After a lease decline, a
  ClaudeHeadless receiver Elf had not quiesced when a 25-minute observation
  bound expired; the mechanism is a hypothesis that was not confirmed.
  (4) A hard quota refusal is not covered by the hard-stop matrix.
  Details, reproductions and the reason each was left unfixed are in the
  live evidence §7 and §8.
- **One unexplained launch failure.** Recorded as
  `transport/process_launch_failed`, the catch-all code; the concrete reason
  is swallowed by `Elf.launch_fresh/1`. It did not reproduce under tracing.
  **Cause not established.**
- **Verification commands:** `mix precommit` in the verification worktree with
  a fresh state directory under `System.tmp_dir!()`. On the committed tree,
  three runs, all `1340 tests, 0 failures, 1 skipped (6 excluded)` with Node
  `tests 52 / pass 52 / fail 0`. Earlier heads of this branch each saw one
  intermittent failure in five runs, in different unrelated suites
  (`ClaudeHeadless.TransportTest`'s load-sensitive
  `group_leader_unverifiable` spawn/reap race, 0/10 isolated on branch and
  base; and `Exqlite.Error: Database busy` in `Cobbler.LeaseGrantTest`'s
  setup). Neither cause was established; both are reported rather than
  discarded. Five runs at base `6f1653f`: `1302 tests, 0 failures, 1 skipped`
  each. Count accounting: base 1302 + 27 + 6 + 5 new tests = 1340.
  Focused: evidence invariants plus this branch's locks -> 42 tests, 0
  failures; `test/shoestring/cobbler/ test/shoestring/harness/
  test/shoestring/elves/` -> 989 tests, 0 failures, 1 skipped (6 excluded).
- **Evidence redaction.** The committed live transcripts were re-generated
  after a real miss: redaction had been applied field by field, and Codex
  spells an agent message out one `item/agentMessage/delta` fragment at a
  time, so an absolute worktree path -- macOS machine shard and run UUID
  included -- reassembled from events that individually matched nothing.
  Substitution is now same-length and applied to the reassembled stream, and
  `test/shoestring/evidence/live_evidence_redaction_test.exs` enforces it
  (verified to fail against the pre-fix fixture). A scan of all 20 files this
  branch touches, raw and reassembled, reports 0 issues.
- **Instructions for iteration 6 — still do not start it.** Of the two
  conditions the closeout named, the iteration-4 live turn is satisfied and
  the eval gates are **both still open**: acceptance 7 because the live
  transfer bypassed the production observation path, and acceptance 8
  because the ablation is still fixture-authored. Beyond that, this run left
  open defects in the exact path iteration 6 would build on, one of which
  leaves a goal's projection permanently failed in the deployed
  configuration. To unlock iteration 6: repair the `:prod`
  receiver-observation path so a handoff projects under the configured
  probe, give `HandoffWorker` a per-transfer lease-policy channel (or
  establish that the default is right and re-run the handoff through the
  worker end to end), re-run the cross-provider handoff on the unmodified
  production path, obtain semantic evidence that is not fixture-authored
  (the three-arm ablation run live), and settle the declined-lease
  quiescence of a ClaudeHeadless Elf.

### Completion-record addendum — live production-path rerun (2026-09-23)

*Measured on `polly/iter5-live-production-rerun`, base `0f96798`. Full working
in `plans/evidence/05-quota-aware-mvp/live-production-rerun.md`. Earlier
bullets are left exactly as written.*

- **Acceptance 7 stays OPEN; acceptance 8 stays OPEN.** A `MIX_ENV=prod` node
  (configured `WakeupObserve` probes, `ElfEffect`, live Oban queues, both
  monitors) was driven only through product entry points: the `/runs/new`
  submit handler, durable Cobbler commands, `Handoffs.request/3` and
  `Elves.cancel_run/1`. The Claude receiver was never reached, so no
  cross-provider transfer, no live three-arm ablation and no handoff-tax
  measurement exists. Nothing fixture-authored was substituted.
- **Three production defects block the genuine path. All are reported, none
  fixed:**
  1. no production component writes a Claude reading into the Observatory
     ledger, so `HandoffWorker` fails `{:observation_failed,
     :no_observation_for_provider}` on every attempt;
  2. the Elf's lease-renewal boundary re-appends the Observatory-owned Codex
     snapshot under the work goal with its original id (the D1 twin #79 left in
     `LeaseRenewal`), so the goal's projector wedges, the canonical checkpoint
     is never projected, and the `run.handoff` request is rejected
     `handoff_checkpoint_not_found`;
  3. `Trajectory.Writer` never classifies Exqlite's `"Database busy"` as
     retryable, so 3 of 5 Codex launches failed before `run.starting`.
- **Established live:** the receiver command Shoestring launches resolves to
  `claude-opus-5-5` (from the CLI `init` frame; the orchestrating worker's own
  runtime model is UNVERIFIED); one Codex turn completed with a verified Go `game` package;
  a node crash after `run.starting` was redelivered by the dispatch queue to
  exactly one Elf; explicit cancellation of that live Elf gave `cancelled`,
  then `already_terminal`; and three pre-start launch failures projected
  cleanly.
- **Durable handoff lease policy in force:** default `deadline_seconds: 2700`,
  `response_budget: 10`, `tool_budget: 25`, `checkpoint_cadence: 1`, reserves
  1/1. It was never exercised live.
- **Iteration 6 stays locked.** Unblock in order: localize the renewal/wake
  snapshot, give the deployed configuration a Claude ledger source, and
  classify `"Database busy"` as retryable. Then rerun
  `tools/live_eval/prod_rerun.exs` unchanged.

### Completion-record addendum — production path unblocked (2026-09-24)

*Measured on `polly/iter5-production-unblock`, base `d3fa152`, live code SHA
`22c1e72`. The full record is
`plans/evidence/05-quota-aware-mvp/production-unblock.md`. Earlier bullets are
left exactly as written. This branch is unmerged pending independent review.*

- **The three blockers #82 recorded are fixed, each with tests that fail on
  base for the behavioural reason:**
  - renewal and wake re-record an Observatory-owned reading under a
    deterministic goal-local id (the rule #79 introduced for handoff);
  - the trajectory writer retries Exqlite's `"Database busy"` and takes its
    write lock at `BEGIN IMMEDIATE`;
  - the production config ingests the Claude monitor's honest
    `unknown / conservative_partial` reading at boot. It still admits only
    with the goal owner's confirmation.
- **Two further defects on the same path are fixed:**
  - `Handoffs.request/3` projects the goal before validating the sender's
    checkpoint. Nothing else projects a finished run, and #82's driver had done
    it itself.
  - `/runs/new` proposes `checkpoint_cadence = max_events`. A manual lease can
    never renew, so a cadence of 1 ended every manual run at its first
    response once renewal could evaluate.
- **Acceptance 7 — demonstrated on this branch (live, production path, no
  bypass).**
  - Two Codex turns via `/runs/new` both completed; 0 of 6 launches failed
    before `run.starting`.
  - `Handoffs.request/3` → the live `handoff` queue → `HandoffWorker` with the
    `:prod` `WakeupObserve` probe → owner-confirmed admission → receiver lease
    → the live `dispatch` queue → Claude Elf (`claude-opus-5-5` from its own
    events) → `run.completed` in 72.5 s.
  - The receiver's result: gofmt, vet and test pass, all 5 scripted CLI games
    pass, and `game` is reused unchanged.
  - The transfer carried a sized per-transfer `lease_policy`: 150/300/150,
    reserves 1/1, deadline 2700 s. The reason: the Claude receiver's own
    renewal probe can never be admitted under the transfer's scope.
- **Acceptance 8 — partially demonstrated, stays OPEN.**
  - Three arms ran live from the same committed state; all three passed
    acceptance.
  - The product projection arm cost the most: 50 events and 72.5 s, versus 28
    and 49.4 s for worktree_only and 32 and 59.8 s for naive_summary.
  - It first mutated a file after 36.5 s, versus 28.2 s and 14.6 s (POST-HOC
    measure).
  - It is plausibly slowed by the terminal checkpoint's Elixir-only
    `next_action`; this is an INFERENCE, not isolated.
  - Remaining limits: N=1, the arms differ in lease regime, the predefined
    Write/Edit measure never fired, and the milestone fixture's
    interruption / constraint / rejected-approach elements were not exercised.
- **Iteration-4 dependency: owned-group cancellation measured live.** The group
  was alive before `cancel_run/1` and dead after, with the node up. The first
  cancel returned `cancelled` in 125 ms and the second `already_terminal`.
- **Open findings.**
  - Run rows are never projected after start.
  - The terminal checkpoint `next_action` is Elixir-only, and the handoff
    prompt carries no task objective.
  - `ClaudeHeadless.probe/1`'s scope and constant id make a Claude receiver
    unrenewable.
  - Receivers act on the operator's global Claude instructions: they attempted
    `git push` and `gh pr create`, harmless here with no remote.
  - The projector still raises on busy.
- **Gate:** `mix precommit` at `22c1e72`, seed 895679, exit 0: 4 doctests,
  1433 tests, 0 failures, 1 skipped (6 excluded); Node 52/52; UI 7/7. The
  earlier red run at `8587b7f` is recorded with its diagnosis in the evidence.
  Iteration 6 stays locked until review and merge.

### Completion-record addendum — final live acceptance (2026-09-25)

*Measured on `polly/iter5-final-acceptance` (live phases) and finished on
`polly/iter5-final-acceptance-recovery`, base `c1ae4a8`. The full record is
`plans/evidence/05-quota-aware-mvp/final-acceptance.md`; its §2 was
pre-registered at `42fde95` before the first live call. Earlier bullets are
left exactly as written. This branch is unmerged pending independent review.*

- **Seven defects fixed**, six in production code, each locked by a test that
  fails at its pre-fix commit for the behavioural reason (the recovery re-ran
  all six locks):
  - the handoff prompt now carries the goal statement and the sender's
    finished commands with exit status;
  - checkpoint evidence chunks now fit the 2 000-char item budget, where
    they had overflowed to the floor template;
  - the carried goal statement is now labelled as an earlier, ended
    session's, so the receiver no longer adopts the session's stop limit;
  - a granted but unprojected lease is now enforced: every manual run had
    run unenforced;
  - a tool now spends lease only at its completion, not at its START;
  - real Claude ids are removed from #83's committed transcripts;
  - a committed `.pyc` embedding an absolute home path is removed.
- **Acceptance 7 — demonstrated again**, now at `32a3fe6` (code identity by
  timestamp, not recorded by the driver). Codex → `Handoffs.request/3` → live
  `handoff` queue → `HandoffWorker` (`:prod` probe) → owner-confirmed
  admission → receiver lease → live `dispatch` → Claude Elf
  (`claude-opus-5-5`) → `run.completed`, and the Go CLI passed every check.
  16 of 16 live runs launched through the process-group handshake.
- **Acceptance 8 — measured under the pre-registered design; the result does
  not favour the product on this fixture.**
  - Three arms ran live twice, each cycle from one committed state, and every
    pre-registered measure was computed.
  - In the pre-registered cycle the projection arm **failed**: its receiver
    adopted the sender session's stop limit and did nothing, while
    `worktree_only` passed and `naive_summary` failed only on `go vet`.
  - After the post-hoc label fix, projection passed 2 of 2, but in the one
    same-cycle comparison it was dearer than `worktree_only`: 55 vs 50
    events, 63.0 vs 55.8 s.
  - The constraint and rejected-approach measures did not separate the arms.
  - The gate's letter (§2.5) is met, but the product value it was meant to
    show was not shown. Closing it is the reviewer's call.
- **Lease stop at a safe boundary — met on Shoestring's side after two fixes;
  open issues remain.**
  - After both fixes, a live decline fired at a command completion, but
    Codex had started the next item 2 ms earlier.
  - Every manual-scope `lease_decline_recheck` wake failed
    `no_observation_for_provider` (5 of 5 jobs): the Observatory never holds
    the `account:manual` scope.
  - One run declined before the fix remained `suspended` with no terminal.
- **Replay** produced no duplicate run, but it did enqueue a new handoff job
  (failing `handoff_claim_lost`), which the pre-registered clause forbade.
- **Cancellation:** owned group alive and leading before the cancel,
  `cancelled` in 172 ms, dead after with the node up, then
  `already_terminal`. The source checkout was byte-for-byte unchanged before,
  after and at recovery.
- **Gate at the branch tip:** `mix precommit`, exit 0: 4 doctests, 1454
  tests, 0 failures, 1 skipped (6 excluded); Node 52/52; UI 7/7.
- **Iteration 6 stays locked** until review and merge. Open findings are in
  §6 of the record.

### Completion-record addendum — live closeout on merged main (2026-09-27 UTC)

Record: `plans/evidence/05-quota-aware-mvp/live-closeout.md`. One authorized,
bounded sequence (`setup → turn1 → turn2 → handoff → lease_stop → audit`) ran
at `1566acd`, on a fresh state DB built with `Shoestring.Release.migrate()`.
It used 3 Codex runs and 1 Claude run, with no retries and no comparison arms.

- **Code identity:** 6 of 6 phase records carry `1566acd`, clean.
- **Cross-provider handoff on the production path:** completed. Owner-confirmed
  admission, job attempt 1, receiver `claude-opus-5-5` (from its `init`
  frame). Every M1 fixture check passed, C1 0 violations, R1 honoured.
- **Replay:** the settled-transfer replay added 0 jobs and 0 runs (compared
  explicitly).
- **Checkpoint on stop:** the lease-stopped run's checkpoint names its
  unfinished item.
- **Lease stop: not met.** At the manual-lease deadline the turn was
  interrupted 2.5 s after a command START with no completion recorded. The
  decline, suspend and recheck wake never happened, and the lease row stayed
  `active`. The manual-scope wake fix is therefore still unverified live.
  Mechanism not established; not fixed on this branch.
- **Acceptance 8:** not re-run. The pre-registered failure, the post-hoc
  2 of 2 passes with no consistent advantage, and the missing scripted quota
  refusal all stand.
- **Iteration 6 stays locked.**

### Completion-record addendum — post-#85 closeout (2026-09-29 UTC)

*Branch `polly/iter5-final-closeout-post85`, base `a01da97` (#85 merged). The
full record is `plans/evidence/05-quota-aware-mvp/live-closeout-post85.md`;
its §1–§2 were pre-registered at `b344a0b` and amended before any provider call
at `17dd1bd`. Earlier bullets and addenda are left exactly as written. The
header's `Status: proposed` is original milestone text and is not edited; the
status below supersedes it.*

- **Final status (2026-09-29):** implementation complete and hermetically
  green. Of the nine gate items, eight are met at the evidence levels below,
  and **Acceptance 8 is measured with no product advantage shown, pending the
  human's ruling**. The hard dependency has **one open item**: iteration-4
  bullet 6 (lease stopping at safe boundaries) is not verified live since #85.
  **Completed on:** not yet. The conditions are under "Iteration 6" below.
- **#85 supersedes the lease-stop design recorded above.** A lease safe stop
  now only pends until the provider's own turn outcome. A completed turn keeps
  its terminal (no suspend, no wake, no continuation); only an interrupted
  turn or a quota halt declines. The 2026-09-25 "met after two fixes" and
  2026-09-27 "not met" lease-stop bullets are history of the previous design.
  The 2026-09-27 interrupt at a command START is fixed **hermetically** by #85
  (`lease-safe-boundary.md`). It was **not** re-verified live (below). The
  deadline-driven manual-scope wake is superseded as a live requirement
  (`final-acceptance.md` §10); its hermetic locks remain.
- **Live this round: 1 of 3 authorized Codex runs, then a stop by the
  pre-registered rule.** `turn1` completed at `17dd1bd` (clean; group dead,
  Elf deregistered) but could not commit. codex-cli 0.158.0's
  `workspace-write` sandbox denies writes to a git worktree's own git dir
  (VERIFIED with no-model sandbox probes; at 0.157.1 the same turns
  committed). **New finding, not fixed:** at the installed CLI a Codex Elf
  cannot commit in a Shoestring worktree. `turn2` and `lease_stop` were not
  run, and no retry was made. Source checkout VERIFIED unchanged.
- **Gate 1–9** (evidence levels in the record §11):

  | # | Status |
  |---|---|
  | 1 reserves | Met — hermetic; no live automatic refusal exercised |
  | 2 unknown/stale policy | Met — hermetic + live (owner-confirmed Claude `unknown`) |
  | 3 checkpoint on every stop | Met with limits — live for completed, cancelled, lease-suspended, interrupted; failed/crash hermetic |
  | 4 no inference in fallback | Met — hermetic / repo-inspection |
  | 5 idempotent wakes/dispatches | Met with limits — dispatch and settled replay live; manual-scope wake, late delivery, crash window hermetic |
  | 6 resume + fake handoff | Met — hermetic |
  | 7 real cross-provider handoff | Met — live at `22c1e72`, `32a3fe6`, `1566acd`; at-risk at codex-cli 0.158.0 (sender cannot commit) |
  | 8 semantic eval / handoff tax | **Measured, no advantage shown; the pre-registered projection arm failed, the post-hoc repair showed no consistent advantage, and the scripted quota refusal was never reproduced. An independent reviewer judged it meets the contract; no human ruling is recorded** |
  | 9 explainable decisions | Met for the decisions inspected |

- **Iteration-4 dependency** (record §10): bullets 1–5 and 7 met on committed
  evidence; bullet 6 open live.
- **Carried, nonblocking, unchanged:** #85's follow-ups N1–N7, the
  `run_live_test.exs` Elf leak and the trajectory-writer leak, unprojected
  run rows, and the other items in the record's §12.
- **Gate:** the historical independent gate at `0344989` (4 doctests, 1506
  tests, 0 failures, 1 skipped; Node 52/52; UI 7/7) is as reported by the
  orchestrator. It is not recorded elsewhere in the repository and was not
  re-run here. This branch's own gate is reported with its commit.
- **Iteration 6: unlocks only when ALL of these hold.**
  1. This closeout PR passes independent review and is **merged by the
     human**.
  2. The human rules on Acceptance 8.
  3. Iteration-4 bullet 6 is closed, either by one live `lease_stop` under a
     new brief (it needs no commit, so it is not blocked by the Codex
     finding) or by a human ruling that #85's hermetic locks suffice.

  Recommended but not ruled blocking here: resolve the codex-cli 0.158.0
  commit block before any further live Codex sender or handoff work.

### Completion-record addendum — final decision (2026-09-29 UTC, after the standalone lease stop)

*This addendum supersedes the previous addendum's "Final status", its Acceptance
8 row, and its iteration-6 conditions 2 and 3. Everything above is left as
written. Record: `plans/evidence/05-quota-aware-mvp/live-closeout-post85.md`
§§13–15.*

- **Final status: acceptance met on evidence; no contract blocker found.**
  Every gate item 1–9 and every iteration-4 bullet is met at the evidence
  level stated in the record's §15. The milestone takes effect when this PR
  passes independent review and is **merged by the human**.
  **Completed on:** 2026-09-29 (evidence), subject to that merge.
- **Iteration-4 bullet 6 (lease stopping at safe boundaries): met live after
  #85.** It was pre-registered at `f3a8557` as a standalone `lease_stop` from
  `setup`'s committed head, because the original sequence had stopped after
  `turn1` on the Codex commit restriction. One Codex run: the 60 s deadline
  passed at a tool START, and `lease.renewal_due` was marked 27.5 ms later.
  That item completed. The turn continued 6.5 min (16 more items, 11 of them
  commands, all ending by themselves) to its own `completed` outcome. The outcome evaluated
  renewal once (`reject`, `snapshot_provider_mismatch`) and recorded
  `lease.expired`, then the terminal checkpoint and `run.completed`. There
  was no interrupt, driver cancel, suspension, wake or duplicate. The Elf was
  deregistered and its process group dead. Source checkout unchanged.
  Criteria L1–L7 pass.
- **L8 failed as registered.** The lease is terminal in the trajectory, but
  the stored lease row still reads `renewal_due`: the goal's projector
  stopped before the decision and markers, and nothing projects after the
  terminal. This is a read-model follow-up (the twin of "run rows not
  projected after start"), not an unsafe stop, because the trajectory is
  authoritative. It is recorded, not redefined.
- **Acceptance 8: met as a measurement; no product advantage shown.** The
  gate requires the eval to show receiver behaviour and handoff tax. The
  live three-arm, two-cycle measurement does that; the independent audit
  concluded the measurement requirement is met, and beating the other arms is
  not required. The failed pre-registered projection arm, the post-hoc repair
  and the unreproduced scripted quota refusal remain as limits.
- **Live budget this closeout:** 2 of 3 authorized Codex runs (`turn1`,
  `lease_stop`); the third is unspent. 0 Claude, 0 retries.
- **Follow-ups (nonblocking):** the lease/run row projection lag on terminal
  paths. The codex-cli 0.158.0/0.159.0 commit restriction in worktrees, with
  no proven safe repair and no sandbox change made. #85's N1–N7. The
  `run_live_test.exs` and trajectory-writer test leaks. Providers acting on
  the operator's global instructions. The projector raising on busy.
  Redacted ids and the old `.pyc` in `main`'s history. Failed/crash stops, a
  real quota refusal, late handoff delivery and the crash window, none
  exercised live.
- **Iteration 6: unlocked when this closeout PR passes independent review
  and the human merges it.** Recommended first in iteration 6, not a
  condition: resolve the Codex commit restriction before any live Codex
  sender or handoff work.

### Terminal-projection repair addendum — final prose closeout (2026-09-30 UTC)

*This addendum clarifies the final decision's wording; everything above is
left as written. No live capture was altered and no new live run was made.
Record: `plans/evidence/05-quota-aware-mvp/terminal-projection-fix.md` and
`live-closeout-post85.md` §§16–17.*

- **Original live result, unchanged:** criteria L1–L7 PASS live (§14 of the
  record); historical L8 FAIL as registered — the lease is terminal in the
  trajectory while the stored lease row read `renewal_due` (run row
  `running`). That measurement is not redefined after the fact.
- **Scoped reading of the final statements:** "Contract blockers found:
  none" (record §15.3) means no gate/dependency blocker beyond the recorded
  L8 FAIL and the nonblocking follow-ups. Iteration-4 bullet 6 "Met live"
  (record §15.1) covers the L1–L7 safe-stop behavior only — deadline pending
  while tools run, no interrupt, natural completed outcome, one renewal
  evaluation at the outcome, terminal checkpoint plus `run.completed`, no
  suspend/wake/duplicate. Neither statement means L1–L8 all passed.
- **Post-fix repair, hermetic only:** after committing terminal events the
  Elf promptly projects its goal (`commit_terminal/2`, mirrored in
  `crash_land/0`; repair code as committed at `b21e29f`, VERIFIED
  byte-identical in the final tree — this closeout adds prose only). Three
  regression locks fail on base `70af28e` for the stale-row reason and pass
  with the fix. No post-fix live pass is claimed or implied.
- **Gate on the final tree:** `mix precommit` → **4 doctests, 1509 tests,
  0 failures, 1 skipped (6 excluded); Node 52/52; UI 7/7** (ExUnit seeds
  796367 and 31501 green). Gate history, VERIFIED from the saved outputs:
  three full runs on this tree (seeds 839803, 796367, 31501). Seed 839803
  showed **1 failure** in `CodexAppServerContractTest` (cancel
  `GenServer.call` raced a dead session process; Node 52/52 and UI 7/7 still
  passed): that suite drives the adapter/session directly with no Elf, Repo,
  or Harness.Projector in the path, so no direct causal path from this
  diff was found — an indirect load-timing contribution is unestablished,
  not ruled out. The file passes in isolation (7 tests, 0 failures, seed
  0). Reported as intermittent, 1 of 3 full-gate runs, not re-run until
  green.
- **Limits carried:** the codex-cli 0.158.0/0.159.0 worktree commit
  restriction (no sandbox change made, no proven safe repair); Acceptance 8
  MEASURED with no product advantage shown, pending the human's ruling;
  failed/crash stops, a real quota refusal, late handoff delivery and the
  crash window unexercised live; no claim that every arbitrary
  terminal/projector-error path heals (three other terminal writers still do
  not project and recovery never projects; a persisted projector failure
  needs explicit rebuild — record §§16–17, `terminal-projection-fix.md`
  §5).
- **Iteration 6:** unlocked when this closeout PR passes independent review
  and the human merges it (unchanged).
