# Iteration 6 acceptance audit

REPO-INSPECTION: audit baseline is `a53aa1b40ce12e3dac20499f1cc35635ba5efd64`.
The user's instruction to work on main without a PR overrides the standing
isolation/PR workflow. Local `.github/hooks/` and `.pi/` are outside this change.
This audit consolidates existing checks; it adds no tests or implementation.
It does not claim new pre-fix regression verification.

## Required deterministic evaluations

REPO-INSPECTION: the table maps every evaluation in the milestone to executable
assertions. Test names identify the relevant behavior rather than relying on
file names alone. These are fixture/domain checks, not model-quality scores.

| Required eval | Existing checks | What the assertions establish |
| --- | --- | --- |
| Valid DAG | `planner_test.exs`: `valid inference charges before a single call and stays unapproved`; `human adoption binds the exact digest and never self-approves`; `plans_test.exs` | Valid output is reviewable, adoption creates a proposal, and exact human approval is separate |
| Cycle | `planner_test.exs`: `refuses cycle without revision or dispatch`; `plan_graph_test.exs`: two-node and longer cycles | A cyclic candidate has errors, no revision, and no run |
| Missing criterion | `planner_test.exs`: `refuses missing criterion without revision or dispatch`; CLI invalid-graph/missing-criterion test | Missing acceptance prevents persistence/dispatch |
| Unsafe instruction | `planner_test.exs`: embedded command, changed non-goals, invented authority/provenance refusals; `five-hour and weekly reserve breaches cannot be confirmed away` | Structural command/authority injection is rejected; deterministic admission preserves reserves. This does not measure natural-language instruction following |
| Invalid JSON/schema | `planner_test.exs`: `invalid JSON permits only one explicit repair with validation feedback`; `a failed repair remains available for manual editing without another inference` | Explicit bounded repair, retained charges, no fresh allowance under a new request key |
| Restart | `plan_executor_test.exs`: `restart resumes after task one without re-executing it`; isolated integration CLI/quota/restart case | Accepted work persists and the composed fixture continues without another planning call |
| Plan edit | `shoestring_plans_test.exs`: `edits preserve approved content, require another approval and replay safely`; isolated integration dependency edit | New immutable revision and another exact approval; old content remains |
| Replan | `planner_amendment_test.exs`: `initial generation and amendment share charges and preserve accepted execution across approval`; `plan_amendment_test.exs`: approval/evidence/counters case | Accepted event is unchanged; attempts and planner charges persist; new execution is blocked until approval |
| Quota blocked planner | `planner_test.exs`: missing observation, five-hour/weekly reserves, repair capacity re-evaluation | Refusal spends no inference attempt; confirmation cannot bypass reserve policy. Manual-plan fallback is separately covered after failed repair |
| Premature completion | `plan_executor_test.exs`: `a successful run without passing gates cannot unlock dependents`; `a failing global gate blocks goal completion` | Provider success alone does not accept a task or complete a goal; only the failed task retries |

REPO-INSPECTION: Cobbler test paths above are under
`test/shoestring/cobbler/`; the CLI file is under `test/mix/tasks/`.
Additional authority/replay/checkpoint tests in the same run check stale and
superseded approvals, canonical reconstruction, and refusal to replace active
Elves or unresolved continuation intents.

## Acceptance gate mapping

| Milestone condition | Evidence to inspect |
| --- | --- |
| Invalid, cyclic, unapproved or superseded plans cannot dispatch | Invalid planner cases, executor authority tests, `plan_executor_safety_test.exs`, and `plan_authority_hardening_test.exs` |
| Bounded planner calls and admission | Initial/repair/refusal cases and `planner_amendment_test.exs` shared lifetime allowance |
| Durable revisions and edits | CLI edit/decision tests and `plan_replay_test.exs` canonical reconstruction |
| Dependencies and task/global gates | Executor sequential/gate cases and isolated real-worker integration |
| Restart without rediscovery | Executor restart case and composed CLI/planner/quota/restart integration |
| Planner has no lifecycle/reserve/worktree/approval authority | Inert request/generation/adoption assertions, malformed authority/command refusals, deterministic admission checks |
| Replan preserves evidence and requires approval | Amendment and checkpoint-amendment tests; isolated approved amendment integration |

REPO-INSPECTION: these mappings describe deterministic enforcement. They do not
assert a sandbox proof against arbitrary executable extensions or a live
provider's quality, reliability or quota reporting.

## Composed demo and remaining limits

REPO-INSPECTION: the isolated integration test follows initial CLI planner
request/generation, dependency edit, explicit exact approval, real allocated
Git worktree changes, real task/global gates, quota continuation and application
restart. Its second goal rejects a cyclic candidate with no revision or run.
The same file also exercises an approved amendment through real workers and
restart. See [planner-demo.md](planner-demo.md) and
[executor-integration.md](executor-integration.md).

REPO-INSPECTION: fixture goal creation and capacity/profile setup use domain/test
helpers; this is not evidence of a CLI command that creates a brand-new goal.
Provider output is scripted, not model-generated. The user-directed configuration
web UI is a separate milestone; a web approval screen is not missing package C
work.

## Current-run verification

VERIFIED: focused matrix command exited 0:

```sh
MIX_ENV=test mix test test/shoestring/cobbler/plan_contract_test.exs test/shoestring/cobbler/plan_graph_test.exs test/shoestring/cobbler/plans_test.exs test/shoestring/cobbler/planner_test.exs test/shoestring/cobbler/plan_replay_test.exs test/shoestring/cobbler/plan_executor_test.exs test/shoestring/cobbler/plan_executor_safety_test.exs test/shoestring/cobbler/plan_authority_hardening_test.exs test/shoestring/cobbler/plan_amendment_test.exs test/shoestring/cobbler/planner_amendment_test.exs test/shoestring/cobbler/plan_checkpoint_amendment_test.exs test/shoestring/cobbler/plan_executor_integration_test.exs test/mix/tasks/shoestring_plans_test.exs --trace
```

VERIFIED: **214 tests, 0 failures**, seed **511729**, **13.3 seconds**
(0.6 async, 12.6 sync). The parent integration wrapper passed its assertion
that the isolated child returned 0 with `2 tests, 0 failures`; those child tests
are not added to the parent count. The trace records the individual matrix
checks. The existing `:live` exclusion remained in force. No tests were changed,
skipped or retried by this audit. Commands had closed stdin and a 240-second
foreground bound. Exact output is retained locally in `deterministic-matrix.log`.

VERIFIED: full repository gate `mix precommit` exited **0**: **4 doctests,
1900 tests, 0 failures, 1 skipped (6 excluded)**, seed **698990**,
**166.6 seconds** (8.8 async, 157.8 sync). JavaScript suites passed **52/52**
and **8/8**, with zero failures. The existing `:live` exclusion and skipped
test were not changed. The foreground gate had closed stdin and a 480-second
bound; its full output is retained locally in `precommit.log`.

VERIFIED: all **18** relative Markdown links in the four audit/review/milestone/
evaluation documents resolved. `git diff --check` passed. Changes are
documentation only; no runtime or fixture edits followed the gate.

## Still required to close the iteration

1. VERIFIED (subsequent user direction): reference task scopes were accepted
   with a Python/Go language change. The translated Python artifacts and fresh
   digests are in [reference-review.md](reference-review.md); converted bytes
   were not separately human-reviewed. See [python-evaluation.md](python-evaluation.md)
   for the current corpus/gate checks; the matrix run above predates conversion.
2. Explicit provider/model/run-budget authorization, followed by actual proposals
   and scored comparisons, preserving every failure and repair.
3. Approved sequential execution evidence for model proposals, with actual Git
   base binding, material changes, task/global gates and human edits disclosed.
4. Final completion record with semantic results and remaining risks. Do not
   mark the iteration complete or unlock iteration 7 on fixture results alone.

UNVERIFIED: no live model generation, scored semantic comparison or execution of
model proposals has been verified by this audit. Later reference-scope approval
does not turn earlier fixture evidence into model-quality evidence.
