# Lease-safe boundary: terminal-only resolution with outcome-kind settlement

Fourth revision (third Opus review, verdict FAIL on `24d059e`). The
third revision's completed-outcome suspends (decline consuming the
verdict, quiet exits without terminals) is superseded: a confirmed
completed outcome remains completed. Suspend/wake now happens ONLY for
early-stop outcomes (interrupted turns, quota halts). This document
replaces the third revision's outcome-consumption and quiet-exit claims;
its trace citations are unchanged and re-verified.

Review-recovery note: the full prior Opus review text could not be
recovered (session history truncated); the four blockers below follow
the brief's record (B1 completed-consumption/continuation, B2 outcome
re-renewal + unread pending flag, B3 mid-turn refusal appends/double
probe/already-dead settlement, B4 storm/evidence). Each is disposed
under `Blocker dispositions`.

## Behavior change (VERIFIED by the hermetic tests)

- `CodexAppServer.Session` and `ClaudeHeadless.Session` implement the
  terminal-only safe-boundary rule (unchanged from the prior round, all
  session tests still green): a safe stop / safe-boundary cancel request
  NEVER sends or kills — not on request, delta, reasoning activity,
  completion, timeout, quiet, or anything else. The request only pends
  and the turn terminal resolves it. Explicit immediate cancellation
  (no boundary option) still interrupts (Codex) / kills plus reaps the
  whole owned process group (both providers) unchanged. Commit
  `normalized-codex-lease-stop-final.md` ordinals re-verified with
  `awk -F'\t'`: 139 (commentary completion) → 140 (command START); 141
  (command END), bookkeeping 142–143 → 144 (fileChange START). The Claude
  twin needs no trace: real Claude emits no Codex deltas, and renewal /
  decline key only on the provider-agnostic `:result` outcome.
- `LeaseRenewal.renew_only/3` (new; the `preview/3` dry-run is removed)
  is the single atomic admit-only evaluation for mid-turn spends:
  exactly ONE fresh observe/evaluate cycle, appended if and only if
  admitted (same epoch-keyed idempotency as the full path). On refusal
  it appends NOTHING — no snapshot, no decision, no markers — and
  returns `{:ok, %{verdict: :refused}}`. One evaluation per trigger
  means no preview/real double probe and no TOCTOU between two readings.
  Already-refused leases (`expired`, `checkpoint_required`) still replay
  `{:ok, %{outcome: :expired, reason: :already_expired, events: []}}`
  from `maybe_renew/3`; the `:expire` transition chains `:from` the
  freshly re-read status through an explicit finite status→atom mapping
  (no `String.to_atom/1` on database content), with a post-projection
  refusal short-circuit.
- The Elf runs `renew_only/3` on mid-turn spends (a renewal appends and
  rearms, preserving multi-epoch re-loop; a refusal arms
  `lease_refusal_pending?` and appends nothing) and the full
  `maybe_renew/3` at the turn outcome — but only with undecided
  business: a pending refusal, or spends since the last real evaluation
  (`lease_unjudged_spend?`, set on every spend advance, cleared by every
  completed evaluation and re-arm). An outcome with nothing new to judge
  skips instead of minting a duplicate epoch. The removed
  `output_event("work", evt-out-1)` is restored in the deadline-renew
  test with an exactly-one-renewal ordering pin, plus a dedicated
  distinct-snapshot gate test (verified by mutation: bypassing the gate
  yields 2 renewals).
- At the outcome, a refusal settles per the outcome kind: a completed
  (failed/cancelled) turn keeps its terminal with the expiry markers
  and the ordinary terminal checkpoint — NO suspension, NO wake, NO
  reactive checkpoint, NO continuation (resuming a completed run
  errors, so a wake could never usefully fire). Only an interrupted
  turn (early stop proven) runs `decline_lease/2` (reactive contents,
  `run.pausing`/`run.suspended`, durable sleep wake, safe-stop request)
  and keeps its interrupted terminal. `:error`-kind outcomes never
  decline. Every verdict terminalizes — nothing is swallowed into a
  suspension — and the terminal path now also releases adapter-owned
  sessions (`release_adapter/1`); the quiet-exit (no-terminal) path and
  its liveness machinery are removed as unreachable. The quota fast
  path is untouched (provider already halted: immediate re-evaluate,
  decline plus terminal on refusal).
- Dead latches removed with the redesign: `lease_settled?`,
  `lease_declined?`, `settle_on_checkpoint/1`, the mid-turn
  ensure-checkpoint path, and the Elf-side open-tool / model-control
  tracking (already gone). `lease_checkpointed?` is RETAINED — it is
  set by the reactive checkpoint path and feeds the terminal
  checkpoint's interrupted stop-reason suffix. Session-side open-tool maps are
  RETAINED for status observability only — nothing consults them for
  decisions (stated in the moduledocs; no consumers exist outside the
  two session modules) — reported here per the review rather than
  removed, to keep this round's diff focused on behavior.
- Stop documentation/UI text says turn end, not boundary:
  `Elves.request_stop/1` doc and the run-show flash
  ("Safe stop requested; resolves at turn end."). Adapter `cancel/2`
  docs (Codex, Claude, both session modules) describe pend-only safe
  variants vs immediate explicit cancel.
- Untouched as required: spend counting (T2), due markers, quota path,
  wake/resume/dispatch semantics, spend-affecting normalizer output
  (`event_normalizer.ex` has zero net difference from the overall base
  and is NOT in scope), Fake fixtures (handoff receiver setups restored
  byte-identical to base — the refused-capacity handoff runs below are
  the required regression).

## Runs, turns, and what the outcome proves (no guessing)

Provider sessions can observe multiple turns per run (`turn/started`
resets per-turn latches in the Codex session). The Elf does not track
turns: every `:result`-kind normalized event runs the outcome rule, and
every decline now pairs with a terminal in the same `after_ingest/3`
(the run always ends with its decline). No run can therefore outlive
its decline, and continuations are always new runs via wake dispatch —
there is no multi-turn staleness by construction. The outcome proves
the turn stopped because the provider emitted its terminal frame for
it; Fake legs model one turn per run, and the rule is identical for
multi-turn streams (each outcome judges only undecided business).

## Changed-file scope (net vs overall base `1566acd`)

- `lib/shoestring/harness/codex_app_server/session.ex` (terminal-only
  session; open tools kept for observability)
- `lib/shoestring/harness/claude_headless/session.ex` (terminal-only
  safe stop / safe-boundary cancel; immediate cancel unchanged)
- `lib/shoestring/harness/codex_app_server.ex`,
  `lib/shoestring/harness/claude_headless.ex` (cancel-doc truth)
- `lib/shoestring/cobbler/lease_renewal.ex` (`renew_only/3`,
  already-expired replay, `:from`-chained expiry with explicit status
  mapping, post-projection short-circuit)
- `lib/shoestring/cobbler/lease_bounds.ex` (`tool_identity/1` resolver
  only; spend counting byte-identical)
- `lib/shoestring/elves/lease_boundary.ex` (pend-only wording)
- `lib/shoestring/elves/elf.ex` (outcome gating, kind-split refusal
  settlement, always-terminalize verdicts, dead-latch/quiet-exit
  removal, adapter release on the terminal path)
- `lib/shoestring/elves.ex` (`request_stop` doc truth)
- `lib/shoestring_web/live/run_show_live.ex` (flash truth)
- Tests: `session_safe_boundary_test.exs`, `claude_headless/
  session_test.exs`, `session_test.exs`, `lease_boundary_test.exs`,
  `event_normalizer_test.exs`, `lease_bounds_test.exs` (carried over,
  green); `lease_renewal_boundary_test.exs` (replay + renew-only pins);
  `elf_lease_loop_test.exs` (21 tests: completed-terminal shapes,
  restored deadline event, exactly-once gate test, flap atomicity
  test, unfinished-tool terminal evidence);
  `elf_lease_reloop_test.exs` (multi-epoch renewal, interrupted
  session-stop twins, interrupted restart, quota, budget/deadline
  documentation); `elf_checkpoint_resume_test.exs` (already-dead
  completed/interrupted twins, terminal evidence contents);
  `elf_claude_decline_quiescence_test.exs` (interrupted exit hygiene,
  release/reap proofs, pending-supervision control);
  `supervision_storm_eval_test.exs` (deterministic teardown rewrite,
  see below).
- Explicitly out of scope (verified zero net diff vs `1566acd`):
  `event_normalizer.ex`, handoff worker/crash-window fixtures, Fake
  scenario support.

## Tests plus pre-fix regression evidence

Verification label for this whole section: every count below is
implementer-verified (the implementer ran the commands and read the
logs) and NOT independently verified — the reviewer ran no tests, and
the orchestrator gate verified the suite is green on-tree, not these
per-base failure claims. The `/tmp` proof worktrees and logs exist as
named; their contents were not independently inspected.

Proof worktrees at `1566acd` (PR base), `e675c3b` (first revision),
and `238b161` (direct parent) were built in isolation with the final
test files overlaid on the old lib (deps symlinked, no network) and are
PRESERVED with their logs (`/tmp/opencode/proof2-*`, plus
`/tmp/opencode/proof-storm-prefix`); `mix test --seed 0` per file.
This round adds the same isolation proof against its own base
`24d059e` (`/tmp/opencode/proof-24d059e-prefix` with
`/tmp/opencode/proof-24d059e-{loop,rest,storm}.log`), itemized
immediately below. Every failure below is behavioral (the suites
compile and run on all four bases) except where `UndefinedFunctionError`
marks a new API (labeled as such, never as regression evidence):

- `elf_lease_loop_test.exs` (21 tests): 12 fail on `1566acd`, 11 on
  `e675c3b`, 12 on `238b161` — all completed-terminal shapes (expiry
  after the outcome, terminal follows markers, no suspend/wake), the
  unfinished-tool terminal evidence, the flap atomicity counts/ordering,
  and the unprojected-lease enforcement. Healthy-renewal, spend-count,
  quota, no-lease, and lifecycle-noise tests pass on base
  (documentation). The exactly-once deadline test passes on all bases
  (mid-turn renewal, no outcome re-evaluation there); its lock is the
  distinct-snapshot gate test, verified by mutation on-tree (gate
  bypassed → 2 renewals; gate restored → 1).
- `elf_lease_reloop_test.exs` (10 tests): 6 fail on `1566acd`
  (multi-epoch count, outcome-terminal sleeps, interrupted twins with
  ordering, interrupted restart ordering, quiet-exit terminal), 6 on
  `238b161` (same set plus the budget-Claude twin, whose control gate
  blocks there — matching its in-file LOCK note). Quota, budget-renew,
  and deadline-stop twins pass on base (preserved behavior, labeled
  documentation in-file).
- `elf_checkpoint_resume_test.exs` (6 tests): 4 fail on `1566acd`
  (already-dead completed: reactive checkpoint appears mid-turn there;
  already-dead interrupted: no safe-stop request there; both evidence
  tests: suspension appears there). Quota-poison and terminal twins
  pass on base (preserved behavior, labeled documentation).
- `elf_claude_decline_quiescence_test.exs` (4 tests): 3 fail on
  `1566acd` (decline artifacts precede the outcome there). The
  pending-supervision control passes on base (documentation).
- `session_safe_boundary_test.exs` + `claude_headless/session_test.exs`
  (27 tests combined): 17 fail on `1566acd` (proactive interrupt/kill
  on delta/completion/drain/empty-set/idle paths). Immediate-cancel
  reap proofs pass on both (documentation).
- `lease_renewal_boundary_test.exs`: the already-refused replay fails
  behaviorally on `1566acd` (old error shape); the two `renew_only`
  tests fail with `UndefinedFunctionError` (new API — documentation of
  the new surface, labeled honestly, never counted as regression
  evidence).
- Handoff worker/crash-window with DEFAULT fixtures (restored
  byte-identical to base): green on-tree (23 tests) with
  terminal-completed despite the mismatch/stale/single-window refusal
  — the required refused-capacity handoff regression. No fixture
  changes were needed or made.
- Pre-fix proofs against THIS round's base `24d059e` (the commit Opus
  failed): proof worktree `/tmp/opencode/proof-24d059e-prefix`
  (detached HEAD `24d059e`, deps symlinked read-only, the six final
  test files overlaid — `test/support` is byte-identical, zero diff —
  never committed there), `mix test --seed 0` per file:
  - `elf_lease_loop_test.exs`: 21 tests, **14 behavioral failures**
    (log `/tmp/opencode/proof-24d059e-loop.log`). #1 is B2 exactly
    (3 probes vs exactly 1 — the outcome re-evaluates after the
    mid-turn renewal); #2 is B2 exactly (2 `lease.renewal_due`
    markers vs 1); #3–#14 are B1 exactly (no `{:elf_terminal,
    completed}` within 15 s — the completed outcome suspends instead
    of terminalizing). Zero compile/new-API failures in this file.
  - `elf_lease_reloop_test.exs` + `elf_checkpoint_resume_test.exs` +
    `elf_claude_decline_quiescence_test.exs` +
    `lease_renewal_boundary_test.exs`: 28 tests, **9 failures** (log
    `/tmp/opencode/proof-24d059e-rest.log`). The two `renew_only`
    tests fail with `UndefinedFunctionError` (new API — documentation
    of the new surface, never regression evidence). Behavioral: the
    already-dead completed twin finds a mid-turn reactive checkpoint
    (1 vs 0 — B3); the already-dead interrupted twin sees no
    safe-stop request at the outcome (B3/B1); both completed-evidence
    tests see no completed terminal (B1); the reloop second-exhaustion
    test probes 4 times vs exactly 2 (preview+real double probe —
    B2/B3); the reloop exhausted-completes and completed-no-session
    tests see no completed terminal (B1). The 4 quiescence tests pass
    on base (documentation, labeled in-file).
  - `supervision_storm_eval_test.exs`: 4/4 green on BOTH base and tree
    (log `/tmp/opencode/proof-24d059e-storm.log`) — by design: the
    teardown helpers are self-contained, and the pre-fix-insufficiency
    test passes everywhere because it demonstrates the old helper
    leaves the detached member alive.
- Full gate (exact command `mix precommit < /dev/null`, foreground,
  per-pid state under `System.tmp_dir!()`, Elixir 1.19.5 / OTP 28):
  exit 0 — `compile --warnings-as-errors` clean, format clean, 4
  doctests + 1506 tests with 0 failures, 1 skipped (6 `:live`
  excluded); Node pass 52 / fail 0; UI tests 7 / pass 7 / fail 0.
  Complete log `/tmp/opencode/precommit-lease-boundary-finish-final2.log`
  (two earlier full runs with identical counts preserved at
  `/tmp/opencode/precommit-lease-boundary-finish-final.log` and
  `/tmp/opencode/precommit-lease-boundary-finish.log`).
  No retry-until-green; a single full run after the last edit, quoted
  exactly.

## Independent gate record (FAILED on teardown leak;
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
- Teardown-leak record (carried over, unchanged): the storm file's
  teardown helper killed the unlinked test root and awaited only the
  root's DOWN. Code reasoning only (REPO-INSPECTION, not a runtime
  proof): the healthy `CodexMonitor` sets `Process.flag(:trap_exit,
  true)` in `init/1` and has a catch-all `handle_info(_other, ...)`
  clause that keeps its state. NOT established: that a parent's EXIT
  ever reached that clause and was swallowed there — OTP itself handles
  a parent EXIT inside gen_server after already-queued mailbox messages,
  and the monitor's direct parent is the capacity supervisor, not the
  test root. What is VERIFIED: a Repo-touching monitor was observed
  alive after root teardown in diagnosis, and dead ~3s later; the
  independent log independently names the storm as the lingering Repo
  client; the leak was confirmed present on base `1566acd` — not
  re-verified by this slice (that confirmation predates it and was not
  re-run here). What remains INFERENCE (medium confidence, stated
  as such): that the zombie's Repo contention produced the exact
  `Database busy` in ManualRecheck's setup INSERT (observed once, in
  that run; the precise lock mechanics were never reproduced
  deterministically, and the SQLite linkage remains inference).
  Earlier wording that implied the SQLite cause was established, or
  that the catch-all mechanism was verified rather than reasoned
  about, is corrected here.
- Repair and its deterministic rewrite: the `238b161` repair (snapshot
  every tree pid pre-kill, kill root, await every DOWN) is superseded in
  this round by a stronger helper (kill the root, then kill every
  snapshot pid directly — idempotent for the already-dying, required
  for members detached from the root — then await every DOWN until one
  overall deadline, default 10 s, deliberately distinct from the 5 s
  per-child shutdown budgets). The teardown regression is rebuilt
  deterministically with controlled processes: a self-unlinking parked
  Repo-capable worker models the observed outliving (survival
  structural, death after observed DOWN monotonic — no timing anywhere,
  no sleeps/retries/polling, no `Process.alive?` synchronization).
  Proof (preserved worktree `/tmp/opencode/proof-storm-prefix`, log
  `/tmp/opencode/proof-storm-prefix-red.log`): the new test fails on
  the pre-fix helper semantics (detached member observably alive) and
  passes on the fixed helper. The old scheduling-race characterization
  is retired.
- Post-repair gate at `238b161` (independent): exit 0 — format clean,
  `compile --warnings-as-errors` clean, 4 doctests + 1510 tests,
  0 failures, 1 skipped (6 excluded); Node 52/52; UI 7/7. Preserved as
  the baseline this round builds on.
- During this round one intermediate full run showed 7 failures, all
  diagnosed, none retried away: 1 `Database busy` setup failure in
  `DispatcherTest` (exact run: the round-2 full gate in this worktree,
  1502 tests, `INSERT INTO "goals"` in `__ex_unit_setup_1` — same
  signature as the `917f2d8` family; occurrence 1 in that run,
  0 in the quoted green run below; no denominator beyond those two runs
  is claimed) plus 6 handoff receiver regressions from outcome renewal
  meeting the default Fake observations (scope mismatch, wall-clock
  staleness, missing weekly window — each refused correctly by
  renewal). Per the required behavior the handoff tests now pass with
  DEFAULT fixtures (terminal-completed despite refusal, no
  suspension/wake): the fixtures were restored byte-identical to base
  and no fixture change was needed or made.
- NOT fixed here (recorded unresolved, unchanged): a separate app-level
  trajectory-writer leak named by the investigator. Out of scope.

## Blocker dispositions

1. Completed-consumption/continuation — CLOSED: completed (failed/
   cancelled) outcomes terminalize with expiry markers plus the
   ordinary terminal checkpoint; no suspend, wake, reactive checkpoint,
   or continuation (a wake on a completed run would error
   `unexpected_run_state`, verified in `Wakeups.resume_run/2`).
   Suspend/wake happens ONLY for interrupted outcomes (early stop
   proven) and the quota fast path (provider already halted) — each
   with its terminal standing. Loop/reloop tests asserting
   suspended/no-terminal were corrected to the required behavior (and
   their titles with them); the restored deadline event plus the
   distinct-snapshot exactly-once gate test pin B2's scenario.
2. Outcome re-renewal / unread pending flag — CLOSED: the outcome
   evaluates only with undecided business (pending refusal, or spends
   since the last real evaluation — tracked explicitly and now READ).
   The restored `output_event("work", evt-out-1)` plus ordering
   assertions keep exactly 1 renewal; the new gate test (distinct
   snapshots, mutation-verified both directions) locks it. Legitimate
   multi-epoch renewal is preserved (re-loop twins green). Deadline
   checks were not removed.
3. Mid-turn refusal appends / double probe / already-dead settlement —
   CLOSED: `renew_only/3` is a single atomic evaluation that appends
   only on admit; refusals (including already-dead leases) append
   nothing mid-turn — no markers, no checkpoint, no settle. The
   flap test (admit-then-refuse, 3 probes total, expired only after the
   outcome) and the already-dead twins (completed: negatives plus clean
   terminal; interrupted: suspend/wake/terminal proving the outcome
   evaluated) pin it. No live-probe-latency assumption remains (the
   microsecond-TOCTOU note is retired with the preview it described).
4. Storm/evidence — CLOSED except as noted: deterministic teardown
    helper + regression (fixed-helper direction locks the
    whole-snapshot postcondition against a SYNTHETIC detached member;
    the companion direction documents the pre-fix helper's
    insufficiency and passes every commit by construction);
    the false catch-all comment replaced with explicitly labeled
    code reasoning (REPO-INSPECTION, not a verified mechanism);
    no `Process.alive?`-based synchronization and no sleep-polling in the
    new work (`refute Process.alive?/1` appears only as post-DOWN
    monotonic death assertions, never as synchronization; pre-existing
    storm-driver pacing left untouched and labeled in code);
   10 s helper deadline distinct from 5 s shutdown budgets; evidence
   boundaries restored (observed leak vs this run, lock-mechanism
   inference, exact-run busy statistics with no invented denominator);
   README model-control description rewritten for terminal-only;
   `event_normalizer` removed from scope (zero net diff); proof
   worktrees/logs preserved (never deleted this round); new-API
   `UndefinedFunctionError` results labeled documentation, never
   regression evidence.
- NITs, as actually disposed (no blanket claim: each item below states
  what was done, and the stale test comments fixed this round are
  listed): stale `track_open_tools`/`track_control` references — those
  helpers exist nowhere in lib (removed design); the one remaining
  comment naming them (`lease_bounds_test.exs`) is corrected this
  round to name only `tool_identity/1`; event-marker/model-control
  release descriptions (normalizer markers gone with the tracking that
  consumed them; session docs describe pend-only; the
  `session_test.exs` "model-control evidence releases it" comment is
  corrected this round to terminal-only, and the
  `elf_lease_loop_test.exs` "boundary marker" helper comment is
  corrected this round — the normalizer emits no `boundary` key and
  nothing gates on boundaries); contradictory mid-turn expiry
  comments (rewritten); unfinished-tool test now asserts terminal
  checkpoint evidence naming the tool; `String.to_atom/1` on the lease
  status replaced with an explicit finite mapping (the one remaining
  `String.to_atom` in `Leases.validate_transition/2` predates this work
  and is out of scope); `request_stop` doc and UI flash say turn end;
  duplicate probes gone with preview (flap test pins 3 probes for
  3 triggers); observability-only open-tool maps RETAINED (bounded,
  cleared per turn/outcome, status-only) and reported here per the
  review instead of removed, to keep this round focused on behavior.

## Independent gate at `de889c2` (1 failure: contention, cause NOT established)

This run must remain in evidence. Exact command (independent):
`cd <worktree> && mix precommit < /dev/null > /tmp/lease-boundary-independent-de889c2.log 2>&1`.
Exit 2; 4 doctests, 1506 tests, **1 failure**, 1 skipped (6 excluded);
Node 52/52, UI 7/7. The prior independent gate at parent `11b0460`
was green, and this round's own diff is prose/comments only — neither
fact proves cause or unrelatedness.

- Failure (log line ~777, seed 5938): `Shoestring.Harness.ObservatoryTest`
  "semantic deduplication reading with changed source event is persisted"
  (`test/shoestring/harness/observatory_test.exs:573`): first
  `Observatory.ingest` returned `{:error, {:retry_exhausted, :busy}}`
  instead of `{:ok, :persisted, _}`. The test itself is a plain
  two-ingest dedup check — no concurrency, no lease content.
- Log line ~745, same second: `owner #PID<0.5772.0> exited` while client
  `#PID<0.5750.0> (:proc_lib)` was inside `Writer.default_attempt /
  invoke_attempt / append_with_retries / handle_append` (a GenServer
  mid trajectory-append transaction as its sandbox owner died).
  Earlier (~18 s before): three simultaneous `database is locked` on
  `BEGIN IMMEDIATE` across three pool connections. `run_not_found` Elf
  checkpoint errors span several neighboring tests.

### Discrimination (bounded diagnosis, implementer-verified)

- VERIFIED — not a deterministic ingest-path regression: the file
  alone with the exact seed is 25/25 green; the FULL suite with the
  exact seed 5938 plus `--trace` is 1506/0 failures
  (`/tmp/opencode/diag-5938-trace.log`); the 21-file seed-order
  neighborhood block ending at ObservatoryTest is 179/179 green
  (`/tmp/opencode/diag-neighborhood.log`); a smaller subset is 42/42
  green (`/tmp/opencode/diag-subset1.log`). No leaked `sleep 30` OS
  children remained after the subset runs.
- SUPERSEDED/LIMITED (was: "VERIFIED — nothing in this branch's
  diff is in the failing path"): `Writer`, `Observatory`, trajectory,
  Repo, and config are still untouched by this branch (file-list
  proof), BUT the examiner pair reproduction puts the branch-changed
  Elf in the contending stack (`Elf.crash_land ->
  TerminalCheckpoint.record -> task_criterion`), so the earlier
  untouched-path inference no longer bounds the failure. The same
  reproduced leak also exists at `1566acd` (examiner base-pair runs),
  which bounds the leak's age but NOT the original failure: the exact
  causal link from the original run's Writer-client strand to this
  leak is unestablished.
- VERIFIED — retry mechanics (`writer.ex:224-246`, `:38`, `:78`):
  default max 2 retries with NO inter-attempt delay (tight recursion),
  so 3 rapid attempts overlapping any concurrent writer's transaction
  fail the call with `retry_exhausted`. Inside the test sandbox the
  savepoint-upgrade busy path fails at once (code comment at
  `writer.ex:260-266`); `busy_timeout: 2000` (`config.exs:19-20`, not
  overridden in test) does not cover that path.
- VERIFIED — cross-test-boundary Repo activity existed in the failing
  run (the owner-exited background Writer transaction above); the
  failing test's own process spawns nothing.
- NOT ESTABLISHED (INFERENCE at best): which exact earlier test's
  process held the write lock in the ORIGINAL run, and for how long.
  The earlier "manual-lease Elves die at launch" reasoning is WITHDRAWN
  (contradicted by the examiner trace: live registered Elf at test
  end). One failure in 5+ full runs is consistent with a rare
  timing collision, but rarity is not a root cause and is not claimed
  as one.

### Update: examiner diagnosis reproduced a manual-run Elf leak; test-only repair committed

Examiner read-only trial results (diagnostic evidence, NOT committed
proof — reported here, not re-run by the implementer): the examiner
traced the pair
(manual-lease + observatory, seed 0) with registry/DB-lock probes and
found a LIVE registered Elf at lease-test end in 27/27 cases across
HEAD and base: `/runs/new` submits reach `run_new_live.ex:340`
`Elves.start_elf` with no `supervisor` option, so the Elf runs under
the APPLICATION `Shoestring.Elves.Supervisor`, while the test's own
`_sup` (test file line 74) never owns it. The stranded client's stack
in the pair runs is `Elf.crash_land -> TerminalCheckpoint.record ->
task_criterion`, i.e. the leaked Elf doing Repo work on a
neighboring test's sandbox owner connection; the next Writer then
fails 3 rapid busy attempts. Pair rates: seed-0 HEAD `03b4ae4`
instrumented 2/6 failures, plain 2/6; base `1566acd` instrumented 1/3,
plain 1/6; trial repair instrumented 0/6, plain 0/6 with 0 owner
disconnects, 0 `run_not_found`, 0 live Elves at end. Artifacts
retained at `/tmp/claude-busy/` (driver, proposed patch, pair/plain/
fix logs); the proposed patch was reviewed, not blindly applied.

Explicit NON-claims (uncertainty retained): the original independent
failure's stranded client was a Writer, the pair's was an Elf — the
original caller was never captured, so the exact original cause is
NOT proven. The early nearby `database is locked` events were the
separate writer_contention test's own DB file, unrelated. Sandbox
busy-timeout behavior in this path remains unknown.

Repair (test-only, this round; production behavior untouched):
`run_new_manual_lease_test.exs:manual_grant!/3` now registers an
on_exit (test body, so before the setup-registered sandbox stop) that
terminates ONLY this test's run_id pid via `DynamicSupervisor.
terminate_child` on the application supervisor, awaits its DOWN
(monitors; already-exited safe), then asserts the regression
postcondition `Elves.whereis(run_id) == nil`. No registry sweep; no
new helpers (public `whereis/1` only); no sleeps/polling/retries;
teardown performs zero Repo writes (`:shutdown` → no crash marker).
The Fake-path `sleep` child is deliberately NOT reaped here — live
group reaping stays proven only by the explicit-cancel tests.

Implementer proofs (this worktree):
- Pre-fix behavior: with termination skipped (temporary local
  mutation, reverted), all 3 tests fail with the owned Elf alive —
  `assert whereis(run_id) == nil`, `left: #PID<0.499.0>` (and .514,
  .529), `right: nil` (`/tmp/opencode/mutation-no-teardown.log`).
  Behavioral reason (live owned pid), no structural error.
- Fixed HEAD: manual-lease file green; manual-lease + observatory
  pair (seed 0) 28/28 green with no lingering `sleep 30` children.
- Full gate after the repair (exact command
  `mix precommit < /dev/null`, foreground, single run): exit 0 — 4
  doctests + 1506 tests, 0 failures, 1 skipped (6 excluded); Node
  pass 52 / fail 0; UI 7/7/0. Log
  `/tmp/opencode/precommit-lease-elf-teardown-fix.log`. No rerun.
- Twin defect REPORTED, not fixed (out of scope):
  `test/shoestring_web/live/run_live_test.exs` submits the same
  `/runs/new` form repeatedly with the same app-supervisor ownership
  and no Elf teardown — same leak shape, needs its own round.

### Blocker and proposed next step (no code change made)

BLOCKER (SUPERSEDED by the repair above, kept for history): at the
time of writing the trigger was not identified within the bounded
investigation, so no fix was attempted. That decision is superseded
by the examiner diagnosis and the committed test-only repair; the
original-cause linkage remains INFERENCE per the non-claims above.
The observatory test was never at fault and was not modified.

Proposed next step (needs a brief): a single instrumented run that
captures the lock holder on busy — e.g. test-env-only logging of the
DBConnection owner/holder plus a live-process census when a Writer
attempt fails — followed by a targeted pair-run against the
identified predecessor; alternatively a Writer retry backoff
(production change, separate brief). Do not claim resolution from the
isolated green runs recorded here.

## Unresolved risks and residual limits

- Deadline pressure waits for the turn to finish (stated cost). An
  operator safe stop on a single-turn run likewise waits for natural
  completion — the accepted terminal-only safety tradeoff; no live
  effectiveness is claimed as proven (see OPEN N5 below).
- A turn with no outcome event at all never declines; supervision
  continues under the locked staleness rules (demonstrated hermetically
  by outcome-less scenarios draining without declining).
- `:error`-kind outcomes with a pending refusal keep their failure
  terminal without declining; recovery context survives through the
  ordinary terminal checkpoint (distinct id), not the reactive one.
- Mid-turn evaluations run once per spend when due/deadline holds (one
  probe each, appends only on admit); spend-heavy turns probe more, but
  never append refusals.
- The teardown helper's snapshot requires a live root (a dead tree
  cannot be traversed); orphans of an already-dead tree are reaped by
  pid. Crash-loop reincarnation between snapshot and kill is a bounded
  pre-existing window, unchanged by this round.

## Open follow-ups (recorded from review, NOT fixed this round)

Source: the Opus re-review of `11b0460` (behavioral blockers closed by
REPO-INSPECTION; reviewer ran no tests). The implementer did not
independently verify these behaviorally, and no behavior change was
made for any of them here — they are recorded so a later round can
take them with a separate brief.

- OPEN N1: an external concurrent expiry can produce an unhandled
  expired result in `renewal_attempt` and a duplicate admission
  decision within one epoch.
- OPEN N2: a failed outcome / failed stop can leave the UI showing
  lease `renewal_due`.
- OPEN N3: a failed interrupted-outcome checkpoint records the terminal
  with no wake while logging "run stays active for retry" — the log
  line misleads.
- OPEN N4: the Claude safe-stop flag can stick after its session
  finished.
- OPEN N5: operator safe stop for single-turn runs waits for natural
  completion (accepted terminal-only safety tradeoff, stated above);
  no claim is made that live effectiveness is proven.
- OPEN N6: deadline path probes once per spend (repeated probes on
  spend-heavy turns) — pre-existing per inspection.
- OPEN N7: the async kill snapshot can race a supervised child restart;
  post-DOWN `Process.alive?/1` assertions are discouraged by the
  standing contract (this round's uses are post-DOWN monotonic death
  assertions only, labeled where they appear).
- UNKNOWNS (explicitly not established): the `/tmp` proof logs were
  not independently inspected; the unchanged quota failed-terminal
  wake interaction is not fully traced; the live frequency of
  interrupted outcomes under pend-only stops is unknown.
