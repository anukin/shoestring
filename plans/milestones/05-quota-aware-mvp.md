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
  is fixture-authored, and work package G's "audit all cards" clause was not
  performed. The hard dependency (iteration 4 complete) is **not** satisfied.
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
  combination; UI was never visually inspected. Full list in the closeout
  evidence §6–§7.
- **Instructions for iteration 6:** **Do not start iteration 6 on this
  result.** This milestone's own condition — iteration 4 complete and the eval
  gates met — is unsatisfied on both counts: iteration 4 carries an open
  UNVERIFIED second Codex live turn after its normalization fix, and the eval
  gate's real-cross-provider and real-semantic halves are unmet. To unlock
  iteration 6: close the iteration-4 live turn, evaluate at least one real
  cross-provider handoff under an authorized budget, obtain semantic evidence
  that is not fixture-authored, and complete work package G's audit of all
  cards.
