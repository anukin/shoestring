# Semantic evaluation preparation (2026-10-10)

REPO-INSPECTION: implementation base is `cb5734c36fb36d751365a42678f316d7c495bd1c`.
The user's explicit instruction to work directly on main without another branch
or PR overrides the standing isolation/PR workflow for this change. Local
`.github/hooks/` and `.pi/` content is outside the change.

## Scope and limits

REPO-INSPECTION: three small repository goals now have fixed goal contracts,
reference plans, dependency-free source/tests and reference implementation steps.
The offline CLI exports a digested context and compares saved raw output using
the production validator. Comparison reports separate schema/count observations,
pending semantic review and unrun execution. Proposal origin and model quality
remain explicitly unverified. Reference plans were written during implementation;
human review is pending. See `../../../docs/planner-evaluation.md` for the rubric.

REPO-INSPECTION: neither the module nor CLI starts the application or calls a
provider, database or gate. The separate reference smoke script runs only named
local fixture tests in newly owned temporary repositories. It retains exact logs,
never consumes a model proposal, and has closed stdin and bounded invocations.

## Focused verification

VERIFIED: command:

```sh
MIX_ENV=test mix test test/shoestring/cobbler/planner_evaluation_test.exs test/mix/tasks/shoestring_plans_eval_test.exs
```

VERIFIED: **9 tests, 0 failures**, seed **73155**, **0.1 seconds**. Coverage includes
three valid references, exact goal preservation, supplied provenance/command
rejection, cycles, missing gates, malformed/oversized JSON, bounded file reads,
absent-path observations, safe error output and CLI argument refusal. Filtering
checks both removal of rejected sensitive content and retention of required
error/reference/context evidence. The first development run was **8 tests,
1 failure**, seed **195966**: an assertion forbidding the word `command` also
matched the required `embedded_command` error code. It was corrected to check
absence of the input field; sensitive content removal remains asserted.

VERIFIED: standalone command
`MIX_ENV=test mix shoestring.plans.eval reference receipt` exited **0**, reported
a valid two-task, one-edge fixture and left quality `UNVERIFIED`, semantic review
`unreviewed`, reference review `pending_human_review`, execution `not_run`.

VERIFIED: `python3 tools/planner_eval/reference_smoke.py` exited **0**. Initial
fixture runs failed on behavior assertions, not missing modules/signatures:

| Case/phase | Named tests | Failures | Exit |
| --- | ---: | ---: | ---: |
| Greeting initial | 1 | 1 | 2 |
| Greeting reference step | 1 | 0 | 0 |
| Receipt initial | 2 | 2 | 2 |
| Total reference step | 1 | 0 | 0 |
| Receipt reference step | 2 | 0 | 0 |
| Catalog initial | 1 | 1 | 2 |
| Catalog reference step | 1 | 0 | 0 |

VERIFIED: the smoke script required exactly the expected assertion-failure counts
before applying changes. Receipt's first task passed independently before the
dependent rendering step. Temporary repositories and exact logs remain local;
machine paths are not committed.

REPO-INSPECTION: these are new capability/fixture checks, not a regression lock
against `cb5734c`. The evaluator and corpus did not exist at that commit; copying
the tests backward would fail on the missing surface. I did not verify a pre-fix
behavioral regression for this addition.

## Remaining acceptance

VERIFIED: full repository gate `mix precommit` exited **0**: **4 doctests,
1900 tests, 0 failures, 1 skipped (6 excluded)**, seed **822772**, **171.0 seconds**
(9.1 async, 161.9 sync). JavaScript suites passed **52/52** and **8/8** with
zero failures. The existing gate excluded `:live`; this change adds no skipped
tests or retry wrappers. Full output is retained locally in the planner-evaluation
precommit log. `git diff --check` also passed.

UNVERIFIED: actual model generation, model-vs-human comparison and approved
sequential execution of model proposals have not been performed. No live run or
provider quota was spent. Human reference review and a named model/provider/run
budget are still required; iteration 6 remains in progress. Fixture smoke results
do not substitute for semantic model quality or the separate lifecycle proof.
