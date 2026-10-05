# Package B: initial planner boundary

VERIFIED: implementation base is `df624790538b9bde687262a2ef86d24ae140b4bd`
(merged package A, PR #89). Work uses the isolated
`codex/iter6-planner-boundary` branch. The user's source checkout was not edited.
The initial-planning contract and limitations are recorded in
[`docs/planner-boundary.md`](../../../docs/planner-boundary.md).

## Progress audit

VERIFIED (GitHub inspection, 2026-10-04): A merged in
[PR #89](https://github.com/anukin/shoestring/pull/89), and L1 merged in
[PR #87](https://github.com/anukin/shoestring/pull/87).
[PR #90](https://github.com/anukin/shoestring/pull/90) remains a draft at
`ec7b644b86221b2a68728da4a41dfc77382001c5`, with passing checks and no submitted
reviews or comments at inspection. Passing checks do not establish independent
review or production integration.

REPO-INSPECTION: B, C and E were absent on the inspected main revision. This
change supplies B. C, E and D's independent review, production wiring, worktree
binding and integration proof remain open. The ignored local milestone was
copied into this branch, made trackable, and updated to mark L1 complete; the
historical L1 evidence was left intact.

## Verification

VERIFIED: the final full gate ran in `$WORKTREE` with this exact command:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null > /private/tmp/shoestring-iter6-planner-precommit.log 2>&1
```

VERIFIED: exit status 0. Observed summaries:

```text
4 doctests, 1694 tests, 0 failures, 1 skipped (6 excluded)
Node gate: tests 52, pass 52, fail 0, cancelled 0, skipped 0, todo 0
Node UI: tests 7, pass 7, fail 0, cancelled 0, skipped 0, todo 0
```

VERIFIED: this gate includes formatting, compilation with warnings as errors,
the full ExUnit suite and both Node suites. No existing tests were disabled or
relaxed. The skip/exclusions above are reported as emitted by the full suite.

VERIFIED: a baseline full gate exited 0 before implementation; its output was
truncated, so I did not verify the exact baseline test count. Earlier focused
planner runs emitted 30 tests / 0 failures and then 33 tests / 0 failures. An
initial focused run emitted 24 tests / 2 failures: a fixture omitted the
required schema version, and a crash test stopped the caller while its
separately supervised inference task remained alive. The fixture was corrected;
the crash test now explicitly stops and restarts the owned supervisor and
checks that replay makes no replacement call. These were corrected development
failures, not a claim of intermittent green testing.

REPO-INSPECTION: new tests defend inert request replay, exact human adoption,
fixed goal/provenance, schema and DAG validation, unsafe output, one explicit
repair, fresh initial/repair admission, reserve refusals, both capacity windows,
provider/scope binding, global claim occupancy, charged budgets, lost-result
replay, event/cache tampering and refusal to reset initial planning through a
new key or manual revision. Projection tests check both sensitive-data refusal
and preservation of the required goal/evidence facts. Req Plug stubs exercise
the actual HTTP adapter, request schema/model/options, response byte/usage
bounds, transport failures, and disabled retry/redirect behavior.

REPO-INSPECTION: these are new-feature tests, not claimed regression locks
against the base commit: that commit has no planner boundary, and missing-module
failure would not be behavioral proof. Existing foundation tests run unchanged
in the full gate.

## Practical limits

SCHEMA-ONLY: the Ollama production API contract is based on its documented
structured generation interface. HTTP request/response handling is exercised
with hermetic stubs; no live model or provider CLI was invoked.

UNVERIFIED: live model quality, actual local-server configuration, live quota
measurement, and production UI integration. I did not verify these. The output
budget is a deterministic precharged allowance, not monetary-cost accounting.
Ambiguous in-flight calls retain their charge and claim until an explicit
operator decision; there is no timer, retry, replacement or cleanup policy.
Amendment budgets and completed-evidence preservation belong to package E.

REPO-INSPECTION: fixtures use synthetic values and do not persist provider
identifiers, credentials, absolute home paths or hidden model reasoning. Req
was absent from the inspected dependency list despite the repository guideline;
the prescribed HTTP library was added with five new lock entries and no existing
dependency-version changes.

## CI follow-up before merge

VERIFIED: PR #91's original completed pull-request run
[37359666256](https://github.com/anukin/shoestring/actions/runs/37359666256)
reported `4 doctests, 1694 tests, 1 failure, 1 skipped (6 excluded)`. The
failure was a sandbox connection checkout refusal in the handoff replay test,
while its polling query competed with the trajectory writer. The original push
run was cancelled during tests; it did not emit a completed test summary.

REPO-INSPECTION: all five handoff completion waits now use the existing
`elf_terminal` notification, sent after terminal projection, instead of querying
the shared sandbox while writes are active. Their durable-state assertions and
10-second timeout remain intact. This is test synchronization work, not a new
production regression lock; I did not reproduce the checkout refusal locally.

VERIFIED: the focused command
`perl -e 'alarm 300; exec @ARGV' mix test test/shoestring/cobbler/handoff_worker_test.exs < /dev/null`
reported `10 tests, 0 failures`.

VERIFIED: after that synchronization change, the full command
`perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null > /private/tmp/shoestring-iter6-handoff-precommit.log 2>&1`
exited 0 with `4 doctests, 1694 tests, 0 failures, 1 skipped (6 excluded)`,
Node gate `52 tests, 52 pass, 0 fail`, and Node UI `7 tests, 7 pass, 0 fail`.

UNVERIFIED: the original CI checkout failure's exact load-dependent trigger.
I did not reproduce it locally and do not claim the local result establishes
CI success. No unchanged CI run was retried to obtain a green outcome.
