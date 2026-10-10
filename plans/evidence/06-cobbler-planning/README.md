# Iteration 6 evidence

REPO-INSPECTION: This directory follows the iteration-5 identifier and evidence
conventions. UUID fixtures must preserve their version and variant; synthetic
UUIDv7 example: `01950000-0000-7000-8000-000000000001`.

No credentials, provider-generated identifiers, machine identifiers, absolute
home paths, or hidden model reasoning are stored here. Commands use `$WORKTREE`
for the implementation worktree and `$REGRESSION` for its owned proof worktree.

Claim labels: VERIFIED means command output from this run or a committed
artifact; REPO-INSPECTION means inspected repository code; SCHEMA-ONLY means a
schema without runtime integration; UNVERIFIED means not verified.

## Documents

- `task-retirement.md` — explicit approval-gated scope reduction with retained
  task identities/contracts, evidence rechecks and CLI review.

- `duration-budgets.md` — lifetime provider/gate time, bounded gates, quota-wait
  exclusion and durable global acceptance failure.

- `quota-continuation.md` — canonical checkpoint lineage, same-provider quota
  recovery, continuation authorization, counters and amendment preservation.

- `cli-execution.md` — durable repository-only CLI execution requests, per-task
  cached-ledger admission, delivery recovery and material-code restart proof.

- `execution-profile.md` — saved agent revision/role, provider and model binding
  through admission, dispatch and provider protocol options.

- `amendment-core.md` — exact accepted-contract preservation, bounded approved
  activation, lifetime counters, regression and restart evidence.

- `executor-integration.md` — PR #90 review, behavioral regressions, process-group
  gate bounds, durable dispatch/worktree binding and worker/restart proof.
- `sequential-executor.md` — historical PR #90 author report; read its successor
  above for current claims and limits.

- `cli-approval.md` — package C's repository-only plan inspection, validated
  immutable JSON edits, exact-revision decisions and stored planner budget display.

- `configuration-and-usage.md` — persisted orchestrators, immutable CLI snapshot
  lookup, configuration/allowance UI, browser evidence, reconstructed regressions
  and the final-gate transaction-abort correction. Execution binding remains open.

- `planner-boundary.md` — package B's bounded fixture/local-model inference,
  quota admission, durable budget/replay, strict validation and single repair.

- `hermetic-lifecycle.md` — the iteration-5 follow-up end-to-end lifecycle
  test. The bounded hermetic task does not reopen iteration-5 acceptance.
- `plan-foundation.md` — work package A (goal and task contracts) plus the
  durable plan revision / approval / rejection foundation and its event
  replay. No executor, no model planner, no amendment orchestration, no
  approval UI.
- `plan-foundation-race-fix.md` — the independently reproduced red gate on
  PR #89 at `f265da6`, its root cause in the plan store's read-then-write
  idempotency windows and its structured-error contract, and the fix.
