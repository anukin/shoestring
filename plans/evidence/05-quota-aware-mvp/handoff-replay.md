# Handoff Replay Honesty: No Success for Incomplete Effects (Round-2 Finding 5)

## Claim labels

- `VERIFIED`: proven by committed code and the exact gate/test outputs quoted below.
- `REPO-INSPECTION`: derived from direct inspection of committed repository files.
- `UNVERIFIED`: cross-provider LIVE handoff (explicitly out of scope; hermetic Fake-to-Fake only).

## Problem (VERIFIED)

In `lib/shoestring/elves.ex` `resume_handoff/4`, the replay path returned
`{:ok, …}` success whenever the receiver run row existed — but the row is
inserted BEFORE the adapter effect (writer constraint, see the recorded
deviation in `handoff-correction.md`). A crash (or failed start) between
row insert and adapter start therefore replayed to success with the
receiver never started, and
`test/shoestring/harness/handoff_correction_test.exs` locked this masking
in ("failed-start → success with zero new calls").

Fail-on-base proof (VERIFIED against `4d2df5a`): with the fix stashed, the
four new/updated lock tests fail because base replays any present receiver
row to success with the durable-derived identity (`provider_session_id`
`nil`) and zero new adapter calls; with the fix applied, all 11 tests pass.

## Implementation (VERIFIED)

`lib/shoestring/elves.ex` only (resume/handoff region; no behavior change
to session turn logic):

- `resume_handoff/4` replay branch now delegates a present receiver row to
  `replay_stored_receiver/6`, implementing the P1 decision tree:
  1. terminal/result evidence for the new run → success-replay, zero new
     calls (preserved behavior);
  2. else a live receiver session observable via the adapter's
     `lookup_session/1` (where supported, e.g. `CodexAppServer`,
     `ClaudeHeadless`; read-only, never starts/probes/mutates session
     state) → success with that identity, zero new calls;
  3. else re-attempt the effect with the SAME handoff/run/dispatch ids
     (at-least-once with idempotent convergence: first genuine success
     wins; duplicates impossible by idempotency keys).
- `receiver_terminal?/2` counts run terminals (`run.completed` /
  `run.failed` / `run.interrupted` / `run.cancelled`) and recorded harness
  results (`harness.event_recorded` with kind `result`).
  `run.requested` deliberately does NOT count: it is appended before the
  adapter effect, so it cannot prove the effect ran.
- The re-attempt converges through `run_handoff_effect/7` (extracted tail
  of `handoff_effect/6`): idempotent `handoff.created` + `run.requested`
  appends (duplicates converge by idempotency key) plus a fresh
  `adapter.start/2`. The row insert is skipped on re-attempt — a blind
  re-insert would collide on the primary key instead of converging.
- Fake exposes no `lookup_session/1`, so Fake replays re-attempt whenever
  no terminal/result evidence exists (P3, documented in test names).

## Intended behavior change (P2, VERIFIED)

The pre-existing "failed-start → success with zero new calls" assertion is
UPDATED to the honest semantic: failed start → replay re-attempts →
success WITH exactly one new adapter call (RequestLog `1 → 2`), same run
id, and still exactly one `handoff.created` and one `run.requested`
(durable convergence). This is a behavior fix, not a lock break.

## Fail-on-base ledger (VERIFIED against 4d2df5a)

| test | base result | reason |
|---|---|---|
| failed start → re-attempt, one new effect, no duplicates | FAIL | base returns success with zero new calls, stored identity (`nil` session) |
| crash before adapter start → replay performs the effect once | FAIL | base returns success with zero logged attempts |
| replay without terminal evidence re-attempts (Fake) | FAIL | base reports success without the effect (`count` stays `1`) |
| dead receiver session → replay re-attempts | FAIL | base treats any present row as success |
| replay after terminal evidence → zero new calls | PASS | documentation: pins the preserved success path |
| live receiver session → zero new calls | PASS | documentation: passes on base too; stub mirrors `lookup_session/1` |
| P3 same-provider matrix, P5, P4, intent-first | PASS | unchanged behavior, green |

## Gate (VERIFIED)

`mix precommit` — exact command and counts recorded in the task report.

## Scope note

Touched: `lib/shoestring/elves.ex` (resume/handoff region only),
`test/shoestring/harness/handoff_correction_test.exs`, and this note.
Untouched: `elf.ex`, lease bounds, wakeups, `continuation.ex`,
`terminal_checkpoint.ex`, same-provider resume matrix. No new trajectory
event types; no new processes/timers. Live cross-provider handoff stays
explicitly UNVERIFIED.
