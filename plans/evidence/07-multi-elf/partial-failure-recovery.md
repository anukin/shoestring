# Iteration 7: partial failure, replacement and cancellation

Implementation date: 2026-10-14. Baseline: `53d0c53` (scope resolution). The
user's direct-main/no-PR authorization for iteration 7 overrides the standing
worktree/PR workflow. Verification uses Fake, real local process groups on an
isolated node and local Git fixtures; no provider run was made.

## Classification

REPO-INSPECTION: execution status now gives every child a deterministic
`stop_class` derived from canonical resolutions and the latest run lifecycle
event:

| Class | Source |
| --- | --- |
| `accepted` | accepted, or human-accepted scope resolution |
| `task_failure` | gate failure, or `run.failed` with a task category |
| `adapter_failure` | `run.failed` with `transport`, `schema_incompatible`, `authentication_required` or `unsupported_capability` |
| `conflict` | scope-blocked or scope-rejected |
| `quota_sleep` | `run.suspended`, or `run.failed` with `quota_refused` |
| `interrupted` / `cancelled` | unresolved run terminals |
| `running` / `awaiting_verification` / `superseded` | in flight, terminal not yet verified, replaced by amendment |

## Bounded replacement

REPO-INSPECTION: the fan-out coordinator now also admits replacement attempts.
A task qualifies only when all of the following hold:

- every attempt is resolved and the latest one failed with executor retry state
  `retry` (computed from task/total attempt and duration limits) or was a
  rejected conflict;
- its dependencies are accepted and the execution is not cancelled.

Attempt `n + 1` reuses the deterministic reservation, run, command and
workspace identities and goes through normal admission (`admission_fun` receives
the attempt), budget and independence checks. It gets a fresh private Git store
at the approved base. The failed attempt's owners must already be settled: the
coordinator reconciles terminals first and re-checks settlement inside the
serialized dispatch transaction, so a replacement never overlaps the failed
attempt's process.

REPO-INSPECTION: the replacement prompt appends a bounded "Replacement context
(own task only)" section: the recorded failure plus
`Continuation.compose_handoff_prompt/2` over the previous attempt's latest
checkpoint. Lookup is scoped to that attempt's run chain with goal fallback
disabled, so sibling checkpoints and provider transcripts never enter it.
Quota sleep, interruption and cancellation never reach retry state `retry`
and are never replaced automatically; they keep the existing explicit
wake/handoff continuation and amendment paths. Sequential retries are unchanged.

## Cancellation

REPO-INSPECTION: `mix shoestring.execution cancel GOAL --execution-id ID
[--run-id RUN] --reason TEXT --command-id ID --by human:NAME` records
`cobbler.plan.cancellation.requested` and queues `PlanCancellationWorker`
(`plan_cancellation` queue, five attempts). The repository-only CLI stops
nothing itself. The service worker handles each target as follows:

- a provably never-started intent is fenced through
  `ReservationRecovery.cancel_unstarted/3` and re-projected;
- a started run goes through `Elves.cancel_run/2`, which terminates its owned
  process group (TERM, bounded grace, KILL) and records `run.cancelled` under
  the single-terminal key.

Terminal settlement then releases verified owners.
`cobbler.plan.cancellation.completed` (at most 64 listed outcomes) is appended
only when every target has stopped. Otherwise the job errors and retries, and
startup repair re-queues pending requests.

REPO-INSPECTION: a child-scope request must name the current run of an
unresolved child and stops only that run; its sibling keeps running. A
goal-scope request stops every unresolved child. It also fences the execution:
fan-out dispatch, sequential `advance/2` and plan continuation authorization
refuse with `:execution_cancelled`, and the sequential worker cancels its job.
Identical replay converges; a changed request conflicts. A cancelled child
stays unresolved and blocks goal completion until an explicit continuation or
an approved amendment resolves it.

## Verification

VERIFIED: the regression file was copied into an independent archive of
`53d0c53` with its own build and state.
`mix test test/shoestring/cobbler/plan_fanout_replacement_regression_test.exs`
exited 2: **1 test, 1 failure**, seed 427973. The baseline returned
`dispatched: []` for a failed child with retry state `retry`: it only ever
admitted first attempts. The test passes on the fix.

VERIFIED: `mix test test/shoestring/cobbler/plan_partial_failure_test.exs`
exited 0: **7 tests, 0 failures**. Covered:

- replacement through admission with only its own checkpoint (a sibling
  checkpoint marker is absent), a fresh worktree at the base, and replay
  without re-admission;
- adapter versus task classification, and escalation with no replacement
  after the task limit;
- quota sleep and interruption never replaced;
- child and goal cancellation of unstarted intent, including fencing of
  dispatch, advance and continuation;
- request validation and registry shapes.

Unit tests never cancel a started run, because that would signal a synthetic
process group id.

VERIFIED: the isolated-node lifecycle wrapper now requires **6 tests,
0 failures** and passed 3 of 3 consecutive runs after the final fix. The new
live scenarios cover:

- **child cancellation:** a running child with a real `sleep` process group is
  cancelled; its Elf exits, the group is gone (`kill -0`) and the sibling's
  Elf keeps running and is then accepted;
- **goal cancellation:** fences dispatch across a full application restart;
- **quota sleep and replacement:** a quota-refused child sleeps while a crashed
  (transport) sibling is replaced from attempt 1 to attempt 2 and accepted.

An earlier draft of the cancellation scenario failed: the fixture's stream
barrier blocks inside the Elf, so the cancel call could not run. The scenario
now releases a non-terminating stream before cancelling. That draft also
logged one `database is locked` error; it did not recur in the three passing
runs.

VERIFIED: `mix test test/mix/tasks/shoestring_execution_test.exs` exited 0:
**8 tests, 0 failures**, including CLI cancel replay and refusal.

VERIFIED: `mix precommit` exited 0: **4 doctests, 2145 tests, 0 failures,
1 skipped, 6 excluded**, seed 249869, 340.9 s (9.0 s async, 331.9 s sync).
JavaScript passed **52/52** and **8/8**.

## Remaining limits

UNVERIFIED: no live provider cancellation; Claude/Codex group termination uses
the same Elf path, verified here only with Fake. A goal cancellation does not
change the generic goal row: it stays `active`. Replacement attempts still need
production activation, which is the next package.
