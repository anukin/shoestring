# First subscription-model planner evaluation

VERIFIED (user direction): the user approved the reference task scopes, requested
Python or Go, then authorized `chatgpt/gpt-6-luna` with no spending cap and said
"go ahead". Existing direction permits working and pushing directly on main;
that overrides the standing branch/PR workflow for this task. Baseline:
`84c125d9a7dbb37a565767003094c1ed300c3d15`.

VERIFIED: the installed CLI reported `codex-cli 0.162.0` and `Logged in using
ChatGPT`. Read-only app-server model discovery exposed the exact `gpt-6-luna`
model with medium default effort. No credential contents were read or captured.
The interface follows [official non-interactive documentation](https://learn.chatgpt.com/docs/non-interactive-mode)
and [configuration documentation](https://learn.chatgpt.com/docs/config-file/config-reference).
Account model discovery, rather than documentation alone, established access.

## Outcome and limits

VERIFIED: five CLI invocations produced three complete proposals, two of which
pass the production planner-output validator. Two earlier invocations failed in
capture/setup. No automatic repair was requested, and no proposal was edited to
make it validate. Original answer bytes, invocation metadata and offline
comparisons are retained under [luna-evaluation/](luna-evaluation/).

| Case | Complete proposal | Static result | Tasks / edges | Reported output tokens |
| --- | --- | --- | --- | --- |
| Greeting | Second CLI invocation | Valid; partial assistant review | 1 / 0 | 443 |
| Receipt | First CLI invocation | Valid; partial assistant review | 2 / 1 | 979 |
| Catalog | Second CLI invocation | Rejected: `invalid_json` | Unavailable | 443 |

VERIFIED: completed turns reported 26,043 input tokens, including 5,376 cached
input tokens, and 1,865 output tokens in total. Usage for the failed invocations
is unknown. These are CLI-reported counts, not subscription cost or quota units.
Two valid proposals out of three completed responses is an observed result on
this tiny corpus, not a general model-quality estimate.

UNVERIFIED: no model plan has run through Shoestring. No exact human model-plan
approval, production subscription planner admission, provider-side output-token
cap or live handoff evidence is established. This packet does not close iteration 6.

## Capture and failures

REPO-INSPECTION: [the capture utility](../../../tools/planner_eval/codex_proposal.py)
invokes Codex once per new output directory, with ChatGPT authentication,
medium effort, ephemeral history, an empty read-only working directory, ignored
user configuration/rules, zero project-document allowance and execution features
disabled. It supplies only the exported context, which excludes reference plans
and implementations. JSON is requested in the prompt, not through native
`--output-schema`; validation happens after capture. Final-answer bytes and
allowlisted numeric usage are retained. Reasoning, raw event streams, diagnostic
text, account configuration and provider-generated session/item IDs are discarded.

REPO-INSPECTION: bounds are 180 seconds per CLI invocation, 65,536 answer bytes,
1 MiB per frame and 8 MiB for the stream. Oversized answers fail without
truncation. Unexpected/tool items stop capture and cancel the owned process
group. Local invocation accounting is separate from the durable domain planner
allowance. CLI transport retries were not measured; one CLI invocation is not
claimed to mean one HTTP request. The current helper additionally disables the
shared daemon and distinguishes charged launches from successful process starts;
those two refinements were added after the recorded live calls.

VERIFIED: a manual, bounded loopback compatibility probe, with authentication
disabled and a synthetic HTTP 400 response, observed `tools: []`,
`tool_choice: auto` and no Authorization header. It performed no model inference.
Its safe observations are in [offline-probe.json](luna-evaluation/offline-probe.json).
This was a manual CLI compatibility check, separate from the hermetic test gate.
It demonstrates the observed mock-provider request, not a provider-independent
tool-free guarantee or a production adapter proof.

VERIFIED: the retained failures are:

1. [Greeting capture failure](luna-evaluation/greeting/failed-run.json): stopped
   at an unrecognized item after 0.605 seconds; no answer or usage was captured.
   That helper counted every unknown item as a tool item and did not retain its
   type. A later offline probe showed startup `item.type = error` diagnostics;
   the capture was corrected to count/discard them while keeping top-level
   errors fatal. The original item's type and any inference usage are unknown.
2. Automatic approval review rejected a proposed catalog call because tool
   blocking was unverified after that failure. The call did not start. The
   subsequent offline empty-tool probe supplied new evidence, and the next
   escalation was approved. No rejection was bypassed.
3. [Catalog setup failure](luna-evaluation/catalog/failed-run.json): exited in
   0.016 seconds without events or usage. Offline diagnosis showed that the CLI
   forbids overriding the built-in `openai` provider. The attempted transport
   retry overrides were removed and the corrected configuration was rechecked
   against the loopback mock before the next live invocation.
4. [Catalog's complete answer](luna-evaluation/catalog/proposal.json) contains
   malformed trailing JSON. The production validator returns `invalid_json`;
   it is preserved byte-for-byte and remains rejected. It has no valid graph to
   execute or reliably score. No catalog repair was requested in this run.

## Assistant static review

VERIFIED: each raw proposal was compared using
`MIX_ENV=test mix shoestring.plans.eval compare CASE --file PROPOSAL` (exit 0
for each comparison). The command's exit status means a comparison was produced;
catalog's `candidate.schema_status` is `schema_failed`. The captured comparison
files retain `unreviewed` / `UNVERIFIED`; separate annotation files below contain
assistant review, not human or independent judge scores.

| Criterion (0–2) | Greeting | Receipt | Catalog |
| --- | --- | --- | --- |
| Acceptance coverage | 2 | 2 | Unscored |
| Boundedness and independence | 2 | 2 | Unscored |
| Dependency ordering | 2 | 2 | Unscored |
| Checkpoint usefulness | 1 | 1 | Unscored |
| Repository grounding | 2 | 2 | Unscored |
| Task count and handoff overhead | 1 | 1 | Unscored |
| Sequential execution success | Unscored | Unscored | Unscored |

REPO-INSPECTION: greeting's `update-greeting` covers trimming, the blank-name
fallback, punctuation and signature preservation with the correct named gate.
Receipt's `implement-total` covers multiplication, summation and empty baskets;
`render-receipt` depends on it and explicitly reuses `total_cents(items)` for
the exact format. Cited source/test paths and symbols exist in the snapshot.
Both decompositions match the reviewed reference's task count and dependency
shape, without exposing that reference to the model.

REPO-INSPECTION: checkpoints are weaker than the references: neither plan asks
for a commit identity, and greeting asks to run a gate without explicitly
capturing its passing result. The executor independently enforces commit/gate
evidence; that does not make the proposed checkpoints stronger. Receipt allows
no additional global-gate time if both task time maxima are consumed. No actual
execution failure or handoff overhead is inferred from these static observations.

Review annotations:
[greeting](luna-evaluation/greeting/semantic-review.json),
[receipt](luna-evaluation/receipt/semantic-review.json),
[catalog refusal](luna-evaluation/catalog/semantic-review.json).

## Concrete plans for execution review

VERIFIED: separate owned repositories were seeded from the unchanged Python
fixture, committed and checked clean. Both have real base revision
`84876c7022c9712aedd38cbc1f767cb58156be17`. Only
`goal.repository.base_revision` was replaced in each valid candidate; normalized
content equality after that substitution was checked with `PlanContract`, and
both rebound plans validate. These are prepared artifacts, not stored domain
revisions, approvals or executions. Fixture repositories and local logs remain
outside the source checkout; no cleanup was performed.

| Plan | Task order | Task limits | Goal limits |
| --- | --- | --- | --- |
| [Greeting bound plan](luna-evaluation/greeting/bound-plan.json) | `update-greeting` | 2 attempts, 180 seconds | 3 attempts, 300 seconds |
| [Receipt bound plan](luna-evaluation/receipt/bound-plan.json) | `implement-total` → `render-receipt` | 1 attempt, 300 seconds each | 2 attempts, 600 seconds |

REPO-INSPECTION: both plans allow changes only to `pantry.py`, preserve signatures,
forbid packages/network access and exclude unrelated functions. Greeting runs
`test/test_greeting.py`; receipt runs total first and then both total/receipt
tests. Catalog is excluded because its candidate does not validate. The model's
attempt/time limits differ from the reference limits and require review.

VERIFIED: exact bound plan digests:

- Greeting: `6b9bc3ae436268cae8be56dc2f8c22ef17ba9b1b88b76d9c15ac277955e686b0`.
- Receipt: `13ba4b39f66d01dd9d1e37a119803e73f85caebdb3792181d134843138d8decd`.

Bindings and original plan digests are in
[greeting binding](luna-evaluation/greeting/binding.json) and
[receipt binding](luna-evaluation/receipt/binding.json). The project requires
approval of a specific immutable revision and says, "No task may dispatch from
an unapproved or superseded revision."
[Milestone contract](../../milestones/06-cobbler-planning.md#work-package-c-cli-approval-interface).
Reference-scope approval does not invent a decision for these newly generated
contracts. Exact approval, import as immutable domain revisions and real-worker
execution evidence remain open.

## Verification

VERIFIED: the new capture checks use only local Python children, no Codex CLI
or network. They exercise preserved answer/usage alongside discarded reasoning,
IDs and diagnostics, tool refusal, multibyte byte limits, multiple-message
refusal, bounded local process execution, stdin EOF, malformed frames and timeout
cancellation. They are capability checks for new code, not a claimed regression
lock against an earlier committed implementation.

VERIFIED: the initial 12-check suite failed with one process-group signalling
error in both its sandboxed and escalated runs (2 of 2 before correction).
Reaping the exited direct child before signalling its group corrected the race;
this was not treated as an intermittent pass. After adding diagnostic handling,
the direct command
`python3 -B -m unittest discover -s tools/planner_eval -p test_codex_proposal.py`
reported **13 tests, OK**. The ExUnit wrapper runs these checks as part of the
full repository gate.

VERIFIED: `mix precommit` exited 0. ExUnit reported **4 doctests, 1907 tests,
0 failures, 1 skipped (6 excluded)**, seed **122463**, in **174.9 seconds**
(8.6 seconds async, 166.3 seconds sync). JavaScript suites reported **52/52**
and **8/8** passing, with no failures or skips. The new ExUnit capture wrapper
includes all 13 hermetic Python checks. Full command wall time was 178.414 seconds.

VERIFIED (subsequent run): [the receipt execution packet](receipt-live-run.md)
records the approved plan's first real production-path attempt. Its total
implementation passed its named test but remained uncommitted, so acceptance
failed and the dependent task stayed blocked across restart. This does not
establish successful model-plan completion.
