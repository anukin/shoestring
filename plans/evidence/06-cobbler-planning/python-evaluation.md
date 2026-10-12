# Python evaluation corpus and trusted acceptance gate

REPO-INSPECTION: implementation base is
`95728a70f97e7a51d9726074d9991296c0917c64`. The user's instruction to work
directly on main without a PR overrides the standing isolation/PR workflow.
Local `.github/hooks/` and `.pi/` are outside this change.

## User direction and scope

VERIFIED (user direction): the user accepted the three reference task scopes
and asked for Go or Python instead of Elixir. This change translates the active
fixture repository, named tests and implementation steps to dependency-free
Python, replaces the superseded Elixir fixture files, and retains the reviewed
goal behaviors, examples, sequential dependency and numerical budgets.
The scope approval and fresh Python digests are in
[reference-review.md](reference-review.md). Converted bytes were not separately
human-reviewed; the report explicitly distinguishes this from task-scope approval.

REPO-INSPECTION: the closed gate registry previously supported only Mix commands.
`python_unittest` now requires one to sixteen unique repository-relative
`test/**/test_*.py` paths with Python identifier segments and a 200-byte bound.
The trusted argv is `python3 -B -m unittest` followed by those validated paths.
No arbitrary executable/module option, shell string, absolute path or parent
traversal is accepted. Existing Mix behavior remains covered by its original tests.
The planner schema exposes the new gate, and goal/task contracts use the same
validator. `-B` avoids bytecode caches changing the tested snapshot.

## Verification

VERIFIED: focused command exited 0:

```sh
MIX_ENV=test mix test test/shoestring/cobbler/plan_python_gate_test.exs test/shoestring/cobbler/plan_contract_test.exs test/shoestring/cobbler/plan_gate_runner_test.exs test/shoestring/cobbler/plan_gate_safety_test.exs test/shoestring/cobbler/planner_evaluation_test.exs test/mix/tasks/shoestring_plans_eval_test.exs
```

VERIFIED: **73 tests, 0 failures**, seed **320093**, **4.5 seconds**
(0.1 async, 4.4 sync). The earlier focused run before review-status bookkeeping
also passed **73 tests, 0 failures**, seed **473204**, **4.8 seconds**.
No intermittent failure or retry wrapper was introduced.

VERIFIED: six new capability checks cover registry bounds/injection refusal,
retention of valid argv/evidence, goal/task validation and schema exposure,
and the three cases through real `PlanGateRunner` execution. Each case uses a
new owned local Git repository: the baseline fails on assertions, reference
steps are committed in task order, and task/global gates pass with real
commit/worktree bindings. A wrong digest is refused; final snapshots remain
clean without bytecode caches. These checks do not replace the composed worker
lifecycle proof, which still uses its original Elixir fixture.

REPO-INSPECTION: the new gate is a capability addition, not a claimed bug fix.
Its positive acceptance behavior did not exist at the base. I did not verify a
pre-fix behavioral regression; existing Mix safety and binding tests are retained.

VERIFIED: `python3 -B tools/planner_eval/reference_smoke.py` exited **0** after
translation. The script requires exact named test counts and assertion failures
for baseline failures; import/compilation errors cannot substitute for that red
baseline. Reference steps must pass exactly the expected named test count.

| Case/phase | Tests | Failures | Exit |
| --- | ---: | ---: | ---: |
| Greeting baseline | 1 | 1 | 1 |
| Greeting reference | 1 | 0 | 0 |
| Receipt baseline | 2 | 2 | 1 |
| Total reference | 1 | 0 | 0 |
| Receipt reference | 2 | 0 | 0 |
| Catalog baseline | 1 | 1 | 1 |
| Catalog reference | 1 | 0 | 0 |

VERIFIED: six offline CLI context/reference exports exited **0**. All references
were schema-valid with no absent cited paths; all contexts contain Python-only
source/test files. Fresh context/plan/raw-reference digests are recorded in the
reference record. Quality remains `UNVERIFIED`, semantic scores remain empty,
and execution remains `not_run` in offline comparison reports.

VERIFIED: full repository gate `mix precommit` exited **0**: **4 doctests,
1906 tests, 0 failures, 1 skipped (6 excluded)**, seed **496581**,
**176.8 seconds** (9.9 async, 166.9 sync). JavaScript suites passed **52/52**
and **8/8**, with zero failures. The existing `:live` exclusion/skipped test
were not changed. The foreground gate had closed stdin and a 480-second bound;
its exact log is retained locally in `precommit.log`. No runtime/fixture changes
followed the gate. All **21** relative documentation links resolved and all
**9** recorded context/plan/raw-reference digests matched CLI output.
`git diff --check` passed.

UNVERIFIED: no live model/provider calls were made; no live run budget is authorized.

## Limits

REPO-INSPECTION: only the selected named tests run for each goal because unrelated
functions are intentionally broken in the starting fixture. Material diff review
must check unchanged public signatures/functions, test immutability and receipt
reuse of the total function. A passing named gate alone does not prove those
requirements. These remain small one-/two-task examples in one source file.

UNVERIFIED: actual model generation, scored quality comparison, approved model
execution and real provider handoff costs have not been evaluated. Scope review,
language diversity and fixture/gate success do not close iteration 6.
