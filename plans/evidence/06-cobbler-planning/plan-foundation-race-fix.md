# Iteration 6 — independently reproduced red gate on PR #89, and its fix

Branch: `polly/iter6-plan-foundation-recovery`
Red at: `f265da6c2803c6711058f093fc4a8a0300085101`

Identifier and redaction conventions for this directory are in its
`README.md`. No credential, provider-generated identifier, machine
identifier, absolute home path, or hidden model reasoning appears here.

## The red result, preserved

VERIFIED — independent reviewer run, quoted from the supplied report and
from `.shoestring/polly-f265da6-precommit.log` in the worktree:

```
$ timeout 300 mix precommit < /dev/null > .shoestring/polly-f265da6-precommit.log 2>&1
exit 2, seed 251449, 166.1 seconds
4 doctests, 1650 tests, 1 failure, 1 skipped (6 excluded)
gate_0a.node_test 52/52, ui.node_test 7/7
```

```
  1) test the same approval replayed concurrently records one decision and one event
     (Shoestring.Cobbler.PlanApprovalRaceTest)
     test/shoestring/cobbler/plan_approval_race_test.exs:159
     unexpected concurrent approval outcomes: [ok: %{...}, ...]
     code: assert Enum.all?(results, fn
     stacktrace:
       test/shoestring/cobbler/plan_approval_race_test.exs:178: (test)
```

The assertion message was useless: `inspect/1` on the raw results printed
whole revision structs and the pretty-printer truncated the offending
element away.

## Honest account of my earlier green run

My prior report claimed three green `mix precommit` runs at this tree and
is **not** withdrawn as a record of what those runs printed — but it was
wrong as a statement about the code. The gate was genuinely red; my runs
did not surface it. Two separate reporting errors stand corrected:

1. I named the commit `5d1a8b2…` in my completion summary. The commit is
   and always was `f265da6`. I verified the author and trailers after
   committing but never read the SHA back.
2. I treated three green runs as evidence the concurrency was sound. They
   were evidence only that this particular race did not lose on those runs.

**No intermittency label is claimed.** I could not reproduce the reviewer's
failure, and that is a limitation of my reproduction, not a property of the
defect. See "Reproduction attempts" below.

## Reproduction attempts (all VERIFIED, all green — i.e. all failed to reproduce)

| Attempt | Result |
| --- | --- |
| `mix test --seed 251449` (full suite, the reviewer's seed) | green, 1650 tests, 0 failures |
| 25 focused runs of `plan_approval_race_test.exs`, seeds 251450–251474, under 6 saturating CPU load processes | 25/25 green |
| 100-iteration 4-way concurrency probe against one stable scratch repo | green; **zero** unique-constraint violations |

The seed is not the trigger. On a connection that actually takes SQLite's
write lock, `BEGIN IMMEDIATE` serializes the writers and the window never
opens.

## Root cause

Two defects, both in `Shoestring.Cobbler.Plans`, both traced to a
behavioural API consequence.

### 1. Idempotency rested on the transaction mode, not on the index

`decide/4` reads `cobbler_plan_decisions` to detect a replay and then
inserts. `propose/3` reads `(goal_id, proposal_id)` and `max(revision_number)`
and then inserts. Both are read-then-write pairs.

`mode: :immediate` closes those windows by taking SQLite's write lock at
BEGIN — **but only when it is in effect**. Inside an enclosing transaction
Exqlite issues a SAVEPOINT instead and takes no write lock. That is not
hypothetical: it is the ExUnit SQL sandbox (`Shoestring.DataCase`, which
every other plan test runs under) and any future caller that wraps this
store in its own transaction. `Shoestring.Trajectory.Writer` already
records this same degradation in its own comments.

**Behavioural consequence.** A writer whose replay lookup loses the race
does not converge on the winner's row. It proceeds down the record path and
is then refused — with `{:error, {:plan_revision_not_pending, ...}}` once
the winner has flipped the revision status, or
`{:error, {:plan_decision_insert_failed, changeset}}` on the unique index,
or on the propose side `{:error, {:plan_parent_required, ...}}` because the
stale read made a replay look like a brand-new revision. Every one of those
is a **plan-level refusal reported for a request that in fact succeeded**,
and it directly contradicts the documented guarantee that re-sending the
same id with the same content replays the original row.

`{:plan_revision_not_pending, _}` is a 2-tuple that is not
`{:database_busy, _}`, which is exactly the shape that failed the
reviewer's `Enum.all?`. REPO-INSPECTION: this is consistent with the
observed failure; UNVERIFIED that it is the specific tuple that run
produced, because the pretty-printer truncated it and I could not
reproduce the run.

**Fix.** Idempotency now rests on the unique index, which is always in
effect, rather than on the transaction mode, which is not.

- `load_decidable_revision/3` *classifies* (`{:proposed, _}` /
  `{:already_decided, _}`) instead of refusing outright. "Already decided"
  is only a refusal once we know the decider is someone else, and that
  answer lives in the decisions table.
- `converge_or_refuse/4` is the single place that answers "is this a
  replay?" after the cheap lookup missed. It re-reads inside the same
  transaction and defers to `replay_decision/4`, so a decision id that
  disagrees on kind, revision, or digest is still a conflict.
- The decision row is inserted **before** any mutation, so a loser has
  nothing to undo.
- A `(goal_id, decision_id)` index loss converges; a
  `plan_revision_id` index loss stays a refusal, because a *different*
  decision id cannot claim a revision that is spoken for.
- On the propose side, `resolve_proposal_replay/5` applies the same rule
  after rollback: a proposal id that already carries byte-identical content
  is the same request, so it replays. Digest equality is the whole guard —
  different content under the same id keeps its original refusal.

### 2. Storage exceptions escaped the structured-error contract

`Plans` documents that every error leaving it is a structured tuple. It was
not true: `run_transaction/2` rescued only `Exqlite.Error` and
`DBConnection.ConnectionError`. A concurrency probe surfaced
`Ecto.MultiplePrimaryKeyError` escaping from `append_one_event/5`, and the
committed regression test shows `Ecto.StaleEntryError` escaping from the
decision insert.

**Behavioural consequence.** A caller — eventually a LiveView or a worker —
gets a crash where the contract promises a refusal it can branch on.

**Fix.** Two deliberately distinct classes, and a **closed** list:

- `{:database_busy, message}` — lock refused or connection unavailable.
  Nothing written; a plain retry converges.
- `{:database_conflict, detail}` — the write met storage constraints this
  code did not anticipate. Rolled back whole, but the caller should
  **re-read** before deciding, because durable state may have moved.

A programming error (`ArgumentError`, `FunctionClauseError`, a bad query)
still crashes loudly. A committed test asserts exactly that.

## Pre-fix proof

VERIFIED — the new regression file run against `f265da6` in an owned
detached proof worktree (`$PREFIX`), with only the two new test-support
modules and the test file copied in and no production file changed:

```
$ cd $PREFIX && git log --oneline -1
f265da6 Add the Cobbler plan contract and durable approval foundation
$ MIX_ENV=test mix test test/shoestring/cobbler/plan_decision_race_window_test.exs --seed 0
8 tests, 6 failures
```

Each failure is behavioural, not a `NameError` or a missing module:

| # | Test | Pre-fix behaviour |
| --- | --- | --- |
| 1 | decision race converges on the winner's row | `{:error, {:plan_revision_not_pending, %{"status" => "approved"}}}` |
| 2 | decision race writes nothing extra | same refusal |
| 3 | decision race still refuses a genuine conflict | refused with the wrong reason (`:plan_revision_not_pending`, not `:plan_decision_conflict`) |
| 4 | proposal race converges on the winner's row | `{:error, {:plan_parent_required, %{"revision_number" => 2}}}` |
| 5 | proposal race on different content is still a conflict | same wrong reason |
| 6 | a storage exception becomes a structured conflict | raised `(Ecto.StaleEntryError) attempted to insert a stale struct` |

The two tests that pass on both commits are guards, and are labelled as
such: "a second decision id for an already decided revision is still
refused" and "a programming error still crashes loudly".

The interleaving is driven deterministically by
`Shoestring.Test.RacingPlanRepo`, which answers one chosen lookup `nil`
although a row exists — exactly what a writer observes when its read
precedes a competing writer's commit. No sleeping, no retrying, no racing
two real writers and hoping the scheduler cooperates.

## Replay acceptance: reconstruction, not comparison

The earlier replay evidence compared rebuilt state against surviving rows,
which proves little when the rows are the thing under test. Two tests now
**destroy the derived projections** and reconstruct from the event log
alone:

- `reconstructs the whole state after the derived rows are destroyed` —
  deletes every `cobbler_plan_revisions` row for the goal (decisions
  cascade), asserts the tables are empty and `authority/2` returns `nil`,
  then asserts `rebuild/2` returns all three revisions with their lineage,
  status, author and ordering; all three decisions with the digests they
  bound and the recorded rejection reason; the active authority with its
  digest **recomputed** from the reconstructed content; and the content of
  the superseded and rejected revisions too. It also asserts the loss is
  *reported* as divergence rather than papered over.
- `reconstruction survives destroying the derived rows AND rebuilding
  projections` — same, with `Trajectory.Projector.rebuild/2` in between.

## Gate

VERIFIED — three consecutive full runs in `$WORKTREE` after the fixes:

| Run | Command | Seed | Result |
| --- | --- | --- | --- |
| 1 | `mix precommit` | 465568 | exit 0 — 4 doctests, 1660 tests, 0 failures, 1 skipped (6 excluded); node 52/52 and 7/7 |
| 2 | `mix precommit` | 127626 | exit 0 — same counts |
| 3 | `mix precommit` | 330808 | exit 0 — same counts |

1660 − 1650 = 10 new tests: 8 in `plan_decision_race_window_test.exs`, 2 in
`plan_replay_test.exs`. No existing test was deleted or skipped.

## Test changes that are corrections, not widenings

- `plan_approval_race_test.exs` now unwraps `Task.async_stream`'s
  `{:exit, reason}` into a named `{:raised, reason}` result. Previously a
  raised exception blew up an unrelated `{:ok, result}` pattern match, so
  "the API raised" — one of the things this test exists to catch — was
  reported as a `FunctionClauseError` in test plumbing.
- Its allowed-outcome predicate accepts `{:error, {:database_conflict, _}}`
  alongside `{:error, {:database_busy, _}}`. This is not a widening to hide
  a failure: `:database_conflict` is the structured form of a condition
  that previously escaped as a raw exception, and the same change makes the
  test refuse raises by name for the first time.
- Its failure message now prints a compact outcome tag per result instead
  of `inspect/1` on whole structs, so a future failure names the offender
  instead of truncating it away. No fixture content and no identifiers are
  printed.
- One test expectation was corrected with a stated reason: "a proposal that
  loses the race on DIFFERENT content is still a conflict" now supplies
  `parent_revision_number: 1`, so the only thing wrong with the request is
  the conflicting proposal id. Without it the stale read made the request
  fail first as a parentless second revision — an accurate refusal, but not
  the one the test was written to pin.

## Remaining limitations

- **UNVERIFIED — I never reproduced the reviewer's exact failure.** The
  fixes are proved against a deterministic injection of the interleaving,
  not against that run. I believe the mechanism matches the observed
  failure shape, and I have not proved it.
- **The three green gates above do not prove the race is gone.** My three
  green gates before the fix did not prove it either. What carries weight
  is the deterministic regression lock, not the run count.
- **`append_one_event/5` still rescues only `Ecto.ConstraintError`
  directly.** Other storage raises from it are now caught one level up by
  `run_transaction/2` and reported as `:database_conflict`, which loses the
  event type from the reason. Acceptable here, worth tightening if event
  append ever grows a second caller.
- **`Ecto.MultiplePrimaryKeyError` is converted but not explained.** I
  observed it in a probe that repeatedly started and stopped a repo under
  concurrency, and did not isolate whether the trigger is that churn or
  something in the insert path. It is handled as `:database_conflict`
  rather than crashing; the underlying cause is unexplained.
- **`status_changeset/3` sets `updated_at` from the injected clock but
  Ecto overwrites it with wall-clock time on update.** Cosmetic, nothing
  asserts on it, not fixed here.
- Scope is unchanged: no executor, no model planner, no amendment
  orchestration, no approval UI, no provider or network access.
