# CLI plan review

REPO-INSPECTION: `mix shoestring.plans` provides package C's local review flow.
Commands return JSON on stdout; refusals raise a Mix error with a nonzero exit.
They migrate/start only the repository and do not start application workers,
provider monitors, inference, leases or task dispatch. Use the same state root
as the server (`SHOESTRING_STATE_DIR` in dev/prod). Tests use the separate
`SHOESTRING_TEST_STATE_DIR` variable.

## Review a goal

```sh
mix shoestring.plans list "$GOAL"
mix shoestring.plans show "$GOAL"
mix shoestring.plans show "$GOAL" --revision 1
mix shoestring.plans planner "$GOAL"
```

REPO-INSPECTION: `show` includes the full goal acceptance contract, the plan,
tasks in deterministic dependency order, revision/digest/status, human decision
metadata and the stored planner summary. Omitting the revision selects the latest
proposal or decision, which need not be the currently approved revision. `list`
shows every revision's status. Neither command authorizes work.

REPO-INSPECTION: `planner` exposes model/provider/support tier, attempt history,
validation errors, charged output allowance and remaining planning budget.
It labels this as a stored budget, not a live provider subscription allowance.
Each admitted call charges its full configured output allowance before inference;
displaying, editing, adopting or rejecting does not replenish it. A missing
request reports `not_requested` and an unknown support tier. A ready candidate
is displayed with its digest only after validating its content and event replay.

## Import or edit JSON

```sh
mix shoestring.plans propose "$GOAL" --file plan.json \
  --request-id proposal-1 --by human:operator

mix shoestring.plans export "$GOAL" --revision 1 > plan.json
# Edit plan.json with your own editor, then submit it as a new revision:
mix shoestring.plans edit "$GOAL" --revision 1 --digest "$PARENT_DIGEST" \
  --file plan.json --request-id edit-1 --by human:operator
```

REPO-INSPECTION: `export` emits only editable plan content. Edits can change
outcomes, dependency edges, criteria, checkpoints and non-goals, subject to the
strict plan contract. Files over 65,536 bytes, invalid JSON, cycles, missing
criteria, unbounded tasks and embedded commands are refused. File reads are
bounded before decoding. The edited revision becomes a new **proposal** with
the specified parent; the parent's content/digest remain preserved. The parent
digest must match the exact content you reviewed. All task identities introduced
by approved history must remain present. Explicit retirement and completed-work
evidence preservation belong to package E.

REPO-INSPECTION: replay the same request ID with identical content to obtain the
original proposal; use a new ID for a new edit. Reusing an ID with changed content
is a conflict. Stored content/digest disagreement prevents review/export and
decisions rather than rendering corrupt authority.

## Adopt a planner candidate

```sh
mix shoestring.plans planner "$GOAL"
mix shoestring.plans adopt "$GOAL" --request-key "$PLANNER_REQUEST_KEY" \
  --digest "$CANDIDATE_DIGEST" --by human:operator
```

REPO-INSPECTION: adoption uses the existing planner boundary's human-only API and
fixed candidate request identity. It records a proposed revision; a separate
approval is required. It does not run inference or repair. This CLI slice does
not expose planner generation/repair or goal creation; those existing domain
entrypoints remain separate. Adoption here covers initial planning, not an
amendment to an executing plan.

## Decide an exact revision

```sh
mix shoestring.plans approve "$GOAL" --revision 2 --digest "$DIGEST" \
  --request-id approval-2 --by human:operator --note "Reviewed dependencies and gates."

mix shoestring.plans reject "$GOAL" --revision 2 --digest "$DIGEST" \
  --request-id rejection-2 --by human:operator --reason "Acceptance needs a narrower scope."
```

REPO-INSPECTION: choose one decision per revision. Both paths require the exact
revision and digest; neither infers them from a moving latest pointer. Identity
must be `human:`-prefixed, and rejection requires a reason of at most 500
characters. These are local attribution labels, not authenticated identities.
The domain checks the bindings inside its transaction. Repeat the same decision
ID/kind/revision/digest to replay the durable decision. A conflicting reuse,
already-decided revision or stale digest is refused.

REPO-INSPECTION: approving a newer revision supersedes the older authority but
does not cancel running work or begin execution. A new edit does not supersede
anything until approved. Repository-only CLI writes persist canonical events;
they do not broadcast PubSub hints to a separate server process. Reload views
to read durable state.

REPO-INSPECTION: approved-plan execution is a separate
[CLI interface](cli-execution.md), with saved-agent binding and a hermetic
worker/worktree/restart proof. Manual amendments preserve accepted evidence;
model-assisted amendment and retirement remain open. These later additions do
not expand the verification claims of this review-interface slice. No live
provider was called for this slice.
