# Reviewed reference scopes and Python artifacts

VERIFIED: offline `MIX_ENV=test mix shoestring.plans.eval context CASE` and
`MIX_ENV=test mix shoestring.plans.eval reference CASE` exited 0 for each case
after conversion from baseline `95728a70f97e7a51d9726074d9991296c0917c64`. All three references
validated, and no cited test/hint path was absent from the exported snapshot.
The exporter reported `user_approved_with_language_change` and `not_run` for every case.
No model or application was started by these commands.

VERIFIED (user direction): after reviewing the three task scopes in conversation,
the user said, "these are good. But use a different language from elixir like
golang or maybe python so its different". The scopes, task order, examples and
budgets are retained; Python was selected and the fixtures/gates translated.
The digests below bind the resulting Python artifacts. UNVERIFIED: the converted
bytes were not separately human-reviewed, and this is not production execution
approval or a semantic model score. The earlier Elixir artifact digests remain
in Git history; they must not be compared with these Python contexts.

## Common contract

REPO-INSPECTION: the dependency-free Python Pantry repository is in
`priv/planner_eval/repository/`. Each goal permits changes only to
`pantry.py`, preserves public signatures, excludes unrelated functions,
and forbids packages/network access. Each task permits at most two attempts
and 600 seconds. Goal budgets add 60 seconds to the sum of task time limits.
Checkpoints require a commit, changed paths and the named passing gate.
The named gate is `python_unittest`, resolving to `python3 -B -m unittest`
plus validated test file paths. The synthetic `1111111` base must be rebound to a real owned Git repository
before approved execution, recording the resulting changed plan digest.

## Greeting

REPO-INSPECTION: one task, `greeting`, has no dependencies. It trims names,
substitutes `friend` when blank, and preserves punctuation/nonblank names.
The named gate is `test/test_greeting.py`; examples are padded `Sam`, blank
whitespace and unchanged `Jo`. Goal allowance: two attempts, 660 seconds.

Review artifacts:
[goal](../../../priv/planner_eval/cases/greeting/goal.json),
[reference](../../../priv/planner_eval/cases/greeting/reference.json),
[test](../../../priv/planner_eval/repository/test/test_greeting.py).

VERIFIED: context digest:
`1b615cce63d34c930838e9ae12f1b1f612796d2752c7c31bb8508a7cb497c40d`.
Normalized reference plan digest:
`323ed846f0352dcee29595972cd81b02916ca369d2ff27c805689dbfda85dbce`.
Raw reference SHA-256:
`398126ce931c40c9bfdc27711ef7795b0cb619631f9aad18b0274797d498efaf`.

## Receipt

REPO-INSPECTION: `total` computes integer `price_cents * quantity` sums;
`receipt` depends on `total` and calls that function to render `Total: N cents`.
The first gate runs `test/test_total.py`; the second and global gates run total
and receipt tests. Empty basket gives zero; the example basket gives 475.
Both tasks modify the same source file, so this checks ordered composition,
not independent-file decomposition. Goal allowance: four attempts, 1260 seconds.

Review artifacts:
[goal](../../../priv/planner_eval/cases/receipt/goal.json),
[reference](../../../priv/planner_eval/cases/receipt/reference.json),
[total test](../../../priv/planner_eval/repository/test/test_total.py),
[receipt test](../../../priv/planner_eval/repository/test/test_receipt.py).

VERIFIED: context digest:
`cadb79e4c206920b980e7684b0ce10dd7e14e6ca984a0b7a04f23abe5909de89`.
Normalized reference plan digest:
`f03582c9a7964ae1bbf4572097dfd5afedb44fc369c528b7a3251349ee8ecc8b`.
Raw reference SHA-256:
`d26ef35c3ff1e7e807a911d49856ff7775705327ddd14f442161dcff9a63d146`.

## Catalog

REPO-INSPECTION: one task, `catalog`, trims names, removes blanks, deduplicates
and sorts case-sensitively. Its named gate is `test/test_catalog.py`; the
example expects `Apple`, `apple`, `pear`, retaining distinct capitalization,
and checks empty input. Goal allowance: two attempts, 660 seconds.

Review artifacts:
[goal](../../../priv/planner_eval/cases/catalog/goal.json),
[reference](../../../priv/planner_eval/cases/catalog/reference.json),
[test](../../../priv/planner_eval/repository/test/test_catalog.py).

VERIFIED: context digest:
`22c68771588ada558a0d3dc29cb2ad19fcdbf5ec9508143c60f9c28e3b845ad3`.
Normalized reference plan digest:
`8311ee7ff16318cdc5359909902cb459d7a12696ee522b189b8edd99483b3a96`.
Raw reference SHA-256:
`d3a1f4a6757c97e6b8beccfa7e9e59bc652db4895c24ad6366ee6ab46c86c01e`.

## Review decision and limitations

VERIFIED (user direction): reference-scope approval and the requested language
change are recorded above. Exact translated artifact digests are recorded here
without claiming separate human review of their bytes. Further changes require
fresh digests and another fixture smoke run. Acceptance as evaluation references
does not approve a production execution revision.

REPO-INSPECTION: this is a small smoke corpus. Two goals have one task and the
third has two tasks in one source file. It cannot establish quality on larger
repositories, complex graphs, other languages or real quota handoffs.
Named tests sample specified behavior; passing them alone does not establish
the change-only constraint, correct reuse of `total_cents(items)`, or all semantic
requirements. Review material diffs as well as gates. Fewer tasks than the
reference is not automatically worse, and more tasks is not automatically better.

VERIFIED (later user direction): the user authorized `chatgpt/gpt-6-luna` through
the subscription without a spending cap. The [first live packet](luna-evaluation.md)
records three completed proposals and two earlier setup/capture failures.
The CLI route did not establish a provider output-token cap or production
planner admission; it uses explicit byte/time bounds and no automatic repair.
The earlier proposed 4096-token budget is not claimed as enforced on that route.
UNVERIFIED: no exact model-plan execution approval is recorded. The two valid
plans, rebound to a real clean Git fixture base, are in the packet for review.
