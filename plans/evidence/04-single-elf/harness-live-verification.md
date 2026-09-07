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
