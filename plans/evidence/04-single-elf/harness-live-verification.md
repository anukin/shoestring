# Live harness verification: Claude and Codex

Date: 2026-09-07

This verification exercised both production provider adapters through
`Shoestring.Elves.start_run/3`. Each adapter owned its provider process group,
and each Elf used a Shoestring-managed worktree. The two explicitly authorized
provider turns were one Claude turn and one Codex turn; both completed. No
additional provider turn was used while diagnosing the Codex persistence gap.

The commands had this portable shape:

```sh
MIX_ENV=test SHOESTRING_TEST_STATE_DIR=<state-dir> \
  mix run --no-start <smoke-script> claude

MIX_ENV=test SHOESTRING_TEST_STATE_DIR=<state-dir> \
  mix run --no-start <smoke-script> codex
```

The test profile disabled background dispatch and capacity workers. This kept
the run budget limited to the named smoke turn while still exercising the real
Elf, adapter, provider transport, trajectory, worktree, terminal
classification, and teardown paths.

## Results at `1823b892a29aafaba78e9f40ddbaf7dfa4421a74`

| Assertion | Claude | Codex |
|---|---:|---:|
| Adapter start succeeded | VERIFIED | VERIFIED |
| Terminal class | `completed` (VERIFIED) | `completed` (VERIFIED) |
| Durable terminal events | 1 `run.completed` (VERIFIED) | 1 `run.completed` (VERIFIED) |
| Durable normalized events | 11 (VERIFIED) | 14 (VERIFIED) |
| Expected marker was the only worktree change | VERIFIED | VERIFIED |
| Marker bytes were exact | VERIFIED | VERIFIED |
| User source checkout stayed unchanged | VERIFIED | VERIFIED |
| Provider process group alive after terminal | false (VERIFIED) | false (VERIFIED) |
| Adapter session remained registered | false (VERIFIED) | false (VERIFIED) |

The committed summaries are
`fixtures/harness/claude-live-smoke-summary.json` and
`fixtures/harness/codex-live-smoke-summary.json`. They contain only derived
counts, classifications, and boolean assertions. Provider identifiers,
operator paths, raw output, prompts, and hidden reasoning are absent.

## Codex file-change completion gap

The Codex turn exposed one real defect: normalized ordinal 6, the completion
of the file-change item, was rejected by the trajectory safety boundary and
then offered again by each cumulative adapter poll. The run still completed
because the item start, final output, result, and terminal transition all
persisted. Calling the run fully lossless at that head would therefore be
incorrect (VERIFIED from the smoke database and warning output).

The rejection is reproducible without a provider call from the committed
`test/fixtures/codex/app_server/thread-start-workspace-write.json` fixture.
Codex supplies `changes[].kind` as an object such as `{"type":"add"}`. The
adapter retained that object. It passed the extension-local depth check, but
the same object was one level too deep after insertion into the complete
trajectory payload, which produced `invalid_payload` and the warning
`elf dropped harness event` (VERIFIED).

The adapter now normalizes this provider shape to the scalar change kind
`"add"`. A regression drives that exact nested fixture shape through the Elf
and asserts both directions: the required file-change completion is durable,
and the nested kind object is absent. The new regression failed at the pre-fix
head with 42 tests, 2 failures: the unit assertion retained the nested object,
and the through-Elf assertion found no completion event. It passes after the
fix with 42 tests, 0 failures (VERIFIED).

The normalization fix itself has hermetic verification. A second Codex live
turn after the fix is UNVERIFIED because the authorized two-turn provider
budget was exhausted by the Claude and Codex end-to-end runs.

## Hermetic gate

The final repository gate was `mix precommit`: 766 Elixir tests, 0 failures,
1 skipped (6 excluded), followed by 52 Node tests, 52 passed and 0 failed
(VERIFIED).

---

## Addendum — the post-fix Codex turn, run live (2026-09-21)

This section closes the gap the section above left open: *"A second Codex live
turn after the fix is UNVERIFIED because the authorized two-turn provider
budget was exhausted."* That turn has now been run, under explicit operator
authorization, and this addendum records what it showed.

Nothing above is re-labelled. The 2026-09-07 record stands exactly as written;
this addendum only settles the one item it left open.

### What was run

Two live Codex turns through `Shoestring.Elves.start_run/3` with the
production adapter selection (`Shoestring.Harness.CodexAppServer`,
`process_owner: :adapter`, `codex app-server --stdio`, `adapter_opts:
%{live: true}` — the same launch parameters
`Shoestring.Harness.Dispatch.ElfEffect` uses in production), each in its own
Shoestring-managed worktree over a disposable Go module, each gated on the
goal's exclusive Cobbler claim (`require_cobbler_command: true`).

The goal was a self-contained Go CLI Tic-Tac-Toe project, chosen because it
makes the provider write real files — which is exactly what the 2026-09-07
defect was about. The sender leg asked only for the core `game` package and
its tests, deliberately not the CLI entry point.

The commands had this portable shape:

```sh
MIX_ENV=test SHOESTRING_TEST_STATE_DIR=$STATE LIVE_GO_REPO=$GO_REPO \
  LIVE_LEDGER_DIR=$LEDGER mix run <driver> leg1 codex
```

The test profile disabled background dispatch, wakeup and handoff
reconcilers and the capacity monitors, so the run budget stayed limited to
the named turns while still exercising the real Elf, adapter, provider
transport, trajectory, worktree, terminal classification and teardown.

### Results

| Assertion | Turn A | Turn B |
|---|---:|---:|
| Adapter start succeeded | VERIFIED | VERIFIED |
| Terminal class | `completed` (VERIFIED) | `completed` (VERIFIED) |
| Durable terminal events | 1 `run.completed` (VERIFIED) | 1 `run.completed` (VERIFIED) |
| Durable normalized events | 345 (VERIFIED) | 374 (VERIFIED) |
| Normalized ordinals | 1–345, 0 gaps, 0 duplicates (VERIFIED) | 1–374, 0 gaps, 0 duplicates (VERIFIED) |
| File-change **completion** durable | VERIFIED | VERIFIED |
| `changes[].kind` is the scalar kind | VERIFIED | VERIFIED |
| `go test ./...` in the worktree | exit 0 (VERIFIED) | exit 0 (VERIFIED) |
| Expected files were the only worktree change | VERIFIED | VERIFIED |
| User source checkout stayed unchanged | VERIFIED | VERIFIED |

Wall clock: 162 342 ms (turn A) and 166 444 ms (turn B).

### The 2026-09-07 defect, measured against real provider output

The original gap was specific: normalized ordinal 6 — the *completion* of the
file-change item — was rejected by the trajectory safety boundary and then
re-offered by each cumulative adapter poll, because Codex supplies
`changes[].kind` as an object (`{"type":"add"}`) that was one level too deep
once inserted into the complete trajectory payload. The adapter now
normalizes that to the scalar kind.

Both live turns confirm the fix against real provider output (VERIFIED from
the run databases):

- the `fileChange` tool item's **completion** is durably recorded, carrying
  `codex-app-server:status: "completed"` — this is the event that was
  previously dropped;
- every `changes[]` entry carries `"kind": "add"`, a scalar — the nested
  object shape is absent;
- the normalized ordinal sequence is contiguous with no duplicates, so no
  ordinal was dropped and re-offered. On the pre-fix head the symptom was
  precisely a missing ordinal accompanied by a repeated `elf dropped harness
  event` warning.

Calling the 2026-09-07 Codex run "not fully lossless" was correct, and the
loss is gone at this head. **The hermetic regression continues to be what
locks the behaviour; these live turns are the confirmation that the shape it
locks is the shape the real provider emits** (the fixture was captured from a
real run, but a fixture cannot prove the provider still emits that shape).

### Redaction

Provider-generated identifiers (Codex `thread_id` / `turn_id` / `item_id`,
Claude `session_id`), OS process-group ids, operator paths, raw provider
output and prompts are not reproduced here. Where an identifier's *shape*
matters it is described, not quoted. The committed summaries under
`fixtures/harness/` carry derived counts, classifications and boolean
assertions only.

### What this addendum does not claim

- It does not re-verify the 2026-09-07 Claude turn; that record is unchanged.
- It makes no claim about provider behaviour beyond these two turns.
- The cross-provider and cancellation legs run in the same session are
  recorded under iteration 5
  (`plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md`), not
  here.
