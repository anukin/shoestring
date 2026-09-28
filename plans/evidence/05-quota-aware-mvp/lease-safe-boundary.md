# Lease-safe boundary: terminal-only resolution (Codex + Claude sessions, Elf)

Third revision. The second revision (commit `917f2d8`, marker-gated
identity tracking with delta/reasoning-start interrupt triggers) is
superseded in full: no interrupt is ever sent for a lease stop on any
frame class, and the Elf-side open-tool / model-control tracking is
removed. This document replaces the second revision's protocol claims;
its trace citations (ordinals below) are unchanged and re-verified, but
they now motivate abolition rather than gating.

Review-recovery note: the full prior Opus 5.5 review text could not be
recovered (session history truncated to tool calls plus the verdict
tail). The six blockers below follow the brief's record: (1) successful
interrupts bypassing decline/checkpoint/suspension/wake, (2) unsafe Elf
completion boundary, (3) unreachable Claude renewal (real Claude emits
no Codex deltas), (4) race between model activity and next tool,
(5) teardown regression-test correctness, (6) evidence inaccuracies.
Each is disposed under `Blocker dispositions`.

## Behavior change (VERIFIED by the new hermetic tests)

- `CodexAppServer.Session` implements the terminal-only safe-boundary
  rule. A safe stop / safe cancel request NEVER sends `turn/interrupt` —
  not on request, delta, reasoning activity, completion, timeout, quiet,
  or anything else: no observable frame can rule out a tool start
  already in transit (committed trace: commentary completion 139
  immediately followed by command start 140; command end 141,
  bookkeeping 142–143, fileChange start 144), so any proactive interrupt
  can cut a just-started mutation. The request only pends
  (`stop_requested: :safe_boundary`), and the authoritative turn outcome
  (`turn/completed`) resolves it with no send. Open-tool tracking remains
  for status observability only; safe-stop decisions never consult it.
  Explicit immediate cancellation (no boundary option) still interrupts
  plus reaps the whole owned process group unchanged.
- `ClaudeHeadless.Session` is terminal-only likewise.
  `request_safe_stop/1` always pends and never kills — even with nothing
  in flight, since a request can interleave anywhere around a tool the
  child already started. A safe-boundary `cancel/2` pends identically
  (it is the lease-flavored cancel). Explicit immediate `cancel/2` (no
  boundary option — the user/orchestrator path) still kills the whole
  owned process group at once plus reaps it. Lease safe stop and
  explicit cancel are deliberately distinct operations; the old
  at-drain deferred kill is abolished (same race: killing on a tool END
  can cut the next tool already starting in the child). A pended stop
  resolves at the turn terminal (`completed`/`failed`) with no kill.
  Oversized-frame fail-closed (kill + transport error) is untouched: it
  is transport safety, not a lease path.
- `EventNormalizer` (Codex) no longer emits lifecycle boundary markers:
  with nothing consulting them, the `codex-app-server:boundary`
  start/end keys are removed (spend counting never saw them).
- `LeaseRenewal.preview/3` (new, dry-run, zero appends) runs the same
  gating plus fresh observe/localize/evaluate as `maybe_renew/3` and
  reports `:renewable` / `:refused`. Already-refused leases
  (`expired`, `checkpoint_required`) replay `{:ok, %{outcome: :expired,
  reason: :already_expired, events: []}}` from `maybe_renew/3` instead of
  erroring, so a repeated refusal completes the deferred decline instead
  of stalling; the `:expire` transition chains `:from` the freshly
  re-read status, and a post-projection refusal short-circuits before
  settling (this closes a projection-lag race where a stale load met an
  already-terminal row with `lease_transition_rejected`).
- The Elf runs the T2 renewal sequence on mid-turn spend through the
  preview only: a renewable verdict runs the real evaluation immediately
  (a renewal rearms epochs and suspends nothing, so budget renewals keep
  their mid-turn behavior, including multi-epoch re-loop); a refusal
  arms `lease_refusal_pending?` and appends NOTHING — no snapshot, no
  decision, no expiry markers. The full evaluation (with its markers)
  and the suspend/checkpoint/wake decision wait for the authoritative
  turn outcome (`:result` kind), so no decline artifact ever precedes the
  proof the turn stopped, regardless of tools open, interleaved events,
  or unfinished items. Leases already dead elsewhere (force-expired,
  quota-halted) keep the pre-existing bounded path: ensure checkpoint
  contents at spend boundaries plus settle on success, never suspending
  or waking there; a failed write stays unlatched for retry.
- A decline at the outcome consumes the verdict only when it classifies
  `:completed`: the run suspends with no terminal following. A
  non-completed verdict (`interrupted`, and any other class) still
  terminalizes — interruption evidence is durable and must not be
  swallowed — while the decline's suspend + wake already scheduled the
  recheck. `:error`-kind outcomes never decline and keep their failure
  terminal, as before. The quota fast path is untouched (the provider
  already halted the turn, so it re-evaluates and declines immediately).
- Manual-mode, wake, suspend, checkpoint-id, and spend-counting logic are
  untouched.

## Protocol justification (VERIFIED from the committed trace)

All ordinals below are ordinals (first column) from the committed
redacted artifact
`plans/evidence/05-quota-aware-mvp/fixtures/live-final/normalized-codex-lease-stop-final.md`
(re-verified for this revision with `awk -F'\t'`):

- Ordinal 139 (output, commentary completion) is immediately followed by
  140 (command START). Message completions therefore cannot release or
  trigger a stop: the provider routinely starts the next tool in the
  same step.
- Ordinal 141 (command END) is followed by token/rate bookkeeping
  142–143 and then 144 (fileChange START, inProgress). A stop requested,
  a drain observed, or a completion seen at 141 must not send: the next
  START is already on its way.
- Deltas precede their completion, but that headroom is irrelevant once
  sends are abolished: even a delta cannot rule out a tool START already
  in transit behind it (the request itself is a GenServer call that can
  interleave anywhere). Hence terminal-only resolution replaces the
  second revision's delta/reasoning triggers entirely, rather than
  re-gating them.
- The Claude twin needs no trace: real Claude emits no Codex deltas, so
  any delta-keyed renewal/decline is unreachable for Claude by
  construction. The outcome (`:result` kind) is provider-agnostic, so
  renewal and decline work identically for Codex and Claude shapes
  (pinned by the Claude twin tests using real normalizer shapes:
  `toolu_` start/end, text, result — no deltas).

## Safety guarantee and its exact limit

- Nothing is ever sent or killed for a lease stop: the abolished class
  (interrupt/kill racing an in-transit START) cannot occur by
  construction. Mid-turn refusal markers cannot precede the outcome
  either, because mid-turn refusals append nothing at all.
- Cost (documented, not claimed away): deadline pressure waits for the
  turn to finish — including message-only tool loops with no outcome in
  sight. Stops pend; renewals for live turns still evaluate mid-turn, so
  only the refusal suspend waits.
- Residuals (documented, not claimed away):
  - Preview then real evaluation probes twice per spend (one dry-run,
    one appending). Freshness is never reused across the two by design
    (the admitted snapshot is never reused, extended to the preview
    reading); a capacity flap between the two probes can therefore
    append mid-turn markers on the real refusal. The window is
    microseconds within one ingest, the suspend still waits for the
    outcome, and the epoch-keyed idempotency keeps markers singular.
  - A turn with no outcome event at all (stream ends or stalls with no
    `:result`/`:error`) never declines: mid-turn state only arms the
    pending flag, and supervision continues under the locked staleness
    rules. Fake legs demonstrate this: an outcome-less scenario drains
    and re-materializes without declining.
  - Background exec children remain covered by the unchanged OS backstop
    (`killpg` at turn teardown; immediate cancel proved by the reap
    tests against real owned groups, Codex and Elf level).

## Changed-file scope

- `lib/shoestring/harness/codex_app_server/session.ex` (terminal-only:
  always-pend requests, no model-activity triggers; open tools kept for
  observability)
- `lib/shoestring/harness/codex_app_server/event_normalizer.ex`
  (boundary markers removed)
- `lib/shoestring/harness/claude_headless/session.ex` (terminal-only
  safe stop / safe-boundary cancel; immediate cancel unchanged;
  pending-stop resolution at the terminal)
- `lib/shoestring/cobbler/lease_renewal.ex` (`preview/3`, already-
  expired replay, `:from`-chained expiry, post-projection refusal
  short-circuit)
- `lib/shoestring/cobbler/lease_bounds.ex` (open-tool / control
  tracking removed; identity resolver and spend counting retained)
- `lib/shoestring/elves/elf.ex` (`lease_refusal_pending?`,
  preview-gated mid-turn path, outcome decline, consume-only-completed
  verdicts, already-terminal ensure-checkpoint path, declined-run
  re-entry guard)
- Tests: `session_safe_boundary_test.exs` (rewritten for terminal-only:
  no frame class releases; outcome resolves);
  `claude_headless/session_test.exs` (safe stop / safe cancel pend with
  no kill; terminal resolves; immediate cancel still kills);
  `session_test.exs` + `lease_boundary_test.exs` (contract updates);
  `event_normalizer_test.exs` (marker removal);
  `lease_bounds_test.exs` (tracking surface removed);
  `lease_renewal_boundary_test.exs` (replay + preview zero-append pins);
  `elf_lease_loop_test.exs` (19 tests: outcome-decline shapes across
  tools/twins/unknown/nil/compound/unfinished);
  `elf_lease_reloop_test.exs` (outcome-decline + multi-epoch renewal +
  interrupted/quota twins + session-stop doubles);
  `elf_checkpoint_resume_test.exs` (outcome-decline evidence +
  preserved retry-into-recovery);
  `elf_claude_decline_quiescence_test.exs` (outcome-decline quiet
  exit / supervision).
- Explicit scope addition carried over (review-authorized):
  `test/shoestring/harness/capacity/supervision_storm_eval_test.exs`
  (teardown-leak repair + regression test, commit `238b161`) and this
  evidence file. Lib/test changes from the second revision that the
  terminal-only design supersedes are not retained.

## Tests plus pre-fix regression evidence

Proof worktrees at `1566acd` (PR base), `e675c3b` (first revision),
and `238b161` (direct parent) were built in isolation with the new test
files overlaid on the old lib (deps symlinked, no network); `mix test
--seed 0` per file. Every failure below is behavioral (the suites
compile and run on all three bases) except where `UndefinedFunctionError`
marks a new API (labeled as such):

- `elf_lease_loop_test.exs` (19 tests): 11 fail on `1566acd`, 11 fail
  on `e675c3b`, 11 fail on `238b161` — all decline-shape locks (deadline
  across command/fileChange/message/compound/unknown/nil/Claude/unfinished
  twins, in-flight exhaustion, refused renewal). On `1566acd` the lease
  markers land mid-turn with no outcome decline; on `e675c3b` the Elf
  declines at the tool END (expired before the outcome); on `238b161`
  the boundary decline suspends mid-turn and the outcome terminalizes.
  The 8 passing-on-base tests are healthy-renewal/terminal documentation.
- `elf_lease_reloop_test.exs` (10 tests): 7 fail on `1566acd`
  (multi-epoch renewal count, outcome-decline sleeps, dispatch/Claude
  session-stop twins with ordering, interrupted ordering, quiet exit),
  7 fail on `238b161` (same set). Quota, budget-renew, and deadline-stop
  twins pass on base (preserved behavior, labeled documentation
  in-file).
- `elf_checkpoint_resume_test.exs` (5 tests): `planned boundary
  decline` fails on `1566acd` in isolation and seed-0 order (the outcome
  decline terminalizes instead of suspending, so the sleep wake is never
  scheduled). Suite-order on base is sensitive for this file (a passing
  full-file run was observed under a random seed — an artifact of base's
  mid-turn decline, not of the new tests); the isolation/seed-0 result
  is the recorded proof. The retry-into-recovery, evidence-content,
  quota-poison, and terminal-twin shapes pass on base (preserved
  behavior, labeled documentation in-file).
- `elf_claude_decline_quiescence_test.exs` (4 tests): 3 fail on
  `1566acd`, each with a terminal following the suspension
  (terminal-after-suspend — the exact shape consume-only-completed
  abolishes). The working-session control passes on base
  (documentation).
- `session_safe_boundary_test.exs` + `claude_headless/session_test.exs`
  (new terminal-only halves): 15 + 2 fail on `1566acd` (proactive
  interrupt/kill on delta/completion/drain/empty-set/idle paths). The
  immediate-cancel reap proofs pass on both (documentation).
- `lease_renewal_boundary_test.exs`: the already-refused replay fails
  behaviorally on `1566acd` (old error shape); the two preview tests
  fail with `UndefinedFunctionError` (new API — documentation of the new
  surface, labeled honestly).
- Full gate (exact command `mix precommit < /dev/null`, foreground,
  per-pid state under `System.tmp_dir!()`, Elixir 1.19.5 / OTP 28),
  exit 0: `mix format --check-formatted` clean,
  `compile --warnings-as-errors` clean, 4 doctests + 1502 tests,
  0 failures, 1 skipped (6 excluded); Node 52/52; UI 7/7. (Baseline at
  `238b161` was 1510 tests; the delta is removed second-revision-only
  surface — marker/open-tool/control unit tests — plus the new
  replay/preview/pend-only pins.) No retry-until-green; one intermediate
  full run during this round showed 7 failures, all diagnosed, none
  retried away: 1 `Database busy` setup flake in `DispatcherTest`
  (same setup-INSERT signature as the preserved `917f2d8` family) plus 6
  handoff receiver regressions where outcome renewal met
  fixture-inconsistent Fake observations (account-scoped grant vs
  subscription-scoped reading, then wall-clock staleness, then the
  missing weekly window — each refused correctly by renewal, each an
  artifact of the static fixture, fixed fixture-locally with
  receiver-scoped fresh complete readings and all protocol assertions
  intact). The green run above is the single full run after the last
  edit, quoted exactly.

## Deviations and corrections

- The second revision's evidence (delta/reasoning-start triggers,
  marker-gated open sets, Elf control evidence, request-never-sends
  with model-activity release) is superseded, not amended: triggers of
  any kind cannot rule out an in-transit START, so the design resolves
  lease stops only at the turn terminal. Its trace ordinals (51→52,
  53→56, 139→140, 141→144) were re-verified and are re-cited above as
  the motivation for abolition.
- The second revision's "no request-time sends, marker-gated tracking"
  close-out and its session/Elf asymmetry discussion no longer apply;
  both layers are pend-only and neither tracks for decisions.
- Normalizer scope note: the explicit boundary markers added in
  revisions 1–2 are removed in this revision (nothing consults them).
  Spend counting is byte-identical.

## Independent gate record (FAILED on teardown leak, root-caused;
## history preserved, not erased)

- Independent gate at `917f2d8`, exact command
  `mix precommit < /dev/null` in the review worktree
  (log `/tmp/shoestring-917f2d8-independent-gate.log`), exited 2:
  4 doctests, 1509 tests, **1 failure**, 1 skipped (6 excluded);
  Node 52/52, UI 7/7. (Worktree path redacted; the original record named
  a home-directory checkout — no home paths are reproduced here.)
- The single failure is `Shoestring.Cobbler.ManualRecheckTest` "a live
  goal gets an immediate due wake keyed by operator"
  (`test/shoestring/cobbler/manual_recheck_test.exs:98`), failing in test
  SETUP (`__ex_unit_setup_1`, line 24: `create_goal!()`) with
  `Exqlite.Error Database busy` on `INSERT INTO "goals"` — the test body
  never executed.
- Root-cause record (carried over, unchanged): the storm file's teardown
  helper killed the unlinked test root and awaited only the root's DOWN.
  But the healthy `CodexMonitor` traps exits, so the root's death arrives
  as an EXIT message that waits behind the monitor's queued timer/work
  messages — each able to issue further Repo calls — while the monitor
  stays alive. Proven by the regression test added in `238b161` (alive
  immediately after root DOWN on the old helper) plus a throwaway
  diagnostic (same monitor dead ~3s later with reason `:killed`); the
  independent log independently names the storm as the lingering Repo
  client. The leak was confirmed present on base `1566acd`.
- INFERENCE (medium confidence, stated as such, unchanged): the zombie
  monitor's Repo contention produced the exact `Database busy` in
  ManualRecheck's setup INSERT. The exact busy was NOT reproduced
  deterministically, so the precise lock mechanics remain inference;
  what is VERIFIED is the leak and its elimination.
- Repair (minimal, test-file only, commit `238b161`):
  `stop_root_synchronously` snapshots every live pid in the tree BEFORE
  the kill (recursing only into `:supervisor` children), kills the root,
  and awaits EVERY DOWN until one overall deadline, raising loudly on
  timeout. No sleeps, no retries, no skips, no assertion changes, no DB
  `busy_timeout`/pool changes. Storm file 3/3 green in this round's
  gate (re-verified, unchanged coverage).
- Post-repair gate at `238b161` (independent): exit 0 — format clean,
  `compile --warnings-as-errors` clean, 4 doctests + 1510 tests,
  0 failures, 1 skipped (6 excluded); Node 52/52; UI 7/7. Preserved as
  the baseline this round builds on.
- NOT fixed (recorded unresolved, unchanged): a separate app-level
  trajectory-writer leak named by the investigator. Out of scope.

## Blocker dispositions

1. Successful interrupts bypassing decline/checkpoint/suspension/wake —
   CLOSED by construction: no lease path sends or kills, so there is no
   successful interrupt to bypass anything. The outcome decline always
   runs checkpoint → suspend → wake in that order (single function,
   idempotent keys), and the completed-verdict consumption rule keeps a
   suspended run terminal-free while interrupted/failed verdicts keep
   their terminals plus the same artifacts.
2. Unsafe Elf completion boundary — CLOSED: mid-turn spends run a
   zero-append preview; refusals defer everything to the outcome. No
   completion, delta, message, reasoning frame, deadline, or silence
   triggers renewal or decline mid-turn. Leases already dead elsewhere
   still get bounded checkpoint retries (never suspend/wake) at spend
   boundaries.
3. Unreachable Claude renewal — CLOSED: renewal/decline key only on the
   provider-agnostic `:result` outcome. Claude twin tests use authentic
   normalizer shapes (no deltas); the Claude session safe stop pends so
   the outcome always arrives unkilled.
4. Race between model activity and next tool — CLOSED by abolition (see
   trace justification): the residual class the second revision
   documented (RTT-bounded post-evidence START) no longer exists because
   nothing fires post-evidence.
5. Teardown regression-test correctness — PRESERVED: the `238b161`
   repair and its regression test are untouched by this round and green
   in this round's gate; the red proof (fails on the old helper) and the
   VERIFIED-vs-INFERENCE split above are carried over unchanged.
6. Evidence inaccuracies — CLOSED by this rewrite: wrong-file citation
   and unverified ordinals from round 1 stay corrected; round-2 claims
   are marked superseded (not silently kept); base-failure claims in
   test comments were re-verified per test with over-claims corrected
  in-file (documentation vs lock labeled per test); the home-path command
   line is redacted; gate history (red `917f2d8`, green `238b161`) is
   preserved with exact counts.

## Unresolved risks and residual limits

- Deadline pressure waits for the turn to finish (stated cost).
- Preview/real double probe with a documented microsecond TOCTOU (see
  Safety guarantee): a flap can append mid-turn markers, but never
  suspends mid-turn.
- Turns with no outcome event never decline; supervision continues
  under the locked staleness rules (demonstrated hermetically by
  outcome-less Fake scenarios draining without declining).
- `:error`-kind outcomes with a pending refusal keep their failure
  terminal without declining; recovery context survives through the
  ordinary terminal checkpoint (distinct id), not the reactive one.
- The second revision's RTT-bounded post-evidence race is gone with the
  triggers; no replacement headroom claim is made.
