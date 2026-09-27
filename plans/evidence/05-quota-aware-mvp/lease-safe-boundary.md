# Lease-safe boundary: identity-keyed open-tool tracking (Codex session + Elf)

## Behavior change (VERIFIED by the new hermetic tests)

- `CodexAppServer.Session` replaced the single-slot `in_flight_item` with an
  identity-keyed `open_tools` map (`item.id`, else command `processId`, else
  an anonymous fail-closed key cleared only at the natural terminal).
  Reasoning/thought/thinking/agentMessage/userMessage items never open
  entries and never close unrelated tools; unknown item types open entries
  until their matching completion.
- A pending safe stop / safe cancel now sends `turn/interrupt` at most once
  per turn, and only on model-control evidence (agent-message delta /
  completion, reasoning/thinking start-or-completion, turn start) with an
  empty open set — never on a tool completion alone. `turn/completed`
  resolves the pending stop with no send. Explicit immediate cancellation
  still interrupts plus reaps the whole owned group unchanged.
- The Elf folds every ingested normalized event (live and durable rebuild)
  through the new pure `LeaseBounds.track_open_tools/2` (Codex `item_id` /
  Claude `tool_use_id` / `item_id`; the `source_event_id` fallback is
  spend-dedup only and never opens an entry, so synthetic or degraded
  identity-less shapes never block) and requires an empty open set on top
  of the spend-derived boundary before renew/decline. `:output` completions
  with tools open are spend, never a boundary. Manual-mode, quota-fast-path,
  wake, suspend, and checkpoint-id logic are untouched.

## Protocol justification (REPO-INSPECTION of the committed live trace)

`fixtures/live-final/normalized-closeout-codex-lease-stop.md` shows tools
starting back-to-back with no intervening message (ordinals 42→43 command
END→START adjacent; 44→47 with only token bookkeeping between), while
commentary (57→133) routinely precedes the next tool (133→134 adjacent).
Therefore neither "completion drains the slot" nor "message after tool"
alone is a safe boundary; the fix waits for model-control evidence while
the open set is empty, so a provider-pipelined next START (already in the
pipe or milliseconds away, as in phase 19: command END → fileChange START
2 ms later) re-opens tracking before any send. The residual provider-side
race (interrupt in flight while the provider starts a genuinely new tool)
is irreducible for any proactive stop and is documented, not claimed away.
Background exec children remain covered by the unchanged OS backstop
(`killpg` at turn teardown); the provider-declared completion still drains
the boundary entry.

## Changed-file scope

- `lib/shoestring/harness/codex_app_server/session.ex` (tracking + one-shot evidence-gated send)
- `lib/shoestring/cobbler/lease_bounds.ex` (new pure `track_open_tools/2`)
- `lib/shoestring/elves/elf.ex` (`lease_open_tools` state, boundary conjunct, durable rebuild fold)
- Tests: new `test/shoestring/harness/codex_app_server/session_safe_boundary_test.exs`
  (13 tests); `session_test.exs` (2 tests updated to the new contract);
  `test/shoestring/elves/lease_boundary_test.exs` (2 tests updated to the
  new contract: armed-at-completion, released-at-evidence);
  `test/shoestring/cobbler/lease_bounds_test.exs` (+7 unit tests);
  `test/shoestring/elves/elf_lease_loop_test.exs` (+2 tests, +3 helpers).
- No scope expansion was needed; projection lag, terminal lease cleanup,
  Claude background tools, and quiet-exit buffering were not touched.

## Tests plus pre-fix regression evidence

- New session file: 13/13 pass on the fix; 12/13 fail on base `1566acd`
  (verified via `git stash push -- lib/` + `mix test`, then pop). Each
  failure is behavioural — e.g. `turn/interrupt` received while the command
  was observably open; drain-then-message sent twice; stale pending flag
  after terminal. The 13th ("no pending stop never interrupts") is the
  control and passes on both, labeled as such in-file.
- Updated `session_test.exs` contract tests (2): fail on base (interrupt
  arrives at completion), pass fixed (armed at completion, sent at
  evidence).
- New Elf loop tests (2, Codex + Claude shapes): fail on base
  (`lease.expired` lands before the tool END — decline at the message),
  pass fixed (expiry + reactive checkpoint follow the tool END).
- `track_open_tools/2` unit tests (7): fail to compile on base (new
  helper) — documentation of the pure surface, labeled honestly in-file.
- Full gate: `mix precommit < /dev/null` (foreground, per-pid state under
  `System.tmp_dir!()` = `/tmp`, Elixir 1.19.5 / OTP 28).
  Latest green run (exit 0): `mix format --check-formatted` clean,
  `compile --warnings-as-errors` clean, 4 doctests + 1492 tests with
  0 failures and 1 skipped (6 excluded, baseline was 1470/0/1),
  Node 52/52, UI 7/7.
  A second full run on the final tree (only a doc comment changed since)
  exited 2 with ONE failure: `Trajectory.AppendTest` "concurrent appends"
  (`Exqlite.Error Database busy` on `INSERT INTO goals`) — a file this
  slice never touches, and 13/13 green in isolation. Intermittent SQLite
  lock contention under parallel load (the known repo flake class), 1 of 4
  full-suite executions; reported as-is, not retried until green.
  An intermediate full run caught 3 failures honestly: 2
  `lease_boundary_test.exs` tests encoding interrupt-on-completion (updated
  to the new contract, same as the `session_test.exs` pair) and 1
  `elf_checkpoint_resume_test.exs` reactive-decline test whose synthetic
  identity-less `:command` event blocked the new Elf gate — that finding
  produced the real-identity requirement above, after which the whole gate
  went green. Nothing was retried until green; each deterministic failure
  was fixed by a code or contract-test change.

## Unresolved risks and deviations

- Residual provider-side race above (any proactive stop can in principle
  meet a genuinely new tool START); no timer/sleep/timeout was added to
  chase it, per the contract.
- Claude session drain-kill has the analogous at-drain shape but no
  observed failure; brief scopes Claude background handling out, so it was
  checked (tool-id set already correct) and left unchanged — UNVERIFIED.
- An unidentifiable tool START on the raw session (no id/pid) blocks the
  session boundary until `turn/completed` by design (fail closed; raw
  provider frames carry ids in practice). The Elf deliberately does not
  mirror that: normalized events include synthetic/degraded shapes with no
  provider identity (proven by the checkpoint-resume fixture), so
  identity-less normalized commands are instantaneous evidence there,
  mirroring spend semantics. The two layers agree on every real
  provider-shaped event.
- Deviation: none from the assigned scope. Four pre-existing tests encoding
  the old interrupt-on-completion boundary were updated (required by the
  contract), not weakened: they still assert no-early-send and now also
  assert armed-not-sent plus exactly-once release at evidence.
