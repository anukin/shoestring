# Lease-safe boundary: identity-keyed open-tool tracking (Codex session + Elf)

Second revision (review blockers B1–B5, N1–N4). The first revision is
commit `e675c3b`; this document describes the delta on top of it and
replaces the earlier protocol claims, which cited a nonexistent fixture
and unverified ordinals (see `Deviations and corrections`).

## Behavior change (VERIFIED by the new hermetic tests)

- `CodexAppServer.Session` tracks open tools by identity (shared
  blank-safe resolver `LeaseBounds.tool_identity/1`: provider id, else
  command `processId`, else an anonymous fail-closed key cleared only at
  the natural terminal). A safe stop / safe cancel request NEVER sends
  synchronously — it always pends, because a request can interleave
  between the provider emitting a tool completion and emitting the next
  tool start, and no request-time state can rule out a start already in
  transit. The pended interrupt fires at most once per turn, and only in
  a frame handler for streaming agent-message deltas or
  reasoning/thinking/thought starts observed while the open set is empty.
  Completions of any kind never release the stop; the natural terminal
  resolves it with no send. Explicit immediate cancellation still
  interrupts plus reaps the whole owned group unchanged.
- `EventNormalizer` (Codex) records an explicit `codex-app-server:boundary`
  start/end marker on command, file-change, and unknown item shapes, taken
  from the raw RPC method — never inferred from status spelling. The
  marker is namespaced and invisible to spend counting (verified: no spend
  test changed behavior). Unknown shapes (e.g. `mcpToolCall`) stay
  `:lifecycle` (zero spend impact) but now carry markers plus identity and
  the recorded type.
- The Elf folds every ingested normalized event (live and durable
  rebuild) through `LeaseBounds.track_open_tools/2` (marker-gated;
  genuine starts without identity open a sentinel that fails closed until
  a turn outcome clears it; marker-less synthetic shapes never open) and
  `LeaseBounds.track_control/2` (`{tools_seen?, model_control?}`: tool
  lifecycle invalidates, deltas establish, completions establish only on a
  turn with no tool activity yet, message starts invalidate, turn outcomes
  reset). Renewal/decline additionally requires an empty open set plus
  demonstrated control on top of the spend-derived boundary. Manual-mode,
  quota-fast-path, wake, suspend, and checkpoint-id logic are untouched.

## Protocol justification (VERIFIED from the committed trace)

All ordinals below are from the committed redacted artifact
`plans/evidence/05-quota-aware-mvp/fixtures/live-final/normalized-codex-lease-stop-final.md`
(the earlier revision cited a nonexistent file and wrong ordinals):

- Command START 140 is immediately preceded by commentary completion 139;
  command START 52 by commentary completion 51. Message completions
  therefore cannot release a stop: the provider routinely starts the next
  tool in the same step.
- Command END 141 is followed by token/rate bookkeeping 142–143 and then
  fileChange START 144 (still open when the turn is interrupted at 146).
  A stop requested, or a drain observed, at 141 must not send: the next
  START is already on its way.
- Deltas (46–50 before completion 51; 63–138 before completion 139) always
  precede their message completion, and no tool START ever directly
  follows a delta in the trace. A send keyed on a delta therefore fires
  while the provider must still emit at least the completion before any
  tool START can follow — the strongest trigger the trace substantiates.
- Reasoning-frame positions are NOT in any committed artifact
  (reasoning is dropped from normalized traces; raw timing lives only in
  non-committed provider logs, which are not evidence here). Keeping
  reasoning starts as triggers rests on the review suggestion plus the
  same residual bound as deltas, and is labeled accordingly — not as a
  verified headroom claim.
- No committed artifact distinguishes commentary-phase from
  final-answer-phase completions (every observed agentMessage in the trace
  is phase `commentary`; `final_answer` is only the normalizer's default
  for a missing phase). All completions are therefore excluded as
  triggers; no such distinction is invented.

## Safety guarantee and its exact limit

- Single-pipe FIFO ordering plus sequential handling proves a
  frame-triggered send can never race a tool START the provider emitted
  before the triggering evidence: that START's frame arrives first and
  re-opens the set (or, at the Elf, records tool activity), suppressing
  the send. This eliminates the observed failure classes (interrupt with
  an observably running command; request/send at 141 racing START 144).
- Request-time sends are abolished (not gated): GenServer-call/pipe
  interleaving cannot cause a blind send at all. Cost: an idle stop waits
  for the next model-activity frame instead of interrupting instantly;
  the terminal always resolves liveness, as the contract permits.
- Residual (documented, not claimed away): the provider may emit a NEW
  tool START after the triggering evidence but before processing the
  interrupt (RTT-bounded). It is irreducible for any interrupt-based
  design over this transport, minimized here by triggering only on frames
  that provably require further provider emissions first. If that window
  is unacceptable for a given product decision, the conservative
  alternative is terminal-only resolution (already the fallback); the two
  cannot be combined without reintroducing the race. No timers or sleeps
  were added.
- Background exec children remain covered by the unchanged OS backstop
  (`killpg` at turn teardown; immediate cancel proved by the new reap
  test against a real owned group).

## Changed-file scope

- `lib/shoestring/harness/codex_app_server/session.ex` (always-pend
  requests; delta/reasoning-start triggers; shared identity resolver)
- `lib/shoestring/harness/codex_app_server/event_normalizer.ex`
  (explicit boundary markers; authorized scope expansion)
- `lib/shoestring/cobbler/lease_bounds.ex` (`tool_identity/1`,
  marker-based `track_open_tools/2`, `track_control/2`; spend untouched)
- `lib/shoestring/elves/elf.ex` (`lease_tool_seen?` /
  `lease_model_control?` state, boundary conjunct, durable rebuild fold)
- Tests: `session_safe_boundary_test.exs` (16 tests incl. the Elf-driven
  141→144 test via `LeaseBoundary.enforce` and the reap proof);
  `session_test.exs` + `lease_boundary_test.exs` (contract updates);
  `event_normalizer_test.exs` (+3 marker tests);
  `lease_bounds_test.exs` (rewritten gate surface: identity, markers,
  sentinel, terminal-clear, control);
  `elf_lease_loop_test.exs` (marked helpers; reworked deadline/message/
  Claude tests; new compound and unknown-tool tests).
- Untouched as required: projection lag, terminal lease cleanup, Claude
  background tools, quiet-exit buffering, spend counting.

## Tests plus pre-fix regression evidence

Base `1566acd` (single slot) and `e675c3b` (first revision) were each
verified by stashing `lib/` (tests use only pre-existing APIs, so every
failure below is behavioral, not a missing helper):

- New session file (16 tests): 14 fail on `1566acd`, 4 fail on `e675c3b`.
  The 4 (`elf deadline stop`, `idle stop pends`, `message completion with
  empty set`, `file change plus reasoning` second half) are the exact
  second-revision deltas: request-never-sends and completions-never-
  release. The 2 passing on both (`immediate cancel reaps`, `without a
  pending stop`) are labeled documentation in-file.
- Updated `session_test.exs` (3) and `lease_boundary_test.exs` (2): fail
  on `1566acd`; the delta-release halves pass on `e675c3b`, the idle half
  fails there too.
- New/updated Elf loop tests (5 deadline shapes): all 5 fail on both
  bases — on `1566acd` the Elf declines at the message or START, on
  `e675c3b` at the tool END (expired lands before the delta).
- New normalizer marker tests (3): fail behaviorally on both bases (no
  marker key emitted).
- `track_open_tools/2`, `track_control/2`, `tool_identity/1` unit tests:
  fail to compile on both bases (new helpers) — documentation of the pure
  surface, labeled honestly in-file (N4).
- Full gate: `mix precommit < /dev/null` (foreground, per-pid state under
  `System.tmp_dir!()` = `/tmp`, Elixir 1.19.5 / OTP 28), exit 0:
  `mix format --check-formatted` clean, `compile --warnings-as-errors`
  clean, 4 doctests + 1509 tests with 0 failures and 1 skipped
  (6 excluded; round-1 baseline was 1492/0/1), Node 52/52, UI 7/7.
  Gate history is preserved, not erased: the round-1 run caught 3
  deterministic failures (2 interrupt-on-completion tests, 1
  checkpoint-resume identity issue that produced the real-identity rule);
  one later full run showed a single intermittent SQLite-busy flake in
  untouched `Trajectory.AppendTest` (13/13 in isolation), reported
  as-is. During this revision one intermediate full run exposed a genuine
  design bug (completions-after-tools wiped delta-established control, so
  spend and control could never coincide — expired==0); fixed by making
  tool lifecycle the only clearer, with a unit test pinning it.

## Deviations and corrections (B5)

- The round-1 evidence cited `fixtures/live-final/
  normalized-closeout-codex-lease-stop.md` (nonexistent) with ordinals
  42→43, 57→133, 133→134 (unverified). Corrected above to the committed
  `normalized-codex-lease-stop-final.md` with ordinals 51→52, 53→56,
  139→140, 141→144. Factual claims now quote only that artifact.
- The round-1 "Deviation: none" was inaccurate. Two deliberate design
  corrections since: (a) identity-less Elf tracking went
  block-everything → block-nothing → marker-gated (genuine marked starts
  without identity fail closed via sentinel; unmarked synthetic shapes
  never open — the checkpoint-resume fixture justifies only the latter);
  (b) request-time sends were abolished rather than memory-gated, because
  no request-time observation can rule out an in-transit START — a
  stricter response to B1 than the suggested mechanism, with the idle-stop
  latency tradeoff stated above.
- Session/Elf asymmetry is deliberate and documented: the raw session
  tracks every started shape (anonymous fail-closed keys) because raw
  frames always carry explicit methods; the Elf tracks only marked,
  identified lifecycle because normalized events include synthetic shapes.
  The layers agree on every real provider-shaped event; the residual
  class is identical (post-evidence provider decisions).

## Independent gate record (FAILED on environment flake, preserved)

- Independent gate at `917f2d8`, exact command
  `cd /Users/anukin/projects/shoestring-fix-lease-safe-boundary && mix precommit < /dev/null`
  (log `/tmp/shoestring-917f2d8-independent-gate.log`), exited 2:
  4 doctests, 1509 tests, **1 failure**, 1 skipped (6 excluded);
  Node 52/52, UI 7/7.
- The single failure is `Shoestring.Cobbler.ManualRecheckTest` "a live
  goal gets an immediate due wake keyed by operator"
  (`test/shoestring/cobbler/manual_recheck_test.exs:98`), failing in test
  SETUP (`__ex_unit_setup_1`, line 24: `create_goal!()`) with
  `Exqlite.Error Database busy` on `INSERT INTO "goals"` — the test body
  never executed.
- Causal finding (environment contention, not a regression):
  (1) the failing statement is a plain setup-time goal INSERT through a
  code path this slice never touches — the commit contains zero DB-layer
  files (no repo, schema, DataCase/sandbox, `create_goal!`, `Wakeups`,
  storm-test, or ManualRecheck changes);
  (2) the same log, at the same timestamp, shows the concurrently running
  `supervision_storm_eval_test` crash-loop test with async DB owner
  disconnections (`:healthy_codex_storm` client holding connections from
  exited owners) under `max_cases: 40` against file-based SQLite —
  writer-lock contention;
  (3) the identical signature (`Database busy` on `INSERT INTO goals`)
  was already observed in `Trajectory.AppendTest` during this slice's own
  gate history, then green in isolation and green on the next full run;
  (4) targeted hermetic rerun here: `mix test
  test/shoestring/cobbler/manual_recheck_test.exs < /dev/null` → 7 tests,
  0 failures in 0.1s.
- No code change was made for this: the failure is in test setup, so no
  assertion change could address it, and serializing the DB suite or
  adding retries would be broad test-infra refactoring outside the
  authorized scope (and prohibited by the standing contract). The full
  gate was deliberately NOT re-run for green. Blocker status: unrelated
  environment flake, reported with evidence; corrective action, if
  wanted,   belongs to test-infrastructure ownership (SQLite contention
  under parallel load), not this slice.

## Unresolved risks and residual limits

- The RTT-bounded post-evidence race above; terminal-only resolution is
  the stated conservative alternative, with the lease-responsiveness cost
  named (message-less tool loops defer stops to the turn end).
- Claude session drain-kill keeps its at-drain shape (no observed
  failure; out of scope) — UNVERIFIED. Claude Elf declines after tools
  now wait for deltas that Claude never emits, i.e. effectively for the
  turn outcome; one-shot Claude turns end promptly so this is bounded,
  but it is a responsiveness change stated here, not hidden.
- Long-lived plan/non-mutating provider items, if ever emitted as
  unknown lifecycle shapes, conservatively delay the Elf boundary to the
  terminal (accepted over-conservatism; no such shape is in any committed
  artifact).
- Unknown command statuses (e.g. `declined`): closing follows the
  explicit end marker independent of status spelling (unit-pinned with a
  hypothetical shape, labeled as such); no provider evidence for such
  statuses is claimed.
