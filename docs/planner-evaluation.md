# Offline planner evaluation

REPO-INSPECTION: `mix shoestring.plans.eval` prepares and compares saved proposals
without starting Shoestring, using a database, calling a model or executing gates.
It uses the production planner-output validator. Schema results stay separate
from semantic review and execution evidence. A report never grants approval.
Schema failure is a report result: inspect `candidate.schema_status`, not just
the command's exit code.

## Cases and references

REPO-INSPECTION: `priv/planner_eval/` supplies three goals in a dependency-free
Python Pantry repository, using standard-library `unittest`:

| Case | Goal | Reference tasks | Named tests |
| --- | --- | --- | --- |
| `greeting` | Trim names; substitute `friend` for blanks | One normalization task | Greeting |
| `receipt` | Sum integer prices times quantities; render the total | Total, then dependent receipt | Total and receipt |
| `catalog` | Trim, remove blanks, deduplicate and sort case-sensitively | One normalization task | Catalog |

VERIFIED (user direction): the user accepted the three task scopes and requested
Python or Go instead of Elixir. The artifacts now use Python; the converted
bytes have not separately been human-reviewed. Reports record
`user_approved_with_language_change` and explain that distinction. This approval
is for evaluation baselines, not an executable production revision.
REPO-INSPECTION: reference plans and implementation steps are deterministic
fixtures written during implementation. The context export includes the exact goal,
output schema and repository file contents, bound by a digest. Reference plans
and solutions are excluded from model input. `1111111` is a synthetic base
revision, not an executable Git revision.

VERIFIED: the [reference review packet](../plans/evidence/06-cobbler-planning/reference-review.md)
records the three concrete decompositions and their context/plan digests.
The user's scope approval and the conversion are recorded there. The [acceptance audit](../plans/evidence/06-cobbler-planning/acceptance-audit.md)
maps the separate deterministic milestone checks to existing test assertions.

```sh
mix shoestring.plans.eval list
mix shoestring.plans.eval context receipt > receipt-context.json
mix shoestring.plans.eval reference receipt
mix shoestring.plans.eval compare receipt --file receipt-proposal.json > receipt-comparison.json
```

REPO-INSPECTION: comparison expects raw planner JSON without Shoestring-owned
`planner` provenance. It checks the exact goal, strict contract, graph, budgets
and forbidden content without repairing output. File input is bounded to 65,536
bytes before decoding. Rejected content is not echoed; safe error codes remain.
Reports include the context digest, normalized candidate/reference digests and
SHA-256 of the original candidate bytes. Saved proposal origin is unverified.

REPO-INSPECTION: task counts, edges, transitions, attempts and declared durations
are observations, not scores. Absent paths need review and may be intended new
files. Existing paths do not prove correct symbols or repository facts. Task
transitions do not predict provider handoffs.

## Reference execution smoke check

```sh
python3 tools/planner_eval/reference_smoke.py
```

REPO-INSPECTION: this Python 3.10+ script creates new owned temporary repositories,
runs named local Python tests with closed stdin and a 60-second bound per invocation,
and leaves logs and a JSON summary for inspection. Each initial goal must fail
on behavior assertions. Shipped reference implementations are then applied in
task order; total passes before receipt rendering is applied. The script never
accepts model output. It verifies reference test/implementation steps, not the
Shoestring executor, quota or approval lifecycle. The composed lifecycle proof
is in the iteration-6 `planner-demo.md` evidence record.

REPO-INSPECTION: plan references use the trusted `python_unittest` gate, resolved
to `python3 -B -m unittest` plus mandatory named `test/**/test_*.py` paths.
Options, arbitrary executable/module parameters, absolute paths and traversal
are rejected. `-B` prevents bytecode caches from dirtying the tested worktree.
Real-gate capability checks cover failed baselines, passing reference steps,
Git commit/worktree binding and clean snapshots. They do not execute a model
proposal through the complete Shoestring worker lifecycle. See
[the Python conversion evidence](../plans/evidence/06-cobbler-planning/python-evaluation.md).

## Semantic review procedure

VERIFIED (user direction): the user authorized `chatgpt/gpt-6-luna` through the
subscription without a spending cap. The first recorded live comparison has
three completed proposals: greeting and receipt validate; catalog fails with
`invalid_json`. Assistant static review stays separate from human review and
execution. See [the run and review packet](../plans/evidence/06-cobbler-planning/luna-evaluation.md).

REPO-INSPECTION: `tools/planner_eval/codex_proposal.py` is an explicitly invoked
evaluation utility, not a production planner adapter. It runs one ephemeral
Codex CLI invocation in an empty read-only directory, ignores user configuration,
disables execution features and retains final-answer bytes and numeric usage.
It bounds each invocation to 180 seconds, each answer to 65,536 bytes, each frame
to 1 MiB and the stream to 8 MiB. It rejects tool items and never repairs output
automatically. It requests JSON through the prompt schema; native structured
output is not enabled in this run. Schema validation happens after capture.

UNVERIFIED: this route has no demonstrated provider-side output-token cap or
Shoestring planner admission. Local invocation records are not the durable
domain planner allowance. A production subscription adapter, if added, must
establish those boundaries before wiring into normal admission and lifetime
allowances. That integration is separate from evaluating saved model proposals
through the existing approval/execution path. Deterministic planner admission
evidence and semantic execution evidence must retain their distinct scope.
Preparing or comparing files spends no quota.

1. Record the human reference review and its scope against the pinned goal and
   repository. Current review accepted the task scopes with a language change;
   do not describe the converted bytes as separately human-reviewed. Record
   reference/context digests; rerun fixture checks after edits.
2. After run authorization, preserve the context, configuration, bounded attempt
   accounting and raw structured proposal. Keep initial and repaired outputs as
   separate results. Never store credentials, private paths, provider identifiers
   or hidden reasoning.
3. Compare every proposal, including rejected proposals, against the reviewed
   reference for the same context digest. Record schema validity separately.
4. Score each criterion below `0` (fails), `1` (partial), or `2` (satisfies), citing
   concrete task IDs, criteria, paths or evidence. Missing evidence stays unscored.
   Any optional judge score stays separate from human and deterministic results.
5. Record actual sequential execution: approved revision/digest, material changes,
   task/global gates, accepted dependency order, amendments, attempts and observed
   handoffs. Disclose human edits; success after repair is not initial-plan success.

| Criterion | Evidence needed |
| --- | --- |
| Acceptance coverage | Map each goal requirement to task criteria and gates; identify gaps |
| Boundedness and independence | Scope, artifacts, shared-file coupling and numeric bounds |
| Dependency ordering | Check missing and unnecessary prerequisite edges |
| Checkpoint usefulness | Safe stopping condition and evidence useful to a successor |
| Repository grounding | Inspect cited files/symbols against exported contents |
| Task count and handoff overhead | Explain extra tasks and record actual transfers; fewer is not automatically better |
| Sequential execution success | Accepted material work and global gates, including failure/repair costs |

REPO-INSPECTION: domain execution requires an owned Git fixture and actual base
revision. Record that binding transformation and the new plan digest; the
synthetic reference is not directly executable. The smoke script does not prove
approved model-plan execution.

UNVERIFIED: human semantic review across the pack remains open. Production
subscription planner admission is separate integration work. The first live
packet adds two valid proposals, one rejected proposal and partial assistant
static review; reference smoke checks do not supply execution or admission evidence.

VERIFIED (subsequent run): [the receipt execution packet](../plans/evidence/06-cobbler-planning/receipt-live-run.md)
records an approved model-plan attempt through real production admission,
workers, harness and worktree. Its dirty-worktree acceptance failure and blocked
dependent survive restart. No production planner call is claimed by this packet.

VERIFIED (2026-10-12): [the new receipt evaluation](../plans/evidence/06-cobbler-planning/receipt-live-success.md)
completed both tasks through real production admission/workers and Codex after
controlled private Git storage was added. Both material commits and task/global
gates were accepted, and node restart preserved task one's acceptance before
task two ran without replanning. It used a new explicitly authorized goal and
allowance; the failed evaluation remains intact. This proves execution of that
saved model proposal, with the fresh fixture base binding disclosed. It does
not supply a production subscription planner adapter or close semantic review
across the whole evaluation pack.
