# Round-2 Finding 6 — Real Content in Checkpoints and Handoff Prompts

Milestone 05, iteration 5, slice W6 (content). All factual claims below are
labeled per the evidence conventions (`VERIFIED` = proven by committed code
or exact command output in this run; `REPO-INSPECTION` = direct file
inspection; `UNVERIFIED` = not verified here).

## Problem (VERIFIED)

On the base commit (`4d2df5a`), `TerminalCheckpoint.collect/3` writes
`decisions: []` + `artifact_ids: []` unconditionally
(`lib/shoestring/elves/terminal_checkpoint.ex`), and
`Continuation.compose_handoff_prompt/2` carries only the checkpoint id,
`next_action`, decision refs, and generic session instructions
(`lib/shoestring/harness/continuation.ex`); the sole production caller
(`Elves.handoff_request/3`, `lib/shoestring/elves.ex`) passes no record.
Verified behaviourally: 8 of the 12 new/changed tests in this slice fail on
`4d2df5a` (missing sections, empty decisions, empty artifact ids — never a
compile error); the remaining 4 pass there by design and are labeled
DOCUMENTATION in the test files.

## What changed (VERIFIED)

- `lib/shoestring/elves/terminal_checkpoint.ex` (P1): `collect/3` fills
  `decisions` from the goal's recent `admission.decided` history
  (`decision_id` + `reason_code` + admission source event id, oldest first,
  at most `@max_decision_entries` = 8, exposed as
  `max_decision_entries/0`); `artifact_ids` from the run's recorded
  `harness.event_recorded` kind-`"artifact"` references, re-checked against
  goal-owned artifact rows in one query (at most `@max_artifact_ids` = 32,
  exposed as `max_artifact_ids/0`). Both degrade to `[]` honestly on empty
  history or query failure — enrichment never fails the checkpoint.
  `fallback_inputs/4` (new optional 4th `opts` arg; 3-arity callers
  unaffected) still attempts the admission history but keeps
  `artifact_ids: []` so the writer ownership pre-check cannot fail on the
  floor retry path. Module doc carries the artifact inventory (why event
  references: `artifacts` rows are goal-scoped with no run column; the Elf's
  own terminal log artifact is persisted synchronously before the
  checkpoint attempt, so it is visible; no artifact discovery pipeline is
  built in this slice).
- `lib/shoestring/harness/continuation.ex` (P2/P3):
  `compose_handoff_prompt/2` accepts additive `:checkpoint_record` (explicit
  struct or plain map) and `:repo` (self-load by the continuation's
  checkpoint id via `repo.get(CheckpointRecord, id)`). Precedence:
  explicit record > repo load > generic default. With a record, bounded
  `Completed work:` (decisions), `Failure:` (`stop_reason` +
  unresolved issues), `Constraints:` (unresolved issues), and
  `Verification:` (evidence) sections are appended inside the existing
  4000-char cap. Without either option the output is byte-identical to the
  W5 pointer-only shape (locked by test).
- Tests (hermetic — FakeHelpers/CobblerHelpers/ElfWorktreeFixture, local
  `git` only; no provider CLI, no network):
  `test/shoestring/elves/terminal_checkpoint_test.exs` (+5: decisions fill,
  decisions cap at newest 8, honest-empty decisions [DOCUMENTATION],
  artifact populate, honest-empty artifacts [DOCUMENTATION]) and
  `test/shoestring/harness/continuation_test.exs` (+7: byte-identical
  default [DOCUMENTATION], explicit-record sections, overlong truncation
  with marker, privacy sweep both directions, repo self-load,
  explicit-beats-repo precedence, unknown-id fallback [DOCUMENTATION]).
- Untouched by design (REPO-INSPECTION): `lib/shoestring/elves.ex`
  (W5-owned; the `:repo` self-load path exists so `handoff_request/3`
  needs no call-shape change), `lib/shoestring/elves/elf.ex` + lease
  bounds (W4), `RunRequest`/continuation structs (stay closed), the
  trajectory registry (no new event types), and all W5 handoff/session
  tests.

## Section composition + caps table (VERIFIED in code + tests)

| Piece | Source | Bound | Overflow |
| --- | --- | --- | --- |
| Terminal decisions | goal `admission.decided` payloads (`decision_id`, `reason_code`) + event id | newest 8, oldest first | older entries dropped (cap, not truncation) |
| Terminal artifact ids | run `harness.event_recorded` kind-`artifact` `artifact_id`s, goal-ownership re-checked | latest 32 unique | older refs dropped |
| Prompt `Completed work:` | checkpoint `decisions` items | 8 items, 800 chars | `…[+N more]` / `…[truncated]` |
| Prompt `Failure:` | checkpoint `stop_reason` + unresolved items | same section caps | same markers |
| Prompt `Constraints:` | checkpoint `unresolved_issues` items | 8 items, 800 chars | same markers |
| Prompt `Verification:` | checkpoint `evidence` items | 8 items, 800 chars | same markers |
| Whole prompt | base + sections | 4000 chars (`handoff_prompt_max_chars/0`) | `…[truncated]` (record path only; the no-record path keeps the exact W5 slice-without-marker) |
| Pre-existing (unchanged) | `next_action` 2000 chars, refs 32, history 50 | as before | as before |

Only checkpoint content fields (`decisions`, `unresolved_issues`,
`evidence`, `stop_reason`) are ever read by the new sections; the
transcript-scale key guard is covered by the privacy-sweep test
(`Security.scan_term == []`, `Contract.safe_term? == true`, required
sections present, smuggled transcript value absent).

## Fail-on-base ledger (VERIFIED — `git stash push -- lib/`, base `4d2df5a`)

8 behavioural failures, each for the right reason (pointer-only prompt
where sections were asserted; `decisions == []` where 2/8 entries were
asserted; `artifact_ids == []` where the recorded id was asserted):

- continuation: explicit-record sections, overlong truncation markers,
  privacy required-present direction, repo self-load, explicit-beats-repo.
- terminal checkpoint: decisions fill, decisions newest-8 cap,
  artifact populate.

4 DOCUMENTATION tests pass on base as labeled (byte-identical default,
unknown-id repo fallback, honest-empty decisions, honest-empty artifacts).

## Deviations from P1–P4 (VERIFIED)

- None material. P1 bound encoded as `@max_decision_entries` = 8 with a
  `max_decision_entries/0` accessor (as proposed); artifacts populated from
  recorded event references (the cheaply queryable run link per the
  inventory) with the floor-path `[]` reason documented in the module doc.
- P4 respected: no `RunRequest`/continuation struct changes, no registry
  changes, no new event types. No live runs (no budget authorized).
