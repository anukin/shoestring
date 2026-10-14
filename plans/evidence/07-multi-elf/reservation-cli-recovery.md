# CLI reservation inspection and recovery — 2026-10-13

## Scope and ownership

VERIFIED (user direction): continue on main without a PR or approval stops
between implementation packages. This overrides the standing worktree/PR
workflow. Baseline: `770a1b61c1baf5d465e835b88b47c6daab0596a0`.
No live provider calls were made.

REPO-INSPECTION: [the CLI](../../../docs/cli-reservations.md) provides bounded
read-only listing and inspection plus durable `reconcile` and
`cancel-unstarted` requests. Inspection exposes owner/parent/task/run,
configured concurrency weights and policy, scoped occupancy, admitted
observation and projected capacity windows, dispatch, settlement and results.
It omits raw prompts, transcripts, provider sessions and arbitrary metadata.
Overdue state is evidence only and continues to occupy capacity.

REPO-INSPECTION: repository-only CLI startup cannot see the service's live Elf
registry. Recovery therefore queues a UUID-bound, human-attributed operation
for the running service rather than drawing ownership conclusions in the CLI
process. Request row, canonical requested event and delivery job commit
together. The service validates canonical request authority, evaluates ownership
under the reservation writer/immediate transaction, and commits its canonical
result with settlement/cancellation. Changed cache or command reuse cannot
authorize a second observation. Replay returns the original result. A later
observation requires a new command UUID.

REPO-INSPECTION: a new `reservation_control` queue has concurrency one. A startup
repair pass restores delivery for existing pending operations only. It neither
creates new recovery decisions nor starts/cancels a provider automatically.
Completed operations are not repaired. Lost/discarded Oban jobs do not erase
the durable request. The new migration adds the operation table; no existing
ownership or evidence is deleted. Scratch fixtures include **23 migrations**.

## Never-started cancellation

REPO-INSPECTION: cancellation is allowed only for a same-goal requested run,
an absent live Elf, harmless initial intent/grant history, and no possibly
started dispatch. Missing run intent uses the existing conservative orphan
reconciliation. Missing canonical initial run intent is repaired from its
durable row before canonical cancellation. Multiple/mismatched dispatches,
advanced run state, checkpoint/harness/running evidence, claimed or ambiguous
effects and unavailable ownership lookup all retain capacity.

REPO-INSPECTION: a successful cancellation atomically records cancelled dispatch,
canonical `run.cancelling`/`run.cancelled`, a released settlement with basis
`never_started_intent_fenced`, and the canonical operation result. Original
owner and evidence remain. Projection catches up inside that transaction.
The settlement blocks late intent/resume/effect paths. An already queued job
may still be delivered, but its effect claim sees cancelled state and skips.
Job state alone is never used as process proof. No target process is signalled,
killed, replaced or inferred stopped from elapsed time.

REPO-INSPECTION: the effect claim and cancellation use the same SQLite write
boundary. If cancellation wins, delivery cannot execute. If effect admission
wins, cancellation records retained/uncertain ownership and capacity stays
held. A failed final result write rolls back cancellation, projection and
settlement together, leaving the original request pending.

## Verification and failed attempts

VERIFIED: `mix compile --warnings-as-errors` exited **0** after implementation.
Focused commands ran in the foreground with stdin closed and a 180-second
bound. The initial two-file set was:

```text
mix test test/mix/tasks/shoestring_reservations_test.exs test/shoestring/cobbler/reservations_test.exs
```

Runs 3–4 also included
`test/shoestring/cobbler/reservation_recovery_integration_test.exs`.

| Run | Exit | Actual result | Seed | Duration | Finding/change before next run |
| --- | --- | --- | --- | --- | --- |
| 1 | 2 | 35 tests, 4 failures | 868543 | 2.3s sync | Canonical task-dispatch intent was incorrectly treated as execution evidence; added it to the harmless intent allowlist. Fixture capacity was not projected; projected it before inspection checks |
| 2 | 0 | 35 tests, 0 failures | 968215 | 2.4s sync | CLI, cancellation, immutable requests, repair and redaction checks passed |
| 3 | 0 | 39 tests, 0 failures | 430038 | 6.1s sync | Added isolated restart/race, execution evidence, rollback and ownership uncertainty checks |
| 4 | 0 | 40 tests, 0 failures | 269907 | 6.1s sync | Added refusal of completed-cache rollback to pending before any second probe |

VERIFIED: inspection tests assert both directions: sensitive prompt, session,
snapshot extension, operation metadata and free-form reason sentinels are
absent; required owner, admission, snapshot, configured units and operation IDs
remain. CLI validation refuses duplicate/unknown options, invalid limits and
non-human recovery attribution without creating additional operations.
Canonical command/cache tampering is refused before recovery effects.

VERIFIED: an isolated child uses a normal database connection pool, queues
recovery through the real CLI, restarts the application, repairs a discarded
job, and races cancellation against effect admission on separate processes/
connections. It permits exactly the two safe outcomes above and checks canonical
result count, replay and restart preservation. The wrapper requires **1 child
test, 0 failures**; the full gate counts that wrapper as one outer test. No
provider is invoked; this race tests effect admission, not provider execution.

VERIFIED: `mix precommit` exited **0**: **4 doctests, 2004 tests, 0 failures,
1 skipped (6 excluded)**, seed **540492**, **197.4 seconds** (9.3 async,
188.1 sync), wall **201.106 seconds**. JavaScript passed **52/52** and **8/8**,
with zero failures or skips. The command ran in the foreground with stdin
closed and a 480-second bound; the isolated child has a 90-second bound.

VERIFIED: **21 relative Markdown links** across the iteration-7 milestone,
evidence and linked CLI documentation resolve. All **13 new artifacts** passed
home-path, credential-pattern and authorship-trailer scans. The final staged
diff passes `git diff --cached --check`.

REPO-INSPECTION: these are new-capability checks. No baseline regression lock is
claimed: this CLI, operator-request contract and never-started cancellation
boundary do not exist at the baseline. The initial red tests were followed by
implementation/fixture corrections, not unchanged reruns until green.

## Remaining work

REPO-INSPECTION: unknown effects, lost process identity and launch-failed
terminals without ownership evidence still retain capacity. This package does
not make those ambiguous histories releasable by assertion. Live cancellation
remains with the supervising Elf. Released cancelled attempts remain unresolved
plan work; this request never silently retries or approves replacement work.

REPO-INSPECTION: initial reservation activation remains opt-in. The next
iteration-7 packages are deterministic independence/overlap decisions,
independent sibling bases, concurrent dispatch ownership, durable child
inbox/wakeups and partial-failure recovery. Iteration-6 canonical goal status,
public output and verification-budget follow-ups remain before fan-out.

UNVERIFIED: live provider recovery, arbitrary lost-identity release, distributed
operation delivery and parallel execution were not verified in this package.
