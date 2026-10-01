# Iteration 6 manual plan foundation evidence

VERIFIED: Implementation code/test/migration tree committed as
`e12d77fb66145def8aeeca43d1b897ebd93fe9a6`, based on
`13ac5f056d51cbf43554adb740e6971a8d35d3aa` (merged recovery PR #87).
The subsequent evidence commit changes only this record. The draft PR head is
the final delivery SHA. Commit messages were inspected for forbidden attribution.

## Measured gates

VERIFIED: Commands ran in the named implementation worktree with closed stdin,
foreground subprocesses, and a 600-second timeout for each full gate. Logs were
retained locally under ignored `tmp/`; no raw machine-specific log was committed.
The first dependency-free attempt at `mix precommit` exited 1 before tests because
formatter import dependencies were unavailable. Read-only dependency/build copies
were retained as authorized; no dependency or lockfile changed.

| Run | Exact command | Measured result |
| --- | --- | --- |
| Baseline, launched from the clean requested base | `mix precommit` | Exit 0; 4 doctests, 1528 tests, 0 failures, 1 skipped (6 excluded); ExUnit seed 296659 |
| Final implementation | `mix precommit` | Exit 0; 4 doctests, 1561 tests, 0 failures, 1 skipped (6 excluded); ExUnit seed 585124 |
| Baseline Node capacity suite | `mix gate_0a.node_test` (through precommit) | 52 tests, 52 pass, 0 fail, 0 skipped |
| Baseline Node UI suite | `mix ui.node_test` (through precommit) | 7 tests, 7 pass, 0 fail, 0 skipped |
| Final Node capacity suite | `mix gate_0a.node_test` (through precommit) | 52 tests, 52 pass, 0 fail, 0 skipped |
| Final Node UI suite | `mix ui.node_test` (through precommit) | 7 tests, 7 pass, 0 fail, 0 skipped |

VERIFIED: Final formatting and warnings-as-errors compilation passed through
`mix precommit`; `git diff --check` passed. The final gate measured the delivered
Elixir, migration, and test contents. Documentation received prose/evidence updates
afterward. The predecessor's reported count was not used as a substitute for the
measured baseline.

## New feature tests

VERIFIED: The final full gate includes 33 new feature tests (source test count:
10 contract, 12 service, 5 concurrency, 6 canonical-event tests). These APIs do
not exist at the base; no pre-fix behavioral regression proof is claimed.

| Test file | Behaviors asserted |
| --- | --- |
| `test/shoestring/cobbler/plan_contract_test.exs` | Required goal/task fields; unknown/malformed/oversized/deep terms; UUID/dependency checks; missing/self/duplicate/cyclic edges; deterministic order; named gates; bounded attempts and aggregate budgets; fixed digest and JSON round trip |
| `test/shoestring/cobbler/plans_test.exs` | Inert proposal; exact digest/revision approval; human attribution; immutable edits; supersession; rejection reason limits; repeat/conflict behavior; ownership and foreign revisions; failed-write rollback; revision/repository caps; approved identity retention; corrupt projection rebuild; terminal goal guard; unchanged existing running/completed work |
| `test/shoestring/cobbler/plan_concurrency_test.exs` | Real independent SQLite connections: eight same approval requests yield one event; approval/rejection conflict yields one decision; eight optimistic edits yield one new revision without losing authority; eight creation repeats yield one event; external writer returns bounded storage_busy without partial write |
| `test/shoestring/trajectory/plan_event_test.exs` | Strict registry writes/replay; credential marker rejection with ordinary fields retained; ownership/order/digest validation; rebuild from all replaced derived fields; low-level canonical write rejection of cycles/aggregate budgets; unknown versions/types and duplicate causal identities fail closed |

VERIFIED: Final targeted command before the last two feature additions:

```sh
mix test test/shoestring/cobbler/plan_contract_test.exs test/shoestring/cobbler/plans_test.exs test/shoestring/cobbler/plan_concurrency_test.exs test/shoestring/trajectory/plan_event_test.exs
```

VERIFIED: That run had 31 tests, 0 failures, seed 570334. The two later tests for
unchanged running/completed work and future/duplicate causal identities passed in
the final full gate. No provider CLI, live inference, or provider network/quota
call was used. New scratch SQLite databases remain locally under ignored `tmp/`;
new test processes are supervised and connections are stopped by supervision.

VERIFIED: During development, two concurrency cases were intermittent, failing
1 of 2 runs each at SQLite `BEGIN IMMEDIATE`. Local writer serialization corrected
connection contention while preserving the eight-caller assertions. An additional
count failure came from retained scratch databases whose process-local integer
names collided across VM launches; fresh UUID directory names corrected isolation.
The earlier schema/error-wrapper and fixture module failures were implementation
errors corrected before the final gate. No new skip, sleep, assertion widening, or
automatic database-request retry was introduced to make a test pass. The explicit
external-lock feature test intentionally emits a SQLite lock diagnostic and asserts
`:storage_busy`, rollback, and a subsequent explicit same-request submission.

## Contract audit and limitations

VERIFIED: Canonical plan events establish approval authority; the projection can
be corrupted and completely replaced without changing revisions, digests, human
decisions, or selected authority. Superseding an approval retains the old content
and decision. Repeating that old approval request does not restore old authority.
Approved task IDs cannot disappear; existing completed task rows and a running
run remain unchanged under supersession and plan rebuild.

REPO-INSPECTION: The authorized scope consists of the Cobbler facade/new plan
modules, the trajectory event registry, one generated migration, the four new test
files and two narrow support modules, `docs/plan-contract.md`, this record, the
iteration-6 README, and one exact `.gitignore` allowlist entry. No LiveView/assets,
Elves/harness code, recovery tests, prior evidence ledger, dependencies, or supplied
ignored milestone was edited. No cleanup was performed. Git push and draft PR
creation are the expressly authorized delivery network operations.

REPO-INSPECTION: The supplied proposed milestone is broader than this brief.
Concrete choices made here are manual-only provenance, fixed v1 wire shapes and
numeric caps, SHA-1-shaped repository bases, initial budget/repository ceilings,
goal-scoped stable DAG IDs, and conservative retention of all ever-approved task
IDs. These choices and their limitations are detailed in `docs/plan-contract.md`.
They do not assert completion of all work packages in iteration 6.

SCHEMA-ONLY: Acceptance criteria, gate names, checkpoint conditions, logical
evidence references, execution bounds, and planning-attempt budgets are validated
contracts here. Actual gate execution, checkpoint evidence, consumed provider
allowance, and completed-task acceptance accounting require the later runtime.
Future dispatch must claim against exact current approved authority transactionally,
check goal status/dependencies/evidence/admission/leases, and prevent claims from
unapproved or superseded revisions without cancelling useful active work.

SCHEMA-ONLY: Future amendment/executor work must preserve accepted task identity,
completion evidence, lineage, attempts and consumed allowance across revisions and
restarts. Historical snapshots and conservative ID retention here are not a runtime
amendment policy or completion ledger. Legacy iteration-5 dispatch is unchanged
and is not newly plan-gated by this inert slice.

UNVERIFIED: No live planner/provider, approval UI, sequential executor, amendment
orchestration, or iteration-7 integration was verified. Independent different-vendor
review remains the next human-directed step; this PR must stay draft and unmerged.
