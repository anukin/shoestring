# Iteration 12 evidence — one installed work CLI

Date: 2026-10-24 (UTC). Branch `claude/iter12-installed-cli`, base `6049d90`.
Merged directly to main at the user's direction (no PR).

## What changed (REPO-INSPECTION)

- `Shoestring.CLI.Main` runs the work commands (`do`, `follow`, `result`,
  `review`, `checks`, `goals`, `plans`, `execution`, `agents`, `models`,
  `reservations`). Argument parsing and printing moved out of the Mix tasks
  into `Shoestring.CLI.Commands.*`; no `Mix` call remains on the release path.
  The Mix tasks are thin callers that raise `Mix.Error` on a refusal.
- Installed entry point: `shoestringctl` sends every command it does not
  manage itself to `bin/shoestring eval 'Shoestring.CLI.Main.main(System.argv())'`
  with stdin left open. The checkout's `bin/shoestring` runs `mix shoestring`
  with `SHOESTRING_CALLER_DIR`; both reach the same `run/2`.
- Output contract: data on stdout (`Shoestring.CLI.Shell.info`), messages,
  progress and runtime logs on stderr; `--json` on every command that prints
  data; refusals one line; exit 0 / 1 refused / 2 invalid arguments / 3 `do`
  or `follow` ended without completing. Documented in `docs/cli-output.md`.
- State: the installed command opens the database only at exactly its schema
  (`Repository.with_current_repo/1`) and never creates or migrates it.
  `follow` for an unfinished goal now checks the service, like `do`.
- `doctor` reports `agents` readiness from installation plus the explicit
  `--probe-providers` metadata probe; passive doctor still runs no provider.

## Package A — transport decision

Kept the recommended path: a short-lived release VM against the shared SQLite
database, as the Mix tasks already did. No listener, RPC or distribution.

VERIFIED (local release build of this branch, scratch state directory,
service running from the same build):
- 40 of 40 `goals create` commands run concurrently against the running
  service exited 0 with nothing on stderr; `goals list` then held all of them.
- Missing database, pending migration (newest `schema_migrations` row removed
  from a copy) and newer database (a future version added to a copy) were each
  refused in one stderr line with exit 1; the old copy was left unmigrated.
- A service on a different state directory: `follow` refused with the
  "different state directory" line.

## Defect found and fixed

VERIFIED live, then locked by `test/shoestring/cli/repository_runtime_test.exs`:
in a runtime without the application (the installed command, and equally the
checkout's Mix tasks), confirming capacity in `follow` crashed with
`unknown registry: Shoestring.Trajectory.WriterRegistry`, and `execution
cancel` crashed with `no process` for `Shoestring.Cobbler.ReservationWriter`.
`review accept|reject|retry` and reservation commands use the same paths.
Tests never saw it because the suite runs with the application started.
`Repository` now starts the trajectory writers, PubSub and a local
ReservationWriter when they are absent. Correctness does not rely on these
being the service's: appends read the next sequence inside an immediate
transaction and retry conflicts; the ReservationWriter is local FIFO delivery.

## Live verification

VERIFIED, with the user's standing authorization for subscription use, from
the locally built release (`shoestringctl`, not the checkout):
- `do` in a scratch Python repository, answered through stdin: planning
  confirmed, plan approved, capacity confirmed, Claude Sonnet worker ran,
  `python_unittest` passed, goal completed. stdout carried only the result;
  stderr the plan, questions and progress. `result --json` and `follow --json`
  returned the same commit; the printed `git fetch`/`git merge` took it into
  the scratch repository and its tests passed.
- `checks GOAL --output 1`: description on stderr, recorded bytes alone on
  stdout.
- `execution cancel` (after the fix) was applied by the service.
- `doctor --probe-providers --json`: Claude 2.1.310 and Codex 0.163.0 both
  `ready` (reported signed in, tested versions).
- `tools/release/smoke.py` (guarded PATH, no provider): passed, including the
  new work-command checks.

Quota used: 2 Claude planner calls and 5 Claude worker runs (Sonnet). Four of
the worker runs were wasted on my scratch repository: without
`test/__init__.py`, Python 3.12 resolved `test.test_calc` against the standard
library's `test` package, so every attempt's check failed at import.

## Pre-existing defect observed, not fixed

VERIFIED in the scratch state, not changed (executor code is outside this
milestone): after a task's last allowed attempt fails its checks, that
attempt's task claim (`cobbler_task_claims`) stays `active`; cancelling the
execution does not release it either. Every later goal's planning and
admission then refuses with "Candidate scope 'subscription' is currently
occupied by active execution". Claims of earlier attempts were released only
by the next attempt's sequential advance.

## Regression check

VERIFIED against `6049d90` (base worktree, the four files copied in): 11 of 21
tests fail for behavioural reasons — the runtime test with `unknown registry`,
the two launcher tests (the base launcher prints its usage for work commands
and rejects `doctor --json`), and eight work-loop/follow tests (the base writes
the conversation to stdout). The other ten guard invariants.
`main_test.exs`, the doctor readiness test and the result/checks/review JSON
assertions cannot run on the base (the API is new); they document behaviour,
they are not regression locks.

## Gate

`mix precommit`, seed 307302: 4 doctests, 2489 tests, 0 failures, 1 skipped
(6 excluded); Rust 4 + 5; Node 52/52 and 14/14.

## Not done

- UNVERIFIED: the fresh-VM Homebrew acceptance run with the new work-command
  checks (`tools/release/fresh_vm_acceptance.sh`). It needs Tart reinstalled
  and Local Network access granted by the user.
- Interactive session commands, remote hosts and opencode are out of scope.
