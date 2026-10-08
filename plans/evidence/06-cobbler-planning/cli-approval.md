# Package C: CLI plan review and approval

REPO-INSPECTION: work was isolated on `codex/iter6-cli-approval`, based on
main `16a6adf`. The source checkout was not edited. Scope is the new
`mix shoestring.plans` task, its tests and documentation, milestone/evidence
updates, and a shared repository-only startup helper extracted from the existing
agent lookup task. No package D executor code or web UI was changed.

VERIFIED (session instruction): the user previously authorized integration into
main without a PR. That explicit direction overrides the standing own-PR / never
merge rule for this continuation. No provider run or external model review was
authorized or performed.

## Implemented acceptance

REPO-INSPECTION:

| Package C requirement | Entry point and boundary |
| --- | --- |
| Inspect goal contract and dependency order | `show GOAL [--revision N]`: full plan, ordered tasks, revision/digest, decision and planner summary |
| Edit outcomes, edges, criteria, checkpoints, non-goals | `export` emits the plan alone; `edit --file` validates it and records a new proposed child revision |
| See validation errors | malformed/oversized JSON and domain refusals raise Mix errors; invalid proposals do not persist |
| See planner quota/support tier | `planner` exposes stored attempt counts, full allowance charges, remaining planning budget, tier, safe errors and ready candidate |
| Approve exact immutable revision | `approve` requires revision, digest, request ID and human identity; delegates the atomic decision to `Plans` |
| Reject with reason | `reject` has the same explicit binding and requires a bounded reason |
| Preserve historical revisions | export/review of an older revision remains available; an edit is inert until separately approved |
| Review/adopt initial planner output | `adopt` checks the candidate digest/request key through the existing human-only planner API and leaves the revision proposed |

REPO-INSPECTION: commands share repository-only startup and SQLite migrations with
pool size one. They do not call `app.start`, observe providers, run inference,
create a lease, cancel work or dispatch. The helper preserves the prior agent
lookup behavior. CLI writes append canonical events without attempting cross-process
PubSub publication. Conflicting or duplicate flags are refused, rather than
silently selecting one of multiple revision/digest values.

REPO-INSPECTION: the CLI recomputes a stored revision's content digest before
review, export, edit or decision; domain mutations recheck the supplied bindings
inside their own transaction. Ready planner candidates additionally require
consistent event replay. No domain authority API was changed in this package.

## Focused verification

VERIFIED: the first focused command was:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/mix/tasks/shoestring_plans_test.exs test/mix/tasks/shoestring_agents_test.exs < /dev/null
```

VERIFIED: **11 tests, 1 failure**, seed **580962**, exit **2**. The new duplicate
flag check failed because `OptionParser` replaced earlier occurrences before
validation. Its installed documentation explicitly supports `:keep`; applying
that modifier retains occurrences so the CLI can reject ambiguous requests.
This was an implementation defect in new functionality, not an intermittent
failure. No assertion was widened, skipped, retried or delayed.

VERIFIED: after that correction and additional fixture candidate/digest tests,
the same exact focused command returned **14 tests, 0 failures**, seed **85445**,
exit **0**. This includes both pre-existing agent CLI tests and twelve new plan
CLI tests. Coverage includes edits of all required user fields, old approved
content/digest preservation, proposal and decision replay, stale digest refusals
on both decision paths, human identity validation, cyclic/unsafe/missing-criterion
refusal, file limits and decode failures, ready candidate adoption, failed-output
display, preserved planning charges, and corrupt-content refusal.

UNVERIFIED: these twelve tests exercise a new CLI entrypoint absent at base
`16a6adf`; they are functionality/contract checks, not regression locks verified
against that pre-fix commit. No claim of behavioral pre-fix failure is made.
The underlying storage/approval regression tests remain unchanged.

## Separate-process persistence proof

VERIFIED: a bounded local probe launched the real Mix commands against a fresh
synthetic test state root. It performed fresh migrations, manual import, show,
export, edit, identical edit replay, approval of revision two, rejection of
revision one, another export of preserved revision one, latest review and planner
summary. A final repository-only process checked event rebuild consistency,
zero persisted jobs/runs, and absence of application/endpoint/Oban/Elf/capacity
supervisor registrations.

```sh
perl -e 'alarm 180; exec @ARGV' python3 "$PROBE" < /dev/null
```

VERIFIED: exit **0**, **12 separate CLI/probe processes**. The first probe's
success message hardcoded an incorrect count of 15. Its counter was corrected
and the probe repeated with a new synthetic state root; the actual counted
output was 12. The persistence and no-work assertions passed on both runs.
The probe used local synthetic fixtures and no provider/network calls. Temporary
state and fixture files were left in place; no cleanup behavior was added.

## Full gate

VERIFIED: exact command:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

VERIFIED: exit **0**, **4 doctests, 1736 tests, 0 failures, 1 skipped
(6 excluded)**, seed **89699**, ExUnit duration **175.6 seconds**. Node capacity
gate: **52 tests, 52 passed, 0 failed**. Node UI gate: **8 tests, 8 passed,
0 failed**. Formatting and compilation checks passed. Existing test-source
warnings, migration redefinition warnings and fault-injection/SQLite contention
logs were present; no warning-free claim is made. This turn ran the full gate
once. `git diff --check` passed before integration.

## Remaining limits

UNVERIFIED: package D's independent review, production executor wiring,
worktree binding, task/global gate evidence and end-to-end approved-plan restart
are not closed by this interface. PR #90 was VERIFIED open/draft with successful
CI and no submitted reviews at the start of this turn (2026-10-07).

UNVERIFIED: package E's bounded amendment request, accepted evidence preservation,
explicit task retirement and reapproval before continuing remain pending.
Approved-run binding to immutable agent profile snapshots remains pending.
Initial planner generation/repair and goal creation do not gain CLI commands in
this review slice. Local `human:` attribution is not authentication. Stored
planner budget display is not proof of live subscription allowance or entitlement.
