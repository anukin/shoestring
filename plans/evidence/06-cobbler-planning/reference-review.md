# Reference plans for human review

VERIFIED: offline `MIX_ENV=test mix shoestring.plans.eval context CASE` and
`MIX_ENV=test mix shoestring.plans.eval reference CASE` exited 0 for each case
at baseline `a53aa1b40ce12e3dac20499f1cc35635ba5efd64`. All three references
validated, and no cited test/hint path was absent from the exported snapshot.
The exporter reported `pending_human_review` and `not_run` for every case.
No model or application was started by these commands.

UNVERIFIED: human approval is pending. The observations below are repository
inspection to support review, not a substitute for a human-authored/approved
baseline or a semantic score.

## Common contract

REPO-INSPECTION: the dependency-free Pantry repository is in
`priv/planner_eval/repository/`. Each goal permits changes only to
`lib/pantry.ex`, preserves public signatures, excludes unrelated functions,
and forbids packages/network access. Each task permits at most two attempts
and 600 seconds. Goal budgets add 60 seconds to the sum of task time limits.
Checkpoints require a commit, changed paths and the named passing gate.
The synthetic `1111111` base must be rebound to a real owned Git repository
before approved execution, recording the resulting changed plan digest.

## Greeting

REPO-INSPECTION: one task, `greeting`, has no dependencies. It trims names,
substitutes `friend` when blank, and preserves punctuation/nonblank names.
The named gate is `test/greeting_test.exs`; examples are padded `Sam`, blank
whitespace and unchanged `Jo`. Goal allowance: two attempts, 660 seconds.

Review artifacts:
[goal](../../../priv/planner_eval/cases/greeting/goal.json),
[reference](../../../priv/planner_eval/cases/greeting/reference.json),
[test](../../../priv/planner_eval/repository/test/greeting_test.exs).

VERIFIED: context digest:
`d6292a7ee3474d0d9ff243e4830ee95f6f7457cd7f831ef6be2b8e2019e70073`.
Normalized reference plan digest:
`3de64608f92246d6f0044d6ee6b89bb1d7ae4bc505ecddd5aac07be38fcacc5c`.
Raw reference SHA-256:
`e79f65dc40eca352a29413aaa8eec7d66007d516e5b61669a06a48143a7d09c1`.

## Receipt

REPO-INSPECTION: `total` computes integer `price_cents * quantity` sums;
`receipt` depends on `total` and calls that function to render `Total: N cents`.
The first gate runs `test/total_test.exs`; the second and global gates run total
and receipt tests. Empty basket gives zero; the example basket gives 475.
Both tasks modify the same source file, so this checks ordered composition,
not independent-file decomposition. Goal allowance: four attempts, 1260 seconds.

Review artifacts:
[goal](../../../priv/planner_eval/cases/receipt/goal.json),
[reference](../../../priv/planner_eval/cases/receipt/reference.json),
[total test](../../../priv/planner_eval/repository/test/total_test.exs),
[receipt test](../../../priv/planner_eval/repository/test/receipt_test.exs).

VERIFIED: context digest:
`bdeb2bf5b755b9ce3f3204abc72dad64ed3657116f784d122c691042aa9a7e9f`.
Normalized reference plan digest:
`d61052bd6261ede2a9206932cef493b545307655130ada3f31ab8714a2682343`.
Raw reference SHA-256:
`f30ba09d00e3256528f9cf62d400d75854bfceadf3a1f14c28a8334805a148e7`.

## Catalog

REPO-INSPECTION: one task, `catalog`, trims names, removes blanks, deduplicates
and sorts case-sensitively. Its named gate is `test/catalog_test.exs`; the
example expects `Apple`, `apple`, `pear`, retaining distinct capitalization,
and checks empty input. Goal allowance: two attempts, 660 seconds.

Review artifacts:
[goal](../../../priv/planner_eval/cases/catalog/goal.json),
[reference](../../../priv/planner_eval/cases/catalog/reference.json),
[test](../../../priv/planner_eval/repository/test/catalog_test.exs).

VERIFIED: context digest:
`2bd3515a3cc7bb63211b6e93429082c7671decd57a4cda66639ee4a4db8a5068`.
Normalized reference plan digest:
`70b6e8ae0b35b49c36c63b819890a349631dd61e9cd0e580a67fccc857bdf910`.
Raw reference SHA-256:
`2bf19fa393688d981921fce3852e3d8c4d40af710ee58d1c7e323122412e69bc`.

## Review decision and limitations

UNVERIFIED: reviewer, decision, date and approved digests are not yet recorded.
A human can accept these three pinned references or name required changes;
revised artifacts require new digests and another fixture smoke run. Acceptance
as evaluation references does not approve a production execution revision.

REPO-INSPECTION: this is a small smoke corpus. Two goals have one task and the
third has two tasks in one source file. It cannot establish quality on larger
repositories, complex graphs, non-Elixir projects or real quota handoffs.
Named tests sample specified behavior; passing them alone does not establish
the change-only constraint, correct reuse of `total_cents/1`, or all semantic
requirements. Review material diffs as well as gates. Fewer tasks than the
reference is not automatically worse, and more tasks is not automatically better.

UNVERIFIED: no provider/model budget is authorized by this document. The proposed
planning run is three calls total, at most 4096 output tokens each, one per case,
with no automatic repair. The provider/model must be named and the budget
explicitly authorized before any call. Sequential model execution requires
its own explicit budget; the planning allowance does not authorize it.
