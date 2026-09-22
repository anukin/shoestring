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
