# Iteration-5 final closeout after #85: terminal-only lease stop, live

Branch `polly/iter5-final-closeout-post85`, base `a01da97` (#85 merged; same
tree as the approved `baec113`). Claim labels follow this directory's
`README.md`; an explanation that was not isolated is marked **INFERENCE**.

> **§1–§2 are the pre-registration.** They were committed before the first
> provider call of this sequence, and every live phase record carries the
> commit it ran at (`code.sha`, `code.tree`, `dirty`). They are left word for
> word as committed. Everything after §2 was written after the run.

## 1. Authorization, budget and scope

- **Authorized:** at most **three Codex provider runs** — `turn1`, `turn2`,
  `lease_stop` — one attempt each, through the existing subscription. No
  Claude receiver, no handoff, no ablation arm, no `cancel` phase, no retries,
  no separately billed API.
- **Non-provider phases:** `setup` (fixture + baseline), `release` (a durable
  `task.release` for turn 2's goal, because no handoff follows it here and
  `/runs/new` holds one global claim), `audit` (invariants; its handoff replay
  has no handoff record to replay and records `null`). `selftest` runs only
  against a throwaway state directory, never the live one.
- **Fresh state:** a new state directory under the per-user temp root, never
  the user's application-support directory, migrated with
  `mix run --no-start -e 'Shoestring.Release.migrate()'` (`final-acceptance.md`
  §8.1), never `mix ecto.migrate`. Normal monitors and Oban queues; no direct
  DB writes, no forced state changes, no injected observation.
- **Evidence from `f873372`** (the 2026-09-27 closeout at pre-#85 `1566acd`)
  is integrated by cherry-pick (`78a17f7`), unchanged except the README
  conflict (both entries kept). Its negative findings are history and stay.

## 2. Design, fixed before execution

### 2.1 What #85 changed (REPO-INSPECTION of `a01da97`)

- A lease safe stop (and a safe-boundary cancel) **only pends** at the
  session; the provider's own turn outcome resolves it with no send
  (`codex_app_server/session.ex` `pend_safe_stop/1`, `turn/completed`
  clause). Explicit immediate cancellation is unchanged.
- Mid-turn spends past the deadline run the admit-only `renew_only/3`: a
  refusal appends nothing. The full `maybe_renew/3` runs once at the turn
  outcome when there is undecided business (`elf.ex` `renew_path/3`).
- At the outcome a refusal settles by outcome kind: a **completed** turn keeps
  its terminal with the ordinary terminal checkpoint — no suspend, no wake, no
  continuation. Only an **interrupted** turn declines (`run_renewal/2`).
- `/runs/new`'s `timeout_seconds` is informational (`manual_timeout_seconds`
  in the admission's proposed bounds; the grant reads only contract keys). No
  product code stops a manual run on elapsed time. The lease watcher and the
  deadline path only request the (pending) safe stop.

So the 2026-09-27 shape — an interrupt 2.5 s after a command START with no
completion — is fixed hermetically by #85 (`lease-safe-boundary.md`). Whether
it holds live is what `lease_stop` measures.

### 2.2 Lease-stop acceptance (post-#85), pre-registered

Same prompt and bounds as before (60 s manual lease, 4000 events). Computed by
`FinalEval.lease_stop_facts/3` and `FinalEval.lease_stop_verdict/1` from
committed trajectory events and rows, after the 150 s wake observation. Each
is reported separately; the phase passes only if all hold.

| Id | Criterion | How it is read |
|---|---|---|
| L1 | The deadline marks renewal due while tools run | a `lease.renewal_due` precedes the turn outcome, and at least one tool item event (start or completion) is recorded after it and before the outcome |
| L2 | No Elf-induced interrupt and no driver cancel | the outcome's `result.status` is not `interrupted`, no `run.interrupted`, and the driver issued no cancel on this run |
| L3 | Every started tool item completed | ≥1 tool item started, and every started item's last status is `completed`, `failed` or `declined` |
| L4 | Exactly one renewal evaluation, at the outcome | exactly one `admission.decided` keyed `lease-renewal-decision:*` in the goal, sequenced after the outcome event |
| L5 | `run.completed` with a terminal checkpoint | exactly one terminal, `run.completed`, with a `checkpoint.created` for the run before it |
| L6 | No suspension or wake for finished work | 0 `run.pausing`, 0 `run.suspended`, 0 wakeup rows, 0 `wakeup` jobs, 0 wake decisions |
| L7 | No duplicate dispatch | 1 run in the goal, 1 dispatch row, 1 `run.starting`, 1 terminal |
| L8 | Lease row no longer live | status not in `proposed`, `granted`, `active`, `renewal_due`; the actual status and the `lease.*` event sequence are recorded, not assumed |

If the turn ends before the 60 s deadline, L1 is **not exercised**, and the
run is not repeated.

### 2.3 Superseded requirement (why no decline wake is required)

`final-acceptance.md` §8.4 asked for a manual-scope decline wake settled live.
After #85, a completed turn never declines, so that wake is unreachable
through a deadline stop. Only an interrupted outcome or a quota halt reaches
it. Neither is manufactured here: no forced interrupt, no synthetic quota. The
hermetic proofs stay the evidence for that path:
`test/shoestring/cobbler/wakeup_manual_scope_test.exs` (manual-scope recheck
settles once, `manual_scope_not_resumable`) and
`test/shoestring/harness/live_missing_session_stream_test.exs` (a declined
run's missing session is not a completion). Both files ran at this tree before
the live phases: 7 tests, 0 failures (`--seed 0`). The superseding criterion
is appended to `final-acceptance.md` as §10; its §2 and §8 are not edited.

### 2.4 Other pre-registered checks

- **P1 code identity:** every live phase record carries the same `code.sha`
  and `code.tree` as the commit that adds this file, with `dirty: false`.
- **P2 source checkout:** a read-only snapshot before the first boot and after
  the last are identical (HEAD, porcelain, index SHA-256 and mtime,
  `git diff HEAD` SHA-256 against a private index copy, stash count).
- **P3 process lifecycle:** after each Codex phase the Elf is deregistered and
  its recorded owned group is dead (`process_after`); after `audit`, no
  `beam.smp`, `codex app-server --stdio` or `claude --print` started by this
  sequence is running.
- **P4 capacity before spend:** each Codex phase submits only if the ledger
  holds a Codex reading whose `five_hour` and `weekly` windows are observed
  and below 80 % and 90 % used (the product's default reserves). Otherwise the
  phase records `:capacity_block` and submits nothing.
- **A1 audit invariants:** at most one `run.starting` and one terminal per
  run, a checkpoint before every stop, one dispatch row per started run.
- **Budget:** at most 3 Codex runs in the state DB at the end.

### 2.5 Execution safety and stop rules

- The node runs in the foreground of a `tmux` pane, one phase per boot, with
  no `timeout` wrapper and no `&`. The operator's observer commands (polling
  the phase log and a read-only DB) are each bounded; their bounds cannot
  reach the node.
- Every wait on a run is a **45-minute observation window** (was 900 s). On
  expiry with the Elf alive, the driver records `<phase>:observation_expired`
  and keeps the node up until the Elf exits by itself (`wait_decision/4`).
  Before a phase ends, it also holds for any other live Elf
  (`hold_for_live_elves/1`). Nothing is cancelled because a window ended.
- Stop rules: a capacity block, a turn that does not end `run.completed` with
  a clean committed head, or any observation expiry stops the sequence; no
  further provider run is started, and the block is reported. A phase that
  fails **before** `submit_turn` returns a run id has spent nothing and may
  be re-run once after its cause is fixed and recorded. A phase that has
  submitted is never re-run.
- A continuation the product dispatches after `lease_stop` is handled by the
  pre-existing §2.6 rule of `final-acceptance.md` (recorded, then cancelled
  once running). It fails L6/L7 and counts against the budget.

### 2.6 Driver changes, and how they were checked

`tools/live_eval/final_acceptance.exs`: tree SHA in the code identity; the
observation-window wait above; `hold_for_live_elves/1`; `ledger/0` and
`capacity_clear?/2`; `process_after/2`; `lease_stop_facts/3` and
`lease_stop_verdict/1`. The `selftest` phase (no provider, throwaway state
DB) checks each pure function: 34 of 34 checks pass (13 existing, 21 new),
including the 1566acd interrupted shape failing L2, L3, L4, L5 and L8. These
functions are new, so a pre-fix run would fail on a missing function, not
behaviourally: the selftest is DOCUMENTATION, not a regression lock. That the
old wait returned `{:timeout, run}` with a live Elf, ending the node, is
REPO-INSPECTION of `a01da97` (`do_wait/2`).

### 2.7 Amendment before the first provider call (P4 window names)

§§2.1–2.6 are left as committed at `b344a0b`. This amendment was committed
**after** `setup` and **before** any provider call.

- **What happened:** `setup` ran at `b344a0b` (clean) against the first fresh
  state directory, and its ledger showed the Codex reading's windows named
  `primary` (29.0 % used) and `secondary` (59.0 % used), not `five_hour` and
  `weekly`. P4 as written would have blocked every Codex phase: a driver
  defect, found before any spend.
- **Correction:** P4 now requires a reading with at least two windows, **every
  window observed and below 80 % used** (the stricter of the two default
  reserve thresholds, applied to all windows), and no refused or exhausted
  state. The reading carries no window duration, so it is not assumed which
  window is five-hourly; applying 80 % to both is the conservative reading.
  `selftest`: 37 of 37 checks pass (13 existing, 24 new), on a throwaway DB.
- **State directory:** that first directory (setup only, no provider run) is
  abandoned, not deleted. The sequence restarts on a second fresh,
  release-migrated directory, so every live phase record carries the
  amendment's commit (P1).
- **Observation, not traced further:** `AdmissionEvaluation` looks for
  `five_hour`/`weekly` windows (REPO-INSPECTION, `admission_evaluation.ex`),
  while the Codex reading names `primary`/`secondary`. How automatic Codex
  admission treats that was not traced; manual `/runs/new` admission does
  not consult it. Reported, not investigated in this scope.

---

*Everything below was written after the run.*

## 3. Result (2026-09-29 UTC)

| Item | Status | Where |
|---|---|---|
| Post-#85 lease stop, live (L1–L8) | **NOT RUN: blocked by the §2.5 stop rule.** `turn1` completed but could not commit (§4), so no further provider run was started. #85's terminal-only resolution stays **hermetically verified only** (`lease-safe-boundary.md`); the 1566acd live negative (`live-closeout.md` §5) is history, fixed hermetically, and **not re-verified live** | §4, §5 |
| New finding: Codex CLI 0.158.0 cannot commit in a Shoestring worktree | **VERIFIED** (provider's own message in the committed transcript, plus sandbox probes with no model call) | §4 |
| Budget | **1 of 3** Codex runs used (`turn1`); 0 Claude runs; no retry | §6 |
| P1 code identity | **VERIFIED**: `setup`, `turn1` and `audit` all record `code.sha = 17dd1bd…`, `code.tree = 399ec02…`, `dirty: false` | §6 |
| P2 source checkout | **VERIFIED unchanged**: the before and after snapshots are identical | §7 |
| P3 process lifecycle | **VERIFIED**: after `turn1` the Elf was deregistered and its recorded group dead (0 members); after `audit` no `beam.smp`, `codex app-server --stdio` or `claude --print` from this sequence was running | §6, §7 |
| P4 capacity before spend | **VERIFIED** after the §2.7 amendment: Codex `degraded / proactive`, primary 35.0 %, secondary 60.0 % used at `turn1` | §6 |
| A1 audit invariants | **VERIFIED**, 4 of 4 true over the 1 run | §6 |
| Observation window | Not reached: `turn1` stopped by itself at 174.6 s; no `:observation_expired`, no hold | §6 |

## 4. `turn1`: completed, uncommitted (VERIFIED)

Run `…002` in the fixtures (Codex, `/runs/new`, 300 s manual lease), 371
normalized events, `run.completed` 174.6 s after `run.starting`, one terminal
checkpoint before it. The run started, worked and ended by itself. The lease
deadline (300 s) was not reached, so no `lease.*` event followed the grant.

The `game/` package was written, `gofmt -l .` was clean, `go test ./...`
passed and `go vet ./...` failed only on the planted `legacy/scoreboard`
defect. But nothing was committed: the worktree ended dirty at the base
commit (`?? game/`). Codex's own final answer (reassembled from ordinals
279–366 of `normalized-post85-codex-turn1.md`) ends:

> Commit blocked: sandbox permissions prevent creating Git's `index.lock`.
> Changes remain uncommitted.

**Mechanism (VERIFIED by probes, no model call).** Shoestring starts Codex with
`sandbox: workspace-write` and `approvalPolicy: never`, with the run's worktree
as its working directory (REPO-INSPECTION, `codex_app_server/session.ex`
`thread/start`). A Shoestring worktree is a `git worktree`: its index lives in
the fixture repository's `.git/worktrees/<run>/`, outside the worktree. With
`codex sandbox -c 'sandbox_mode="workspace-write"'` (codex-cli 0.158.0, which
runs a command under the same seatbelt policy without any model), from inside
a scratch `git worktree`:

| Write | Result |
|---|---|
| a file in the worktree | allowed |
| a file elsewhere in the same temp root | allowed |
| a file in the main repository's `.git/` | allowed |
| a file in `.git/worktrees/<wt>/` (the worktree's own git dir) | **denied** |
| `git commit` in the worktree | **denied** (`Unable to create …/index.lock: Operation not permitted`) |

The same denial occurred with the layout under the scratch root and under the
per-user `$TMPDIR`, so the state-directory location is not the cause. At
`1566acd` with codex-cli 0.157.1, the same driver's Codex turns committed
(`live-closeout.md` §3, heads `47e3b26`, `d23fdaa`). **INFERENCE (not
isolated):** 0.158.0 protects the working directory's git dir inside the
`workspace-write` sandbox, where 0.157.1 did not. The adapter still declares
support for 0.153.2, and the ledger labels the Codex source `degraded`.

Consequence: at the installed CLI, a Codex Elf can do the work in a Shoestring
worktree but cannot commit it, so a Codex sender cannot leave committed state
for a checkpoint or handoff. **Not fixed**: a fix changes the production
sandbox policy (for example, adding the worktree's git dir as a writable root)
and is outside this brief.

## 5. What is still unverified live, and why

- **Terminal-only lease stop (#85).** The pre-registered stop rule ended the
  sequence before `lease_stop`, so L1–L8 were not measured. None of them is
  claimed. The `lease_stop` prompt does not ask for a commit, so a single
  `lease_stop` run from `setup`'s head would not hit §4's block. That needs a
  new brief: it is not the pre-registered sequence.
- **Manual-scope decline wake (finding 1).** Superseded as a live requirement
  (§2.3, `final-acceptance.md` §10). Hermetic only.
- **Observation-window hold.** The driver's hold path (§2.5) was never
  triggered live. It is REPO-INSPECTION plus the `selftest` checks only.
- **Observation (VERIFIED, not a criterion):** `turn1`'s lease row reads
  `active` after `run.completed` (deadline not reached, no renewal
  evaluated). Whether a terminal should settle a lease that never came due
  is not settled by #85, and is recorded here as an open question.

## 6. Phases (VERIFIED, committed summary `fixtures/live-final/post85-summary.json`)

| Phase | Provider | Code | Outcome |
|---|---|---|---|
| (abandoned) `setup` on state dir 1 | none | `b344a0b`, clean | ledger showed `primary`/`secondary` windows; P4 as first written would block (§2.7). Directory abandoned, not deleted, not in the summary |
| `setup` | none | `17dd1bd`, clean | fixture head `ed06095`; baseline `go vet` exit 1 (planted `copylocks`), `go test` exit 0 |
| `turn1` | Codex | `17dd1bd`, clean | `run.completed`, 371 events, worktree dirty at base (§4); `process_after`: Elf deregistered, group dead; claim released |
| `audit` | none | `17dd1bd`, clean | 1 run: 1 `run.starting`, 1 terminal, 1 checkpoint before the stop, 1 dispatch row (`effect_completed`); Oban: dispatch 1 `completed`; no wakeup or handoff jobs; replay `null` (no handoff) |

Not run: `release`, `turn2`, `lease_stop` (stop rule). Every phase exited 0
and wrote exactly one `RESULT` line. The fresh DB was built with
`Shoestring.Release.migrate()` (16 versions; a rerun printed `Migrations already
up`). The node ran in the foreground of a dedicated `tmux` pane, one phase per
boot, with no `timeout` wrapper; the operator only read the phase logs and the
DB (read-only).

## 7. Source checkout and processes (VERIFIED)

Before the first boot of this session (including the throwaway `selftest`
boots) and after `audit`: HEAD `1566acd`, porcelain `?? .github/hooks/`
`?? .pi/`, index SHA-256 `f7cfaa54…` with its mtime unchanged, `git diff HEAD`
SHA-256 of the empty string (private index copy), 4 stashes, and an identical
hash over the untracked files. The only `codex app-server` processes running
before and after were three that predate this session (a daemon and two
app-servers, not started by Shoestring). No `beam.smp` remained after any phase.

## 8. Fixtures

`fixtures/live-final/normalized-post85-codex-turn1.md` (371 events) and
`post85-summary.json` (3 phase records), produced by `export_evidence.py` and
`export_summary.py` in one label order (5 synthetic UUIDs: one UUIDv7, four UUIDv4; 0 prefixed ids).
Beyond `live_evidence_redaction_test.exs`, a scan for host paths, the login
name, the scratch and session directory names, the uid, reasoning keys and
non-synthetic UUIDs came back clean.

## 9. Acceptance 8: measured, no product advantage shown

Not re-run here, and no new ablation. The record, from committed evidence only:

- **Milestone wording:** "The semantic eval shows receiver behavior and
  handoff tax, not only final pass." The semantic section asks for the same
  fixture under worktree-only, naive-summary and trajectory-projection
  inputs, "recorded manually at first; deterministic final tests remain
  authoritative". Its fixture's Elf A is "interrupted by a scripted quota
  refusal".
- **What was measured** (`final-acceptance.md` §4, VERIFIED from its
  committed summary): three arms, live, twice, each cycle from one committed
  state; M1–M7 and H computed for every arm by pre-registered code.
- **What it showed:** in the **pre-registered** cycle the projection arm
  **failed** (its receiver adopted the ended sender session's stop limit).
  After a **post-hoc** label fix it passed 2 of 2, but in the one same-cycle
  comparison it cost more than `worktree_only` (55 vs 50 events, 63.0 vs
  55.8 s). The constraint and rejected-approach measures did not separate the
  arms. **No product advantage was shown.** The post-hoc nature of the repair
  and the original failure both stand.
- **Unresolved contractual issue:** the fixture's scripted quota refusal
  was never reproduced (`final-acceptance.md` §2.2). It cannot be produced
  without synthetic capacity, which these runs forbid. So the ablation ran on
  a fixture that departs from the milestone's in its interruption element.
- **Reviewer assessment vs human ruling:** an independent Claude review
  concluded that "measured, no advantage shown" meets the existing contract
  (recorded in `live-closeout.md` §10; not re-verified here). **No human ruling
  is recorded anywhere in the repository**, and none is implied here.
  Acceptance 8 is therefore **MEASURED — pending the human's ruling**.

## 10. Iteration-4 dependency, reconciled from committed evidence

Milestone 04's gate (7 bullets). Its tracked evidence is
`plans/evidence/04-single-elf/`; the milestone file itself is untracked in the
source checkout and was read, read-only.

| # | Bullet | Status | Evidence |
|---|---|---|---|
| 1 | Source checkout unchanged by all implementation runs | **Met on evidence** | every live record's before/after snapshot, including §7 here. The latent risk the milestone recorded (cwd falling back to the BEAM directory) is closed for live providers: an adapter-owned run fails closed with `worktree_not_found`/`invalid_worktree` (`a024558`, REPO-INSPECTION of `elf.ex` `prepare_adapter_workdir/1`). The fallback remains only for runner-owned (Fake) processes |
| 2 | Both adapters pass shared lifecycle and fixture suites | **Met** (hermetic, in every gate) | ContractSuite; Claude `:resume` capability-gated (the 1 skip) |
| 3 | A provider completes the live disposable demo | **Met on evidence** | `harness-live-verification.md` (both providers, marker exact, groups dead, sessions deregistered) and its 2026-09-21 addendum (the post-fix Codex turn). The 2026-09-06 demo failure (PR #39) is history |
| 4 | Run, process, session, worktree, compatibility metadata durable | **Met** | hermetic, plus every live summary (`process_id`, worktree head, the ledger's `degraded` compatibility label) |
| 5 | Crash/cancellation retains work and classifies terminal | **Met** | D1 progress guard merged (#44); live explicit cancellations classified `cancelled` then `already_terminal` (`live-cross-provider-handoff.md`, `production-unblock.md` §3.5, `final-acceptance.md` §5.3); crash redelivery to one Elf (`live-production-rerun.md`) |
| 6 | Lease stopping respects safe harness boundaries | **OPEN (live)**: hermetic after #85 only | the last live measurement (`live-closeout.md` §5, `1566acd`) was negative: an interrupt at a command START. #85 fixes that hermetically. This run could not re-measure it live (§4, §5) |
| 7 | No vendor credential or hidden reasoning persisted or rendered | **Met** | normalizer redaction (token-usage values `[REDACTED]`), `live_evidence_redaction_test.exs`, the per-fixture scans |

**Concrete missing requirement (escalated):** bullet 6 has no live
verification of the current (#85) behaviour. Either a live `lease_stop` run
(new brief), or a human ruling that the hermetic #85 locks suffice, closes it.
Nothing else in iteration 4 is reopened.

## 11. Acceptance gate 1–9 (final table)

Evidence levels: LIVE = VERIFIED from committed live events; HERMETIC =
VERIFIED by committed tests in the gate; REPO-INSPECTION as labelled.

| # | Gate | Status | Evidence level |
|---|---|---|---|
| 1 | Automatic dispatch never violates known reserves | Met | HERMETIC (eval matrix "Reserve refusal"). No live automatic refusal exercised; every live admission was manual or owner-confirmed. Not traced: how automatic Codex admission reads `primary`/`secondary` windows (§2.7) |
| 2 | Unknown/stale/reactive-only follow documented policy | Met | HERMETIC + LIVE (Claude `unknown / conservative_partial` admitted only with owner confirmation: #83, #84, `1566acd`) |
| 3 | All planned and failure stops create a structural checkpoint | Met, with limits | LIVE for completed, cancelled, lease-suspended and interrupted stops (`final-acceptance.md` §5.1, `live-closeout.md` §5, §6 here); failed and crash stops HERMETIC only |
| 4 | Checkpoint fallback performs no model inference | Met | HERMETIC + REPO-INSPECTION (deterministic builder); not separately instrumented live |
| 5 | Wakeups and dispatches idempotent across restart | Met, with limits | dispatch LIVE across every boot; settled handoff replay 0 new jobs LIVE (`live-closeout.md` §6); late-delivery, crash-window and manual-scope wake HERMETIC only (the last superseded as a live requirement, `final-acceptance.md` §10) |
| 6 | Same-provider resume and fake-backed cross-provider handoff | Met | HERMETIC |
| 7 | At least one real cross-provider handoff evaluated | Met | LIVE at `22c1e72`, `32a3fe6` and `1566acd` (codex-cli ≤0.157.1). New risk: at codex-cli 0.158.0 a Codex sender cannot commit (§4); not re-run |
| 8 | Semantic eval shows receiver behaviour and handoff tax | **MEASURED — no advantage shown; pending human ruling** | LIVE, N=1 per arm per cycle (§9) |
| 9 | Every decision explainable from persisted inputs | Met for the decisions inspected | LIVE for the inspected manual and owner-confirmed admissions and renewal refusals (including `operator_confirmed_manual` here); not audited over all decisions |

## 12. Open, carried forward (not fixed here)

- **New:** Codex CLI 0.158.0 cannot commit in a Shoestring worktree (§4).
- **Iteration-4 bullet 6** live (§10).
- **#85 follow-ups N1–N7** (`lease-safe-boundary.md`, "Open follow-ups"):
  N1 an external concurrent expiry can give an unhandled expired result and a
  duplicate admission decision in one epoch; N2 a failed outcome/stop can
  leave the UI showing `renewal_due`; N3 a misleading "run stays active for
  retry" log on a failed interrupted-outcome checkpoint; N4 the Claude
  safe-stop flag can stick after its session ended; N5 an operator safe stop
  on a single-turn run waits for natural completion; N6 the deadline path
  probes once per spend; N7 the async kill snapshot can race a supervised
  child restart. All nonblocking and unchanged.
- **Test leaks:** `run_live_test.exs` submits `/runs/new` repeatedly with
  app-supervisor-owned Elves and no teardown (the twin of the repaired
  `run_new_manual_lease_test.exs` leak); the app-level trajectory-writer leak
  named in `lease-safe-boundary.md`; both unfixed.
- **Carried:** run rows not projected after start (`run_row_status` reads
  `running` on the completed `turn1` here); receivers act on the operator's
  global instructions; the projector still raises on busy; redacted provider
  ids and the old `.pyc` remain in `main`'s history.
- The lease row left `active` after a completed run that never came due (§5).
