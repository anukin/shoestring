# Hermetic lifecycle work ledger

VERIFIED: The sections below preserve measured intermediate failures and
scope decisions. Their unfinished-status statements describe those revisions;
the continuation results at the end supersede them. No earlier red run is
reported as green.

## Baseline

VERIFIED: Both authorized worktrees initially had clean source state at
`a68744e2c6506dc646bb050a20a88964822c59c7`.

VERIFIED: `mix help precommit < /dev/null` reported the alias in `mix.exs`:
format check, compilation with warnings as errors, tests, `gate_0a.node_test`,
and `ui.node_test`.

VERIFIED: The first `timeout 300 mix precommit < /dev/null` exited 1 before
any tests: the worktree lacked dependencies (`Unknown dependency :ecto_sql`
in formatter `import_deps`). Ignored dependency/build artifacts were copied
from the local source checkout into the authorized worktrees. The source
checkout was read only; no package fetch or provider/network run was used.

VERIFIED: The subsequent baseline `timeout 300 mix precommit < /dev/null`
passed: **4 doctests, 1509 tests, 0 failures, 1 skipped (6 excluded)**;
Node capacity gate **52 tests, 52 pass, 0 fail**, UI gate **7 tests, 7 pass,
0 fail**. ExUnit seed was 320405. These are baseline figures, not final figures.

## Pre-fix ledger

| Change | Pre-fix commit | Command | Observed behavioral failure |
| --- | --- | --- | --- |
| UI Fake scenario conversion | `a68744e2c6506dc646bb050a20a88964822c59c7` | `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs --seed 0 < /dev/null` in `$REGRESSION` | 1 test, 1 failure; submitted success run projected `failed`, expected `completed` |
| Terminal active-lease settlement | `5220effb7adcb2fa5330393b37adce56503e7ee5` | Same command in `$REGRESSION` | 1 test, 1 failure; completed run retained lease status `active` |

VERIFIED: The scenario correction was committed at
`5220effb7adcb2fa5330393b37adce56503e7ee5`. Its focused post-fix run passed:
1 test, 0 failures. The commit message contains no attribution trailers.

VERIFIED: The lease change passes the inactive-lease assertion, but the next
terminal-UI assertion fails; this is not reported as a passing composed test.

## Test development failures (not regression proofs)

VERIFIED: Initial launcher construction failed because `@file` is a reserved
module attribute (1 test, 1 failure). The launcher attribute and fixture button
selector were corrected before behavioral proofs. One diagnostic edit lacked
the Ecto.Query macro import and failed child compilation (parent 1 test,
1 failure); this is not a behavioral proof. Diagnostic variants continued to
fail the terminal-UI assertion and were never used as rerun-until-green.

VERIFIED: A forced test compilation, `MIX_ENV=test timeout 60 mix compile
--force < /dev/null`, compiled 180 files and did not resolve the UI failure.
The focused command following it still reported 1 test, 1 failure.

## Current blocker and remaining acceptance

VERIFIED: On the real submission trajectory, the goal page renders
`#cobbler-goal-status[data-status="unknown"]` after successful completion.
REPO-INSPECTION: `CobblerPresentation.trajectory_timeline_event/1` does not
recognize or skip the ordinary `run.requested` event. That presentation file
is outside the brief's allowed source-fix scope. A narrowly scoped extension
was requested; no excluded source file has been edited.

UNVERIFIED: The full quota/refusal/checkpoint/application-restart/restored-wake/
exactly-one-continuation/completion chain, naturally completed deadline twin,
and green final gate have not yet been demonstrated. I did not verify these.
The active goal is not complete. Publication status is recorded below.

## Lease twin runs and contract update

VERIFIED: `timeout 180 mix test test/shoestring/elves/
 test/shoestring_web/live/run_new_entry_test.exs
 test/shoestring_web/live/run_new_manual_lease_test.exs --seed 0 < /dev/null`
(first three path arguments on one command line) reported **189 tests,
5 failures**. Four failures came from retiring resting `renewed` leases.
At that intermediate revision their exact renewal-status assertions were
kept, and settlement was temporarily limited to active/granted on completion.
This intermediate choice was superseded at
`ca8670ac26911ed6173b0ed8921d1a0740f82c19`: final completed-run settlement
includes granted, active, renewal_due and renewed allowances. The affected
exact terminal assertions now require checkpoint_required while retaining
their canonical renewal/spend/checkpoint evidence. The measured red result
above is unchanged.

VERIFIED: The next `timeout 180 mix test
 test/shoestring/elves/elf_lease_loop_test.exs
 test/shoestring/elves/elf_lease_reloop_test.exs --seed 0 < /dev/null` reported
**31 tests, 1 failure**: a lifecycle-only completed Fake run's documentation
asserted that its lease stays active forever.

REPO-INSPECTION: That exact-status assertion conflicts with this brief's
terminal no-active-lease contract. It was changed to the exact retired state
`checkpoint_required`; its zero-spend, zero-renewal, zero-budget-expiration,
zero-reactive-checkpoint and exactly-one-terminal-checkpoint assertions remain.
Settlement now uses `lease.revoked` rather than describing successful
completion as budget expiration. No test is skipped or widened. This is a
reported update to an existing relevant regression test under the allowed
Elves test path.

## Later measured checks and restart boundary

VERIFIED: The updated lifecycle-only terminal regression failed against
`5220effb7adcb2fa5330393b37adce56503e7ee5` using
`timeout 60 mix test test/shoestring/elves/elf_lease_loop_test.exs:1434
--seed 0 < /dev/null`: **1 test, 1 failure (20 excluded)**, exact retired
state expected `checkpoint_required`, observed `active`.

VERIFIED: After the lease change, `timeout 180 mix test
test/shoestring/elves/elf_lease_loop_test.exs
test/shoestring/elves/elf_lease_reloop_test.exs --seed 0 < /dev/null` passed:
**31 tests, 0 failures**.

VERIFIED: The intermediate `timeout 300 mix precommit < /dev/null` at seed
507654 was RED: **4 doctests, 1510 tests, 2 failures, 1 skipped
(6 excluded)**. Node gates still passed **52/52** and **7/7**.
`timeout 120 mix test --failed --seed 507654 < /dev/null` identified both
failures: **2 tests, 2 failures** (terminal UI plus the Observatory renewal
twin's expected renewal boundary state). This was failure diagnosis, not
rerun-until-green. The settlement was temporarily narrowed to active/granted;
`timeout 60 mix test test/shoestring/cobbler/observatory_snapshot_twins_test.exs:283
--seed 507654 < /dev/null` then passed: **1 test, 0 failures (9 excluded)**.
There was not yet a green full gate at that intermediate revision. The later
completed-continuation regression demonstrated renewal_due retention, so
the shipped settlement includes renewal_due/renewed too; the final exact
terminal assertions were updated accordingly (see the later proof ledger).

VERIFIED: The child-node harness now actually calls
`Application.stop(:shoestring)` and `Application.ensure_all_started(:shoestring)`
against the SAME database path. It monitors the old application supervisor
and every started direct child, asserts their DOWN messages, and asserts new
child PIDs. Dispatch, wakeup and handoff reconcilers are enabled as actual
application children; their boot-pass `last_result` must have no failures.
The run, lease, full checkpoint struct (including acceptance/evidence), and
disk-backed worktree identity compare unchanged after restart. The task's
identity and acceptance prompt are asserted in checkpoint criteria. Owned
Elves are monitored and the recorded OS group is checked empty before restart.

VERIFIED: The initial restart scaffold's sandbox auto mode exhausted its
connection ownership slots and failed at connected UI mount (1 test,
1 failure). The isolated child now uses the ordinary DBConnection pool after
stopping the original application; the parent suite's sandbox is unchanged.
This is required hermetic restart setup, not a source sandbox repair. The
current focused command still reports **1 test, 1 failure**, reaching the
terminal UI assertion AFTER all restart/reconstruction assertions pass.

REPO-INSPECTION: The restart boundary is the entire `:shoestring` OTP
application, including Repo, trajectory registries/supervisor, PubSub, Oban,
recovery reconcilers, capacity supervisor/watcher, Elf registry/supervisor
and Endpoint. It is NOT a whole BEAM VM or machine restart. Provider monitors
stay disabled, no provider CLI runs, and no database or fixture is deleted.
The child launcher uses Python's bounded subprocess with stdin DEVNULL.

UNVERIFIED: Quota recovery, durable worker ownership of initial UI delivery,
replay convergence and the composed final completion remain unfinished.

VERIFIED: With the CURRENT restart-enabled test copied into the proof
worktree, the focused command was checked again at the two pre-fix commits
after harness changes. At `a68744e2c6506dc646bb050a20a88964822c59c7`,
**1 test, 1 failure** still reached `run.status`: observed `failed`, expected
`completed`. At `5220effb7adcb2fa5330393b37adce56503e7ee5`,
**1 test, 1 failure** reached the inactive-lease assertion: observed `active`.
The commands were identical to the pre-fix table above. Neither proof failed
on a missing API, module, signature, or running-event row.

## Published draft and current gate

VERIFIED: The branch was pushed. `timeout 30 gh pr create --draft --base main
--head polly/iter6-hermetic-lifecycle --title 'Build iteration 6 hermetic
lifecycle regression coverage' --body-file .shoestring/iter6-pr-body.md
< /dev/null` opened [draft PR #87](https://github.com/anukin/shoestring/pull/87).
`timeout 30 gh pr view 87 --json url,headRefOid,headRefName,isDraft,state
< /dev/null` confirmed OPEN, draft, the requested branch, and source/test
revision `16b0117e680fca7b33106ee4c4a6f743299eef64`. No merge was performed.
`git log a68744e2c6506dc646bb050a20a88964822c59c7..HEAD --format=full
< /dev/null` showed no attribution trailers in either implementation commit.

VERIFIED: On that exact source/test revision, `timeout 300 mix precommit
< /dev/null > .shoestring/iter6-current-precommit.log 2>&1` exited **2**:
**4 doctests, 1510 tests, 1 failure, 1 skipped (6 excluded)**, seed **430572**,
146.4 seconds. Node gates passed **52 tests, 52 pass, 0 fail** and
**7 tests, 7 pass, 0 fail**. The single failure is the composed scaffold's
terminal goal UI assertion; the renewal twin now passes in the full suite.
This is a measured RED gate, not completion. This repeat followed a source
change narrowing lease settlement after the earlier full-gate failure; it
was not rerun-until-green. No intermittent N-of-M claim has been established.

UNVERIFIED: The draft remains incomplete. No composed quota recovery or final
green gate has yet been established.

## Authorized continuation and worker/admission corrections

VERIFIED: The continuation brief explicitly authorized
`lib/shoestring_web/live/cobbler_presentation.ex` and narrowly related tests
for the demonstrated terminal UI failure, overriding the original exclusion.
It clarified that recovery must use provider-scoped admission with Fake
execution and scripted local observations; manual wakes stay refused.

| Correction | Pre-fix source commit | Command | Behavioral assertion |
| --- | --- | --- | --- |
| LiveView defers execution to durable worker | `bec3b75326fe6a2be1ef2245b5df260a92f4e827` | `timeout 60 mix test test/shoestring_web/live/run_new_worker_delivery_test.exs --seed 0 < /dev/null` | 1 test, 1 failure: an Elf was already registered before worker delivery, expected nil |
| Worker reconstructs persisted Fake scenario | `763c290aafc112d07d276c8d343fc16e0588a5d4` | `timeout 60 mix test test/shoestring_web/live/run_new_worker_delivery_test.exs:33 --seed 0 < /dev/null` | 1 test, 1 failure (1 excluded): submitted success projected failed, expected completed |
| Presentation accepts ordinary durable run intent | `ceb1629` | `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs --seed 0 < /dev/null` | 1 test, 1 failure: real terminal goal UI did not render completed after worker delivery and whole application restart |
| Configured provider submission observation | `9536654e03b8e36ba4d7ff6745d815900a45d9e3` | `timeout 60 mix test test/shoestring_web/live/provider_submission_test.exs --seed 0 < /dev/null` | 1 test, 1 failure: admission scope account:manual, expected subscription |

VERIFIED: The worker/entry focused command `timeout 90 mix test
test/shoestring_web/live/run_new_worker_delivery_test.exs
test/shoestring/harness/dispatch/elf_effect_test.exs
test/shoestring_web/live/run_new_entry_test.exs --seed 0 < /dev/null` first
reported 13 tests, 1 failure: the quiet Fake run's projection remains
requested until the normal producer projects it. The test now checks the
canonical run.running event and successful dispatch effect, rather than
assuming an incremental run projection. After that test correction the
command reported **13 tests, 0 failures**. The worker regression also
replays delivery and asserts one Elf and one run.running event.

VERIFIED: After the presentation mapping correction, the composed scaffold
focused command reported **1 test, 0 failures**. This was still a normal
success/restart scaffold, not the required quota-recovery journey.

VERIFIED: Provider/entry focused command `timeout 90 mix test
test/shoestring_web/live/provider_submission_test.exs
test/shoestring_web/live/run_new_worker_delivery_test.exs
test/shoestring_web/live/run_new_entry_test.exs
test/shoestring_web/live/run_new_manual_lease_test.exs --seed 0 < /dev/null`
reported **10 tests, 0 failures** after three development failures of
10 tests, 1 failure each: the observation timestamp postdated its event,
the test read the lease projection before worker delivery, and the test
mistakenly read a nonexistent direct scope field instead of the documented
lease extension. None of these diagnostic failures is a regression proof.

VERIFIED: Earlier worker-test construction diagnostics reported 1 test,
1 failure twice (incorrect requested/starting expectation, then a terminated
Elf barrier) and 2 tests, 2 failures once (launch-failure notification not
emitted and a terminated Elf barrier). The behavioral worker-scenario proof
above instead waits for the owned Elf monitor and asserts the honest durable
failed/completed status; no missing API or signature is involved.

REPO-INSPECTION: Provider submission observation is an opt-in scoped callback
in server configuration. Without it, the existing operator-declared manual
path remains. With it, the product entry records a goal-local observation,
evaluates normal admission, and claims using the durable decision's intent
and scope. The submission flow adds its own deterministic observation
namespace; other flow identities are unchanged. No test appends events or
calls a projector to force this journey forward.

## Composed recovery and later behavioral proofs

VERIFIED: The final child journey submits the real LiveView form, delivers
the durable DispatchWorker job, and runs Shoestring.Harness.Fake with a
scripted quota refusal. The Elf produces both its reactive checkpoint and
its deterministic terminal checkpoint. The failed run remains failed, with
`quota_refused/rate_limit_exceeded` evidence and its task/prompt acceptance
contract. Both checkpoint structs, the run, retired lease, wake intent and
disk worktree identity compare unchanged across the whole application stop
and start described above.

VERIFIED: After advancing the supervised test clock, WakeupWorker obtains
a fresh scripted subscription reading, evaluates admission, and enqueues
one continuation with the same goal, task, prompt and workspace. The new
lease references a new observed snapshot and an admitted durable decision.
The continuation receives the old terminal checkpoint's next action and
checkpoint identity; the old failed attempt is not resumed or rewritten.

VERIFIED: After completion and replaying both dispatch deliveries, the wake
delivery, the original producer wake request, and all three reconcilers,
the test asserts exactly **2 runs, 2 retired leases, 3 checkpoints, 3 delivery
jobs, 2 effect_completed dispatches, 2 run.running events, 1 run.failed and
1 run.completed**. The canonical timeline folds to completed and the
actual goal LiveView renders completed with no active lease. No test appends
events, mutates lifecycle rows or calls projection to advance this journey.

| Correction | Pre-fix commit | Exact command (stdin closed) | Behavioral result |
| --- | --- | --- | --- |
| Authorized quota continuation, retaining failed attempt | `302d169d59e1c67c0b5f1848e45a5f32f3e41623` | `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs --seed 0 < /dev/null` | 1 test, 1 failure: WakeupWorker returned unexpected_run_state failed, expected :ok, after restart assertions |
| Deferred checkpoint/quota presentation and continuation progress | `f9449e78c04de7d1b83f1217881bd168f85e9625` | `timeout 60 mix test test/shoestring_web/live/cobbler_quota_presentation_test.exs --seed 0 < /dev/null` | 4 tests, 3 failures: deferred/continued states unknown and queued continuation progress rejected; ordinary failure/unknown twin passed |
| Admit-only renewal keeps working/checkpointing state | `4fbf532babb60c7c2f4656719444f5a4535d7d5a` | Same pure presentation command | 5 tests, 1 failure: working + admit was rejected, expected working |
| Retire completed renewal allowances | `4fbf532babb60c7c2f4656719444f5a4535d7d5a` | `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs --seed 0 < /dev/null` | 1 test, 1 failure: completed continuation retained renewal_due, expected checkpoint_required |
| Replay settled producer wake request; reject ordinary failed attempt before probing | `ca8670ac26911ed6173b0ed8921d1a0740f82c19` | `timeout 120 mix test test/shoestring_web/live/hermetic_failure_refusal_test.exs test/shoestring_web/live/hermetic_lifecycle_test.exs --seed 0 < /dev/null` in `$REGRESSION` | 3 tests, 2 failures: replay created :r1 wake/job; ordinary failed worker returned :ok instead of unexpected_run_state failed. Manual quota refusal twin passed |
| Preserve queued domain dispatch guard while displaying authorized continuation | `ca8670ac26911ed6173b0ed8921d1a0740f82c19` | `timeout 60 mix test test/shoestring/cobbler/goal_lifecycle_test.exs --seed 0 < /dev/null` in `$REGRESSION` | 11 tests, 1 failure: queued dispatch was accepted instead of rejected |
| Final direct-hatch scenario lock (same initial Scenario correction) | `a68744e2c6506dc646bb050a20a88964822c59c7` | `timeout 60 mix test test/shoestring_web/live/run_new_worker_delivery_test.exs:33 --seed 0 < /dev/null` in `$REGRESSION` | 1 test, 1 failure (2 excluded): attributed direct Fake success failed instead of completed |

VERIFIED: The short pre-fix worker-scenario revision in the earlier table
is `ceb1629f6e81fc9feb3f40272e42797ce5e8da85`. The proof-worktree checks
above used committed pre-fix source with the same regression assertions,
not removed APIs or changed signatures. Earlier proof fixtures were retained
as commits `bd0918a4a3197df88047641fe0cf4a7e26c126b3` and
`e20db42e75f4d0e6048b30d4d3826f52ce961569` in owned proof refs; the later
wake proof fixtures are committed at
`96509fb8522b06433f4ebdbe0af047257cae4ab2` under an owned proof ref.
No destructive reset/clean or other checkout
edit was performed.

REPO-INSPECTION: Quota recovery is restricted to a failed canonical quota
terminal, the same producer decline wake command, deterministic reactive
checkpoint and retired lease for that run. It authorizes fresh execution
through normal admission/dispatch; it does not add a failed-to-starting
transition. Manual refusal executes before this failed-attempt guard.
Settled producer requests replay their original wake; explicit operator
recheck suffix behavior remains covered by existing wake tests.

VERIFIED: The pure domain queued-dispatch guard is preserved. A continuation
uses its existing durable claim, so its new admission yields queued without
another claim-acquired event. The read-only presentation fold recognizes
the ensuing run.starting evidence; the domain machine still rejects a bare
queued dispatch. This narrowing followed the measured full-gate failure,
not a widened test assertion.

## Additional measured commands and diagnostics

VERIFIED: All validation commands used foreground `timeout` and closed stdin.
Local logs are ignored diagnostic output, not committed transcripts. The
following table records the continuation's command/count history in addition
to the earlier ledger. Repeated commands followed a source/test correction
or an explicitly identified pre-fix comparison; none is rerun-until-green.

| Command | Measured outcomes, in order |
| --- | --- |
| `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs --seed 0 < /dev/null` during quota development | 1/1 (test wrongly demanded generic partial output in bounded checkpoint evidence); 1/1 (quota resume rejected); 1/1 (terminal UI after quota continuation); 1/1 (diagnostic renewal-admit timeline); 1/1 (completed renewal_due lease). Each denotes tests/failures |
| `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs test/shoestring_web/live/cobbler_quota_presentation_test.exs test/shoestring_web/live/cobbler_presentation_test.exs --seed 0 < /dev/null` | 20/1 before renewal case added; 21/0 after renewal and retirement fixes |
| `timeout 60 mix test test/shoestring_web/live/cobbler_quota_presentation_test.exs --seed 0 < /dev/null` | 4/3 pre-fix; 4/0 after first mapping fix; 5/1 pre-renewal fix |
| `timeout 180 mix test test/shoestring/elves/elf_lease_loop_test.exs test/shoestring/elves/elf_lease_reloop_test.exs test/shoestring/cobbler/observatory_snapshot_twins_test.exs --seed 0 < /dev/null` | 41/5: exact old terminal renewed assertions conflicted with completed retirement |
| `timeout 180 mix test test/shoestring_web/live/hermetic_deadline_completion_test.exs test/shoestring_web/live/hermetic_lifecycle_test.exs test/shoestring/elves/elf_lease_loop_test.exs test/shoestring/elves/elf_lease_reloop_test.exs test/shoestring/cobbler/observatory_snapshot_twins_test.exs --seed 0 < /dev/null` | 43/0 after exact final statuses were updated; canonical renewal assertions retained |
| `timeout 60 mix test test/shoestring_web/live/hermetic_failure_refusal_test.exs --seed 0 < /dev/null` | 1/1 before ordinary-failure guard; 2/0 after adding manual quota twin and guard |
| `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs test/shoestring_web/live/hermetic_failure_refusal_test.exs test/shoestring_web/live/hermetic_deadline_completion_test.exs --seed 0 < /dev/null` | 3/0 after wake replay/failure fixes |
| `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs --seed 0 < /dev/null` while strengthening final assertions | 1/1 (nonexistent direct admission field); 1/1 (snapshot link read at wrong payload level). These were test-development mistakes, not source proofs |
| `timeout 120 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs test/shoestring_web/live/hermetic_failure_refusal_test.exs --seed 0 < /dev/null` | 3/0 after correcting the assertion to observation.snapshot_id |
| `timeout 180 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs test/shoestring_web/live/hermetic_deadline_completion_test.exs test/shoestring_web/live/hermetic_failure_refusal_test.exs test/shoestring_web/live/provider_submission_test.exs test/shoestring_web/live/run_new_worker_delivery_test.exs test/shoestring_web/live/cobbler_quota_presentation_test.exs test/shoestring/cobbler/wakeup_manual_scope_test.exs test/shoestring/cobbler/wakeups_test.exs test/shoestring/cobbler/wakeup_worker_test.exs --seed 0 < /dev/null` | 16/1: direct-hatch test omitted fixture form values. The last two path arguments did not select files; this is not claimed as their coverage |
| `timeout 180 mix test test/shoestring_web/live/hermetic_lifecycle_test.exs test/shoestring_web/live/hermetic_deadline_completion_test.exs test/shoestring_web/live/hermetic_failure_refusal_test.exs test/shoestring_web/live/provider_submission_test.exs test/shoestring_web/live/run_new_worker_delivery_test.exs test/shoestring_web/live/cobbler_quota_presentation_test.exs test/shoestring/cobbler/wakeup_manual_scope_test.exs test/shoestring/cobbler/wakeup_idempotency_test.exs test/shoestring/cobbler/wakeup_production_test.exs test/shoestring/cobbler/wakeup_reconcile_test.exs test/shoestring/cobbler/wakeup_continuation_test.exs --seed 0 < /dev/null` | 43/0 with real wake-test paths and complete form submission |
| `timeout 120 mix test test/shoestring/cobbler/goal_lifecycle_test.exs test/shoestring_web/live/cobbler_quota_presentation_test.exs test/shoestring_web/live/hermetic_lifecycle_test.exs --seed 0 < /dev/null` | 17/0 after preserving domain guard and narrowing presentation |

VERIFIED: Formatting used `timeout 60 mix format` with explicit changed
Elixir source/test paths and `< /dev/null`; all formatting invocations exited
0. `git diff --check` passed. `mix help precommit` was read again before
the final gates and reported the same five-part alias.

VERIFIED: The full continuation gate before the domain-guard narrowing,
`timeout 300 mix precommit < /dev/null > .shoestring/iter6-final-precommit.log
2>&1`, exited **2**, seed **765604**, **4 doctests, 1522 tests, 1 failure,
1 skipped (6 excluded)**, 158.3 seconds. The failure was the existing
queued-dispatch guard assertion. Node gates passed **52/52** and **7/7**.

## Exact boundaries and deferred work

VERIFIED: The deadline twin submits a real provider-scoped Fake run, advances
the supervised clock past its declared deadline before worker delivery, and
lets its scripted final response complete naturally. It asserts one completed
run, one retired lease, one completed checkpoint, no failed/pausing/suspended
events, no wake, no replacement dispatch, completed visible UI and a reaped
owned process group. Existing running-renewal/deadline twins were also run.

UNVERIFIED: This new deadline twin is delayed delivery beyond the deadline;
it is not a real-time timer crossing during an outstanding provider response.
No live provider behavior, whole-BEAM/machine restart, or independent
different-vendor review was verified. The PR remains draft pending that review.

REPO-INSPECTION: The completed goal projection here is the canonical timeline
fold and its actual LiveView representation. The separate administrative
Goal.status row is not repurposed or manually set to completed. The preserved
database and worktree state live inside the bounded child VM's unique local
state directory; fixtures are retained rather than deleted. Test-created
clock/fixture helpers are supervised outside the restarted application.

VERIFIED: Final completed allowances include granted/active/renewal_due/renewed.
Relevant existing terminal lease assertions were changed to exact
checkpoint_required, preserving their spend, renewal and checkpoint assertions.
No skips, sleeps, retries, Process.alive? assertions, forced lifecycle rows or
widened outcome assertions were added. The initial delivery's source scope extension was the
explicitly authorized presentation file and narrowly related tests; the exact
evidence .gitignore allowlist is authorized. Plan validation, DAG/planner/schema
work and iteration-5/live follow-ups remain deferred.

## Final gate

VERIFIED: After the actual source corrections, on source/test commit
`b61146a38ad9d3631480ad194e5235df22874d15`, the foreground command
`timeout 300 mix precommit < /dev/null >
.shoestring/iter6-final-precommit-after.log 2>&1` exited **0**:
**4 doctests, 1522 tests, 0 failures, 1 skipped (6 excluded)**;
ExUnit seed **489604**, elapsed **150.8 seconds**. Capacity Node gate:
**52 tests, 52 pass, 0 fail**. UI Node gate: **7 tests, 7 pass, 0 fail**.
Formatting and compilation with warnings as errors passed as part of that
same alias. The existing skipped test and live exclusions were not changed.

VERIFIED: The final source was measured once by the full gate, after the
domain-guard correction and its 17/0 focused check. Earlier red gates in
this ledger used different implementation states. No intermittent N-of-M
failure was established, and no gate was rerun without a relevant change.
Only evidence/publication metadata changes followed that green gate before
the review-fix round recorded below.

## Final publication

VERIFIED: `timeout 60 git push origin polly/iter6-hermetic-lifecycle
< /dev/null` pushed all implementation commits through
`b61146a38ad9d3631480ad194e5235df22874d15`. `timeout 30 gh pr edit 87
--title 'Prove hermetic quota recovery across application restart'
--body-file .shoestring/iter6-pr-body.md < /dev/null` updated the SAME
[PR #87](https://github.com/anukin/shoestring/pull/87). The body file contains
real newlines. `timeout 30 gh pr view 87 --json
url,headRefOid,headRefName,isDraft,state,title,body < /dev/null` plus a JSON
comparison verified exact body equality (15 lines), no literal backslash-n
separators, OPEN/draft, the requested branch and pushed implementation SHA.

VERIFIED: `git log a68744e2c6506dc646bb050a20a88964822c59c7..HEAD
--format=full < /dev/null` was inspected for attribution trailers; none were
present. Evidence-only publication recording is committed and pushed after
the source/test gate. No merge or ready-for-review operation was performed.

## Review-fix round at reviewed head b304aac

VERIFIED: The review-fix brief identified reviewed head
`b304aac793aa75f5d07671a9ccedbd53ed2afd38`, preserved the original hermetic
task and PR #87, and explicitly authorized a narrow dispatch-configuration
scope extension. This round edits only `config/runtime.exs` within that new
extension; the earlier presentation scope extension remains authorized.
No config/dev/config/test global execution enablement, planner, DAG or schema
changes are included. Prior red gate outputs are preserved in this ledger.

REPO-INSPECTION: Removing direct LiveView execution exposed a supported dev
configuration gap. The dev runtime selected no effect, while DispatchWorker's
default UnconfiguredEffect returned dispatch_effect_not_configured.
Production already selected ElfEffect. The fix moves that existing setting
into a dev/prod-only runtime guard; unconfigured/test behavior stays fail-closed.

VERIFIED: `RuntimeDispatchEntryTest` starts bounded child VMs for dev and
prod separately, loads and merges the actual runtime file, and restarts the
actual Shoestring application against each child's retained state directory.
It does not inject an effect under test. Inherited test settings keep provider
monitors, the HTTP server and automatic queues/plugins disabled. It submits
a real Fake LiveView run and drains only its durable dispatch queue through
Oban's normal worker, then monitors the owned Elf and checks its OS group.
This verifies configured delivery, not real providers or automatic queue
polling. A separate test asserts normal test runtime configures no effect.

REPO-INSPECTION: The insertion-conflict branch previously suffixed a settled
row even when the ordinary lookup branch replayed the same producer decline.
The fix mirrors the same reason/run/command comparison in unique-conflict
recovery; explicit operator rechecks retain their suffix semantics.

VERIFIED: `WakeupConflictReplayTest` creates and settles a real producer wake
through LiveView, Fake quota failure and WakeupWorker's normal manual refusal.
Its supervised repository wrapper models a race loser with a stale first
negative lookup. The insert goes to the real Repo and fails on the real
SQLite unique index; the test asserts this branch was reached before asserting
replay. It checks one wake/job/run/dispatch and no probe. The operator twin
reaches the same real conflict but creates the permitted new suffix/job.
No lifecycle rows are manually mutated to settle fixtures. This deterministically
tests a conflict window, not concurrent scheduler stress.

VERIFIED: Tracing the operator-envelope note demonstrated another lost direct
entry option: durable ElfEffect did not reconstruct the persisted max_events
stream ceiling. At the reviewed head a real UI submission with a 10-event
ceiling completed 11 scripted lifecycle events plus a result. The minimal fix
restores that existing option from the durable extension (valid positive
integers); requests without it and server overrides are unchanged. The test
now asserts failed/log_overflow, no completion and a reaped group. This
adjacent demonstrated fix stays within the original authorized harness scope.

| Correction | Pre-fix source SHA | Behavioral proof |
| --- | --- | --- |
| Dev runtime selects durable execution | `b304aac793aa75f5d07671a9ccedbd53ed2afd38` | Dev dispatch effect_failed, expected effect_completed; prod twin passed |
| Unique-conflict producer replay | Same reviewed SHA | Real unique conflict reached; replay created :r1 wake/job, expected original wake/job nil; operator suffix twin passed |
| Persisted whole-run event ceiling | Same reviewed SHA | 10-event ceiling completed over-limit stream, expected failed/log_overflow |

VERIFIED: The combined pre-fix command was
`timeout 180 mix test test/shoestring_web/live/runtime_dispatch_entry_test.exs
test/shoestring_web/live/wakeup_conflict_replay_test.exs
test/shoestring_web/live/run_new_worker_delivery_test.exs --seed 0 < /dev/null`.
It reported **9 tests, 3 failures** at unchanged reviewed source in the main
worktree and again in the owned proof worktree at that SHA. Neither failed
on missing APIs, modules or signatures. Proof fixtures are retained in owned
ref refs/iter6/review-fix-proofs at
`dbe8fdc67f7e1632949deff3bd83516286e6252b`; no destructive cleanup was used.

VERIFIED: The historical settlement paragraphs now explicitly distinguish
temporary active/granted-only settlement from the shipped completed guard
including granted/active/renewal_due/renewed. Exact terminal assertions became
checkpoint_required, retaining renewal/spend/checkpoint evidence. Earlier red
counts were not changed or described as green.

## Nonblocking review-note disposition

REPO-INSPECTION: Provider admission's 10-response/25-tool defaults are budgets
for a renewable lease epoch, capped by the operator envelope; they are not
whole-run totals. LeaseBounds accounts completed responses/tools; the run
ceiling counts normalized harness events. Only fresh admitted renewal
replenishes an epoch without relaxing the whole-run ceiling. This distinction
is documented next to the policy. Numerical epoch policy is unchanged.
The provider test pins the 10/25 proposal and separate persisted 1000-event
envelope; these assertions document existing behavior, not a pre-fix failure.

REPO-INSPECTION: Terminal settlement remains best-effort. Returned projection
or settlement errors log run/dispatch context, but rescue/catch lacks equal
detail; there is no durable success marker specifically for this helper.
It does not launch, suspend or schedule a replacement Elf on failure.
Write/projection failure can leave a stale lease view or partial retirement;
observability/atomicity hardening is a follow-up, not a demonstrated source
correction in this round.
UNVERIFIED: I did not inject terminal-settlement storage failures or verify
crash atomicity between retirement events. Existing restart, deadline and
renewal tests prove the successful boundary; their earlier limitations remain.

## Review-round measured commands

VERIFIED: Commands were foreground, bounded and stdin closed. Before source
fixes, `timeout 180 mix test
test/shoestring_web/live/runtime_dispatch_entry_test.exs
test/shoestring_web/live/wakeup_conflict_replay_test.exs --seed 0 < /dev/null`
first reported **5 tests, 3 failures**: two harness diagnostics (scheduled jobs
not drained; runtime endpoint config replaced rather than merged) and the real
producer conflict failure. After fixing only the harness merge/drain setup,
it reported **5 tests, 2 failures**: dev effect_failed and producer duplicate;
prod and operator twins passed. The diagnostics are not runtime proofs.
Adding the event-ceiling assertion yielded the **9/3** proof above.

VERIFIED: After source fixes, `timeout 180 mix test
test/shoestring_web/live/runtime_dispatch_entry_test.exs
test/shoestring_web/live/wakeup_conflict_replay_test.exs
test/shoestring_web/live/run_new_worker_delivery_test.exs
test/shoestring_web/live/provider_submission_test.exs --seed 0 < /dev/null`
passed **10 tests, 0 failures**.

VERIFIED: The broader command was
`timeout 240 mix test test/shoestring_web/live/runtime_dispatch_entry_test.exs
test/shoestring_web/live/wakeup_conflict_replay_test.exs
test/shoestring_web/live/hermetic_lifecycle_test.exs
test/shoestring_web/live/hermetic_deadline_completion_test.exs
test/shoestring_web/live/hermetic_failure_refusal_test.exs
test/shoestring_web/live/provider_submission_test.exs
test/shoestring_web/live/run_new_worker_delivery_test.exs
test/shoestring_web/live/cobbler_quota_presentation_test.exs
test/shoestring/cobbler/wakeup_manual_scope_test.exs
test/shoestring/cobbler/wakeup_idempotency_test.exs
test/shoestring/cobbler/wakeup_production_test.exs
test/shoestring/cobbler/wakeup_reconcile_test.exs
test/shoestring/cobbler/wakeup_continuation_test.exs
test/shoestring/elves/elf_lease_loop_test.exs
test/shoestring/elves/elf_lease_reloop_test.exs
test/shoestring/cobbler/observatory_snapshot_twins_test.exs --seed 0 < /dev/null`.
It passed **90 tests, 0 failures**, **50.1 seconds**, including the original
composed restart and natural-deadline tests.

VERIFIED: `timeout 60 mix format` with explicit changed source/test paths and
`< /dev/null` exited 0; `git diff --check` passed. `timeout 60 mix help precommit
< /dev/null` again reported the format/compile/test/two Node gate alias.
Review source/tests are committed at
`310e2e8f3be809661f6742d12ec69cc31940185a`; its message has no attribution trailer.

VERIFIED: On that source/test commit, after all review source changes, the
foreground command `timeout 300 mix precommit < /dev/null >
.shoestring/iter6-review-precommit.log 2>&1` exited **0**:
**4 doctests, 1528 tests, 0 failures, 1 skipped (6 excluded)**;
seed **114591**, **150.3 seconds**. Capacity Node gate: **52 tests, 52 pass,
0 fail**. UI Node gate: **7 tests, 7 pass, 0 fail**. Formatting and compile
with warnings as errors passed within the same alias. No new skip or live
exclusion was introduced. The review implementation was measured by one
full gate; no intermittent failure was established. Pre-fix failures were
reproduced deliberately in both owned worktrees, not rerun until green.
Only evidence and PR metadata changes follow this green review gate.

UNVERIFIED: Independent different-vendor re-review of these fixes is pending.
PR #87 remains draft. The full OTP application restart (not BEAM/machine),
delayed-delivery deadline twin, deterministic modeled conflict window and
manual queue drain boundaries are explicit above; no live provider or
network execution, concurrent stress, automatic polling, or retirement crash
atomicity was verified in this round. I did not verify these.
