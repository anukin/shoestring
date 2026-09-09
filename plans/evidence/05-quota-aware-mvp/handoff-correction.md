# Handoff Correction: Intent-First, Fresh Sessions, Continuation Actually Sent (I5)

## Claim labels

- `VERIFIED`: proven by committed code and the exact gate/test outputs quoted below.
- `REPO-INSPECTION`: derived from direct inspection of committed repository files.
- `UNVERIFIED`: cross-provider LIVE handoff (explicitly out of scope; hermetic Fake-to-Fake only).

## Problem (VERIFIED)

On base `85437ed`, `Elves.resume_handoff/4` (`lib/shoestring/elves.ex`) ran
`Runs.request/3` + `adapter.resume/3` with the sender's prior identity BEFORE
appending `handoff.created` (effect-before-intent, violating WP A). Claude
defines no `resume/3`, so cross-provider handoff to Claude always failed
`resume_unsupported`; Codex was asked to resume a foreign session instead of
starting fresh; and the receiver's turn carried only the original prompt
(`CodexAppServer.Session` `thread_resume` used `run_request.prompt`) while
the continuation was ignored.

## Implementation (VERIFIED)

P1 — intent-first (`lib/shoestring/elves.ex`, `resume_handoff/4`):
validate → `handoff.created` intent → `run.requested` → `adapter.start/2`.
A `check_handoff_intent/3` idempotency-key guard (`handoff:<handoff_id>`)
runs before any side effect: replay after success returns the stored run
with a durable-derived identity and zero new adapter calls; replay after a
crash between intent and effect continues to exactly one effect, reusing
the stored run-id pointer.

P2 — cross-provider = fresh session: `invoke_start/3` calls
`adapter.start/2` (never resume) with `handoff_request/3`, whose prompt is
`Continuation.compose_handoff_prompt/2` (checkpoint pointer + next_action +
decision refs + constraints summary, truncated to 4,000 chars,
transcript-free). The sender's session identity is never constructed for
the target. `RunRequest` continuation stays the exact 3-key pointer.

P3 — same-provider resume unchanged: `resume_same_run/4` still uses
`adapter.resume/3` with the prior session identity, and the
`validate_resume/3` match/mismatch matrix is untouched
(`lib/shoestring/harness/continuation.ex` existing functions unmodified).

P4 — `CodexAppServer.Session` `thread_resume` now launches its turn with
`resume_turn_text/1`: original prompt + `[Resume from checkpoint
<id>] / Next action: <...> / Decision refs: <...>` built from the three
continuation keys only. Fresh `thread_start` keeps the plain prompt.

P5 — adapters without `resume/3` (Claude) return the precise
`:resume_unsupported_for_provider` error from `invoke_resume/4` (no fake
resume added); cross-provider TO Claude goes through the P2 fresh-start
path (`ClaudeHeadless.start/2` simulated in hermetic tests).

P6 — `handoff.created` schema additive-only: no registry/projector change;
`Continuation.handoff_payload/1` required/optional keys and projectors stay
v1. Only additions: `Continuation.compose_handoff_prompt/2` and
`Continuation.handoff_prompt_max_chars/0`.

## Ordering proof (VERIFIED)

`test/shoestring/harness/handoff_correction_test.exs` asserts the new run's
`handoff.created` sequence is strictly less than its `run.requested`
sequence, `RequestLog` holds exactly one `:start` and zero `:resume`
entries, the composed prompt contains the `NEXTACTION-BRAVO7` continuation
text and checkpoint id but not the `ORIGINAL-TRANSCRIPT-ALPHA7` original
prompt, and the sender session id (`fake-session-sender-ALPHA7`) appears
nowhere in the recorded request.

## Fail-on-base (VERIFIED against 85437ed)

New locks fail on base for the right behavioural reasons; the P3 matrix
test is labeled DOCUMENTATION and passes on base:

| test | base result | reason |
|---|---|---|
| intent-first + fresh session + composed prompt | FAIL | base records `:resume` (no `:start`), original prompt, effect-before-intent |
| crash-between replay (failing adapter then retry) | FAIL | base `resume` ignores the start-failure scenario and succeeds |
| replay-after-success | FAIL | base duplicates the adapter call (no idempotency guard) |
| P3 same-provider matrix | PASS | documentation, matrix unchanged |
| Claude same-provider precise error | FAIL | base returns generic `:resume_unsupported` |
| handoff TO Claude fresh start | FAIL | base attempts `resume` and errors instead of starting |
| Codex resume turn carries continuation | FAIL | base turn text lacks the next-action marker |

## Adjacent fix found while testing (VERIFIED)

`invoke_resume/4`'s `function_exported?/3` check did not load unloaded
adapter modules (`function_exported?/3` never loads), so the first resume
call in a fresh VM spuriously reported unsupported depending on test seed
(pre-existing on base). Both `invoke_resume/4` and `invoke_start/3` now go
through `adapter_exports?/3` (`Code.ensure_loaded/1` first). No behaviour
change beyond determinism.

## Consequential test updates (reported deviation)

Three pre-existing assertions locked the old resume-based handoff and
contradict P2, so each was minimally updated (`RequestLog.resumes` →
`RequestLog.starts` + assert no resumes; pointer/payload assertions
untouched):

- `test/shoestring/harness/continuation_resume_test.exs` (handoff test)
- `test/shoestring/harness/eval_matrix/demo_test.exs` (provider-switch leg)
- `test/shoestring/harness/eval_matrix/ablation_test.exs` (handoff arm)

## Recorded deviation from P1's literal order

The trajectory writer (`lib/shoestring/trajectory/writer.ex`,
`validate_run_reference/2`, REPO-INSPECTION) requires a trusted `run_id`
to already exist as a goal-owned run row, so the bare run row is inserted
just before the `handoff.created` append (via the public
`Runs.build_intent_changeset/3` + `Runs.insert_or_recover/2`, then
`Runs.ensure_requested_event/4`). The observable event order is still
`handoff.created` < `run.requested` < adapter effect, the guard still
precedes everything, and the `handoff.created` envelope (including trusted
`run_id` = new run) is byte-identical in shape to the base version.

## Gate (VERIFIED)

`mix precommit` — exact command and counts recorded in the task report.

## Scope note

Touched: `lib/shoestring/elves.ex` (resume/handoff only),
`lib/shoestring/harness/codex_app_server/session.ex` (turn-input
composition only), `lib/shoestring/harness/continuation.ex` (additive
only), the three test files above plus the new
`test/shoestring/harness/handoff_correction_test.exs`, and this note.
Untouched: dispatcher/run_new/dispatches glue, `elf.ex` ingest,
wakeups/worker/config, goal lifecycle states, presentation/timeline.
Live cross-provider handoff stays explicitly UNVERIFIED.
