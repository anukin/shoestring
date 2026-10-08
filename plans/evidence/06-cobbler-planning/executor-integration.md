# Executor review and integration — 2026-10-08

REPO-INSPECTION: base main `cb8f2a1709d2f7cdf684da3225c84b5b54f1aee7`;
reviewed PR #90 commit `ec7b644b86221b2a68728da4a41dfc77382001c5`.
The user explicitly authorized direct implementation, merge, commit and push on
main, overriding standing source-isolation and PR/never-merge rules. User-owned
untracked hook/configuration directories remain untouched. No provider calls.

## Review rulings

BLOCKER — `PlanExecutor.complete_fresh_dispatch` required any terminal, including
failed/interrupted/cancelled; passing gates then wrote `run_completed: true`,
accepted the task and unlocked a dependent. VERIFIED: all three terminal tests
reach the gate callback at the pre-fix commit. Fixed: failure records bounded
retry/escalation; interrupted/cancelled remain unresolved through completion and
resume, preserving their identity. Quota wake/handoff integration is still open.

BLOCKER — `PlanGateRunner.verify` ignored the tested directory and only checked
commit syntax. `run` allowed a production caller to substitute arbitrary hex for
HEAD, and never checked HEAD/dirty state afterward. VERIFIED: wrong-directory
acceptance and missing-commit crash reproduced. Fixed: explicit directory,
durable run/worktree lookup, clean production snapshot, unchanged HEAD, and
commit overrides only with an internal test runner. Global gates use the final
accepted task's worktree and require ancestor proof for every accepted commit.

BLOCKER — gate `System.cmd` accumulated unbounded output and timeout terminated
only its BEAM task. REPO-INSPECTION: no process-group termination call existed.
Fixed with the existing PortRunner launcher, streaming cap, deadline and owned
TERM/KILL termination. VERIFIED: three real local Python command tests pass,
including a descendant ignoring TERM. No provider or network invocation.
Orphan zombies may remain visible to ps; the test requires no live group member.

BLOCKER — approval read and dispatch creation were separate without immutable
plan binding in the run. REPO-INSPECTION: lease options carried only task title
and a default workspace. Fixed: run extensions bind plan/task/revision/attempt;
run prompts contain the complete task and goal contracts. Dispatch creation,
missing-job repair and initial effect claiming revalidate authority inside
SQLite immediate write transactions. Supersession refuses an unstarted effect;
work already started remains intact. VERIFIED: supersession test preserves
requested rows while refusing effect claiming. Concurrent approval interleaving
outside sandbox transactions has not been separately exercised.

NIT — imported narrative still treated planning/approval as absent and called
injected gate evidence actual integration. Updated current docs and milestone;
retained the historical PR report with a successor notice.

## Behavioral proof

VERIFIED: an archive of exact pre-fix PR commit `ec7b644` plus only the new
`plan_executor_safety_test.exs` and `plan_gate_safety_test.exs` ran:

```
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_executor_safety_test.exs test/shoestring/cobbler/plan_gate_safety_test.exs < /dev/null
```

5 tests, 5 failures, seed 2689, exit 2. Three failures reach gates for unsuccessful
terminals, wrong-directory evidence is accepted, missing commit crashes the
existing Regex call. These are behavioral failures, not missing APIs/modules.
The integrated baseline also produced the same 5 failures, seed 416556.

VERIFIED: intermediate corrected focused run: 39 tests, 0 failures, seed 712125.
An implementation mistake initially treated `Plans.authority` as a tagged tuple
rather than its map/nil API; 15 of 39 tests failed before that correction. A
subsequent old test expected gate transport errors to remain unresolved; it was
updated for the intentional bounded failure policy, without skipping/retrying.

VERIFIED: `gate_process_test.exs`: 3 tests, 0 failures, seed 987831.
These are new functionality tests, not regression locks on an existing API.

VERIFIED: `plan_executor_integration_test.exs`: 1 test, 0 failures, seed 350573.
A child VM uses a disposable database with the ordinary connection pool,
production DispatchWorker/ElfEffect, Fake harness and trivial local process,
real per-task Git worktrees and named `mix_format_check` gates. It restarts the
application after alpha acceptance, verifies identical durable status/worktree,
executes beta, checks global acceptance and two total runs, and checks the
fixture source HEAD/clean state. No manual run terminal or lifecycle row mutation.
The first authored integration test failed on an incorrect State API name;
correcting `State.dir` to the observed `State.root` API fixed that test.
This is a new integration proof, not a pre-existing behavioral regression.

## Limits and remaining work

UNVERIFIED: no live provider run, different-vendor external model review,
plan-level quota wake/handoff continuation, saved-agent/model execution binding,
CLI execution entrypoint, amendment/replan or approval-gated retirement proof.
The integration fixture performs no source changes, so it does not establish
multi-task code-change integration or acceptance of materially changed artifacts.
Duration accounting still records gate duration rather than full elapsed run time.
Package D and iteration 6 remain open. E remains pending. No claims from the
historical PR report are promoted by its imported green gate.

VERIFIED: the expanded safety files also fail against exact PR commit `ec7b644`:
9 tests, 9 failures, seed 532000, exit 2. Additional failures show invalid gate
parameters reaching the runner, missing worktree evidence being accepted, absent
immutable run binding, and quota-refused work being accepted. All are behavioral.

VERIFIED: final focused command includes those two safety files, existing executor,
gate runner and authority hardening files, real GateProcess checks and the
child-node integration proof: 47 tests, 0 failures, seed 85100, exit 0.
Quota-refused runs preserve task/run/attempt awaiting their existing wake lifecycle;
this preservation does not establish plan-level wake completion. Gate parameter
filtering asserts both refusal of unsafe parameters and retention of valid paths.
The integration proof also supplies a forged production `commit:` and verifies
that evidence still records actual HEAD.

## Full integration gate

UNVERIFIED: the first full run was interrupted by the server restart; its terminal
result was not recovered. A prior invocation exited 1 at formatter validation;
formatting in MIX_ENV=test corrected the environment-dependent call layout.
VERIFIED: a fresh run saved output to a local log and exited 0:

```
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null > /private/tmp/shoestring-iter6-executor-final-gate.log 2>&1
```

ExUnit seed 778652: 4 doctests, 1788 tests, 0 failures, 1 skipped (6 excluded).
179.4 seconds: 9.9 async, 169.4 sync. Node: 52 tests/52 pass/0 fail, then
8 tests/8 pass/0 fail. No live provider tests were enabled.
The full run preceded only evidence/milestone and module-doc clarification;
no executable behavior or tests changed afterward. Formatter and compile checks
were repeated for those final explanatory text changes.

The first formatter-only correction still differed between dev/test due to
nested assertions; separating the append result from its assertion made both
environment checks agree. No test assertion was weakened.
