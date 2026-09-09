# Milestone 05: Hermetic Scripted Demo (WP Eval, T6)

- **Status**: Eval work package (Milestone 05, stacked on `c3779f0`).
- **Scope**: Scripted end-to-end test (`demo_test.exs`) + this transcript.
  Tests + docs only; no production code changed.
- **Evidence Label**: `VERIFIED` (hermetic ExUnit run in this worktree).
  Fake-to-Fake only; no provider CLI, no network, `FixedClock`.

---

## Transcript (8 steps, two Fake legs, two request logs)

Fixture identifiers below are synthetic (`01950000-…` shape for fixed ids,
generated UUIDs for rows); no credentials, paths, or machine identifiers.

1. **Submit** — goal `Eval demo goal` + task created; `admission.decided`
   (`admit/automatic_admission_eligible`) appended as the admission
   evidence.
2. **Lease grant** — `Dispatcher.claim_and_gate/3` with `grant_lease:`
   issues the execution lease (`proposed → granted → active`); Oban stays
   at zero jobs.
3. **Partial work** — first Fake leg (`sudden_quota_refusal`, request log
   A): `lifecycle → output → error` streams; partial output recorded.
4. **Injected exhaustion** — terminal stream event is
   `quota_refused/rate_limit_exceeded`; no further model output exists.
5. **Deterministic checkpoint** — `CheckpointFallback.build/1` +
   `Checkpoints.record/3` persist `stop_reason: quota_refused` with forced
   `checkpoint-fallback-v1` provenance; `Continuation.for_goal/1` resolves
   the pointer.
6. **Restart-while-sleeping** — run suspended; wake intent scheduled; two
   `Wakeups.reconcile/1` passes converge on exactly one `wakeup`-queue
   job (simulated reset, no duplicate delivery).
7. **Wake + provider switch** — `perform_wakeup/2` with a FRESH eligible
   snapshot renews (chained to the fresh id) and resumes; `Elves.resume_run/3`
   hands off to the second Fake leg (`handoff_target`, request log B),
   whose recorded continuation carries pointer keys only
   (`checkpoint_id`, `decision_refs`, `next_action`) — the first leg's
   transcript text travels nowhere.
8. **Terminal projection** — the switched leg runs to `run.completed`;
   the goal projects cleanly; `handoff.created` records the checkpoint
   pointer, prior run, and target provider. Every decision (admit, lease,
   checkpoint, wake, handoff) remains explainable from persisted inputs,
   and the Cobbler goal page renders the matching reasons (row 10 of the
   matrix).

## Completion Record

- New files: `test/support/eval_matrix_helpers.ex`,
  `test/shoestring/harness/eval_matrix/{matrix_test,ablation_test,demo_test}.exs`,
  `plans/evidence/05-quota-aware-mvp/{eval-matrix-results,ablation,demo}.md`.
- No production changes; no `UNWIRED` rows; live handoff explicitly
  live-`UNVERIFIED` (no budget authorized — see `eval-matrix-results.md` §5).
- Gate: `mix precommit` (exact command and counts in the work report).

---

## Loop-Closure Addendum — 2026-09-09 (`VERIFIED`, hermetic)

The transcript §§1–8 above is quoted unchanged from the T6 work package. This
section records the I7 genuine loop-closure revision (branch
`polly/iter5-i7-evals`, stacked on `cc116f4`): step 8 no longer hand-appends
`run.starting` / `run.running` / `run.completed`. Tests + test support +
these docs only; no production code changed.

### Revised step 8 — terminal through resumed execution

After the step-7 handoff (fresh `start` on request log B, zero `resume`s,
pointer-only continuation), the demo rebuilds the leg-B request from the
durable run row and asserts it is byte-equal to the genuinely composed
handoff prompt (checkpoint pointer + `next_action` + decision refs, zero
transcript text). It then binds a real supervised Elf to the handoff run via
`Dispatches.enqueue_for_run/1` + `Elves.start_elf/3` (Fake `handoff_target`
leg, trivial local command, `FixedClock`):

- The Elf appends `run.starting` / `run.running` itself, streams the three
  scripted leg-B events, classifies the terminal `RESULT`, and commits
  `run.completed` plus the automatic I3 terminal checkpoint through its
  production path; the test awaits `{:elf_terminal, run_id, %{class:
  :completed}}`.
- The test asserts the `eval-matrix` actor appears nowhere on the handoff
  run, the terminal bears the Elf's durable `elf-terminal:<dispatch_id>` key,
  and the projected `RunRecord` status is `completed`.
- The step-7 `handoff.created` assertions (checkpoint pointer, prior run,
  target provider) are unchanged and still green.

**UNWIRED rows: none.** Cross-provider LIVE remains explicitly
live-`UNVERIFIED` (no budget authorized).
