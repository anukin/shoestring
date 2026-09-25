# Production path unblocked: live Codex → Claude handoff and three-arm comparison

Date: 2026-09-23/24. Branch `polly/iter5-production-unblock`, base
`d3fa1529654bc88397df3d540326069159883b63` (#82 merged). Claim labels follow
this directory's `README.md` (`VERIFIED`, `REPO-INSPECTION`, `SCHEMA-ONLY`,
`UNVERIFIED`); a causal explanation that was not isolated is marked
**INFERENCE**.

This branch fixes the three production blockers #82 recorded (§1), plus two
more that surfaced once renewal could actually evaluate (§1.4, §1.5). It then
drove the genuine production path live (§3):
- two Codex turns;
- a durable handoff through the configured observation, confirmation,
  admission, lease and dispatch path to a Claude receiver, which finished the
  CLI;
- the three-arm comparison with handoff-tax measures;
- an explicit cancel, with the owned process group checked before and after.

**What is new versus earlier records.** #78 moved a real transfer, but it
**bypassed** the production observation path and the worker's decision step
(`live-cross-provider-handoff.md` §0). #82 ran on the production path and was
**blocked before the receiver** (`live-production-rerun.md` §3). This branch's
run went through that path end to end, with nothing bypassed. The branch is
unmerged and awaiting independent review.

---

## 0. Gate status after this run

| Gate | Status | Why |
|---|---|---|
| Acceptance 7: a real cross-provider handoff on the production path | **Demonstrated on this branch** (VERIFIED, §3.3) | `Handoffs.request/3` → live `handoff` queue → `HandoffWorker` with the `:prod` `WakeupObserve` probe → owner-confirmed admission → receiver lease → live `dispatch` queue → Claude Elf → `run.completed`, CLI accepted. Promotion to CLOSED is for the reviewer and merge; it rests on the product changes in §1, which are unreviewed. |
| Acceptance 8: semantic eval shows receiver behaviour and handoff tax | **Partially demonstrated, stays OPEN** | Three arms ran live on comparable initial states and the measures were fixed in advance (§4). But N=1 per arm, the milestone fixture's interruption / constraint / rejected-approach elements were not exercised, the arms differ in lease regime, and the predefined first-write measure never fired (§4.3). |
| Iteration-4 hard dependency: owned-group cancellation measured live | **Measured** (VERIFIED, §3.5) | Group alive before `cancel_run/1`, dead after, with the node still running. #82 could not measure this (`live-production-rerun.md` §4.1 limits). |

Iteration 6 stays locked until review and merge. The residual findings in §6
are open.

## 1. Code changes (each with a base-failure ledger)

The claims in this section rest on committed tests. **Base checks**: each new
test file was run against a `git archive` export of base `d3fa152`, with only
the new test file added. For §1.1 the pure helper module was also added, so
the tests compile; it is called by nothing at base, so base behaviour is
unchanged. Every run used a fresh state dir and `--seed 0`.

### 1.1 Renewal and wake re-record an Observatory-owned reading under a goal-local id (#82 §3.2)

`Shoestring.Cobbler.GoalLocalObservation` holds #79's derivation as one rule
for all three flows. Each flow derives the id from its own durable context:
- `handoff` (per handoff id): the preimage is byte-identical to #79's, so a
  handoff replayed across this change derives the same id;
- `lease-renewal` (per lease grant);
- `wakeup` (per wakeup id).

The observed id is kept as provenance in `cobbler.<flow>:observed_snapshot_id`.
The projector's ownership check is untouched.

`test/shoestring/cobbler/observatory_snapshot_twins_test.exs`, 10 tests:

| Run | Result |
|---|---|
| head | 10 tests, 0 failures (VERIFIED) |
| base | 10 tests, **9 failures**, every one on `{:capacity_snapshot_not_owned, _}` or zero `lease.renewed` events (VERIFIED) |

The one test that passes at base is DOC: the projector still refuses a work
goal re-appending a ledger-owned id, i.e. ownership was not relaxed.

The twins covered:
- renew and expire;
- chaining to the goal's own row, with provenance;
- a crash-retry replay: one observation and one decision;
- two goals renewing on the same ledger reading;
- the wake through the `:prod` MFA via `WakeupWorker` (admit, defer,
  performed twice);
- an Elf whose probe returns the ledger's own snapshot with
  `checkpoint_cadence: 1` (the #82 shape). The run completes, its terminal
  `checkpoint.created` projects to a `CheckpointRecord`, and the Observatory
  row stays owned by the Observatory.

Twelve existing assertions compared a chained or admitted id to the raw
observed id. Each now asserts equality with the exact derived id
(`GoalLocalObservation.snapshot_id/4`), and one also asserts the decision's
`observation.snapshot_id`. None was loosened to inequality or presence.

Not changed, recorded: a re-renewal on an **unchanged** reading replays its
epoch keys by design, so the lease row can rest at `renewal_due`
(REPO-INSPECTION, `LeaseRenewal.epoch_opts/3`). This behaviour predates the
change: the id was already constant for an unchanged reading.

### 1.2 The trajectory writer retries Exqlite's "Database busy" (#82 §3.3)

- `Writer.database_error/1` now also recognises `"Database busy"`, the string
  `Exqlite.Sqlite3` throws for a busy step.
- The writer's transaction begins `IMMEDIATE`, so SQLite's `busy_timeout`
  covers taking the write lock. The previous deferred transaction read first
  and upgraded at the INSERT, and in WAL mode that upgrade fails at once
  without waiting.
- One attempt is still one whole transaction, so a retry re-reads the
  idempotency key and `max(sequence)`: exactly once, contiguous.
- Retries stay bounded (`max_retries`, default 2), and non-busy errors are
  returned unretried.

`test/shoestring/trajectory/writer_contention_test.exs` runs against a real
WAL file database. A raw Exqlite connection holds the lock with
`BEGIN IMMEDIATE`, and the writer's repo runs with `busy_timeout: 0`. The lock
is released from a synchronous telemetry handler after the first failed
statement, so there are no sleeps.

| Run | Result |
|---|---|
| head | 6 tests, 0 failures (VERIFIED) |
| base | 6 tests, **5 failures**, each `{:database_error, "Database busy\nINSERT INTO \"trajectory_events\" …"}`, the exact live error (VERIFIED) |

**Intermittent, fixed in the test's design, recorded.** The
concurrent-writer test first ran every writer with `busy_timeout: 0`. Once
the held lock cleared, the four writers contended with each other, each
failure was immediate, and 2 retries could legitimately run out. That was
observed in **1 of 2** runs that included the file: the `--trace` run at
`061a39e`, seed 214605. One writer returned `{:retry_exhausted, :busy}`.

The test now runs with SQLite's production busy handler,
`busy_timeout: 2_000` (`config/config.exs`). The assertion is unchanged, and
no retry, sleep or skip was added. After the change, each run logged
separately at head:

| Runs | Seeds | Result |
|---|---|---|
| 5 plain runs | 471980, 180193, 857664, 513556, 136754 | 6 tests, 0 failures each |
| 1 `--trace` run | 802076 | 6 tests, 0 failures (the concurrent test took 2402.9 ms) |

Base: 6 tests, 5 failures, the same 5 LOCK tests.

Covered:
- one contended append lands exactly once;
- later-append contention keeps sequences contiguous, and a duplicate key is
  not a second row;
- exhausted contention returns `{:retry_exhausted, :busy}` after exactly 3
  failed statements and leaves 0 rows;
- 4 concurrent launches behind one held lock each land once;
- Exqlite's own message is retryable.

The DOC test (a non-busy `disk I/O error` is returned after 1 attempt) passes
at base.

Recorded, not changed:
- **Exqlite disconnects on a busy BEGIN.** When `BEGIN IMMEDIATE` itself is
  busy, Exqlite disconnects that pooled connection and DBConnection reconnects
  it (REPO-INSPECTION, `Exqlite.Connection.handle_transaction/3`). The error
  still classifies as busy. In production this happens only after the 2 s
  `busy_timeout`.
- **The projector can still raise on busy.** `Projector.project/1` still
  raises a raw `Exqlite.Error` on busy. It was traced and **not changed**:
  - it is not what failed the #82 launches, which failed in the writer;
  - the Elf's renewal caller rescues it;
  - the wake and handoff callers run in Oban, which retries on raise;
  - the new projection in `Handoffs.request/3` catches it as a retryable
    error.

  It remains a residual risk for `RunNewLive`'s manual-observation projection
  (§6).
- **The migration failure #82 noted is not diagnosed.** Migrating a fresh file
  database with `pool_size: 4, busy_timeout: 0` fails partway ("index … already
  exists"), so the contention test migrates on one connection first. This
  resembles #82's unexplained first `mix ecto.migrate` failure, but is
  UNVERIFIED as the same cause.

### 1.3 A Claude reading reaches the production probe (#82 §3.1)

Smallest supported integration: the monitor's existing
`auto_ingest_initial`, set in `config/config.exs`. The reading is the
monitor's honest pre-first-response one: `unknown`, `conservative_partial`,
no windows, no `observed_at`, confidence `none`.

The ingest now happens after version discovery. It never blocks `init/1`, and
a refused sink is reported as `sink_status`, not retried on a timer.
`config/test.exs` resets the flag, because config entries deep-merge (§5,
gate run 1).

`test/shoestring/cobbler/claude_ingress_prod_test.exs`, 8 tests. It reads the
`:prod` config with `Config.Reader`, starts the monitor through
`Capacity.Supervisor.claude_child_spec/1` with a stub version runner (never
the CLI), and uses the real Observatory and `HandoffWorker`.

| Run | Result |
|---|---|
| head | 8 tests, 0 failures (VERIFIED) |
| base | **4 failures**: config key `nil`; `WakeupObserve` → `{:error, :no_observation}`; both handoff deliveries → `{:observation_failed, :no_observation}` (VERIFIED) |

The base run covered 7 of the 8 tests. The eighth, which checks that a boot
reading never displaces a real one, was added after that run and is DOC by
construction: at base nothing is auto-ingested.

What the tests pin:
- no confirmation → `require_confirmation`
  (`support_tier_conservative_partial`, confidence `none`), with no receiver,
  lease or dispatch;
- the owner-bound confirmation (`confirmed_by: owner:<goal owner>`) → admit,
  lease and one dispatch job;
- DOC: a refused Claude reading defers even with a confirmation;
- DOC: a confirmation for another capability admits nothing;
- DOC: a boot reading never displaces a real last-known one. `observed_at: nil`
  sorts last under `DESC` (REPO-INSPECTION, `Observatory` ordering), so a real
  reading always wins.

### 1.4 `Handoffs.request/3` projects before it validates

Found while tracing, not listed in #82. No product path projects a finished
Elf's terminal `checkpoint.created`: the only projector callers are
`/runs/new` at start and the renewal, wake and handoff dispatch steps
(REPO-INSPECTION, `grep` of `lib/`). So `run.handoff` validation, which reads
the projected `CheckpointRecord`, rejected a handoff from a run that had
simply completed (`handoff_checkpoint_not_found`). #82's driver hid this by
calling `Projector.project/1` itself.

`request/3` now projects the goal first. If projection fails, it returns
`{:error, {:handoff_projection_failed, _}}` **before** submitting anything, so
a transient failure never becomes a terminal rejection under the caller's
command id.

`test/shoestring/cobbler/handoff_request_projection_test.exs`, 4 tests:

| Run | Result |
|---|---|
| head | 4 tests, 0 failures (VERIFIED) |
| base | **2 failures**: the command is `rejected` instead of `resolved`, and a poisoned projector records a command instead of erroring (VERIFIED) |

Two DOC tests pass at base: replay returns the same intent, and a foreign
checkpoint is still rejected.

Live, the sender's checkpoint was **not** a row before the request and **was**
a row after it (§3.3).

### 1.5 `/runs/new` proposes `checkpoint_cadence = max_events`

This is a scope deviation, flagged: `lib/shoestring_web/live/run_new_live.ex`
is outside the brief's file list. It is a one-value change in the admission
payload, not a UI refactor.

A manual lease is scoped `account:manual`, and no provider reading carries
that scope. So once §1.1 let renewal evaluate, every manual renewal returned
`:expired` / `snapshot_provider_mismatch`. That was measured in a throwaway
experiment and is now pinned by a DOC test. The Elf then declines: checkpoint,
suspend, stop. With the old cadence of 1, every manual run, including both
live Codex turns, would have stopped after its **first response**. #82 never
saw this only because renewal wedged the projector first.

The operator's own envelope (`max_events` and the ≤300 s `lease_seconds`
deadline) still ends the run through that same safeguard. Renewal itself is
unchanged.

`test/shoestring_web/live/run_new_manual_lease_test.exs`, 3 tests:

| Run | Result |
|---|---|
| head | 3 tests, 0 failures (VERIFIED) |
| base | **1 failure**: `:renewal_due` fires on the first completed response (VERIFIED) |

The two DOC tests pass at base: `max_events` still ends the lease, and a
manual renewal is still never admitted.

## 2. Runtime identity

- **Receiver: VERIFIED.** Every Claude receiver run reported
  `claude-headless:model: "claude-opus-5-5"` in its own normalized system
  frame. That is 3 of 3 Claude runs (summary `tax.receiver_models`, and the
  transcripts). `claude --version` on the host prints `2.1.281 (Claude Code)`.
- **Worker: UNVERIFIED.** The worker that implemented this branch and wrote
  this document is a separate process. Its session context names Opus 5.5
  (`claude-opus-5-5`), but that is configuration text, not a runtime
  observation, and it is not equated with the receiver's reading.

## 3. The live run

### 3.1 Node, isolation and entry points (VERIFIED)

- **Node.** `MIX_ENV=prod` at code SHA `22c1e72` (the gated SHA, §5), with a
  fresh `SHOESTRING_STATE_DIR` under `$TMPDIR`, outside the source checkout. It
  was migrated with `Shoestring.Release.migrate/0` and given a random
  `SECRET_KEY_BASE`, with no web server. Everything production configures was
  live: the `WakeupObserve` MFAs, `ElfEffect`, both monitors, and the Oban
  queues.
- **Workspace.** The disposable Go module is `example.com/tictactoe`. It was
  created by the driver's `setup` phase with one baseline commit (`go.mod`,
  `TASK.md`), no remote, and a synthetic git identity.
- **Source checkout untouched.** `git status --short` shows only the two
  pre-existing untracked paths, both before and after.
- **Entry points.** The driver (`tools/live_eval/prod_rerun.exs`) calls only:
  - the `/runs/new` submit handler;
  - durable `task.release`;
  - `Handoffs.request/3`;
  - `Elves.cancel_run/1`.

  It never calls `Handoffs.perform/3`, never injects an observation, never
  appends events, and, unlike #82's version, never calls the projector.
- **Driver changes, each tied to coverage or a defect.** It now:
  - drops its own projection (§1.4);
  - carries a per-transfer `lease_policy` (§3.3);
  - adds `setup` and `arm` phases;
  - adds the fixed acceptance and tax measures.

  The Codex turn prompts are byte-identical to #82's.
- **Receiver instructions.** The Claude CLI loads the operator's user-level
  instructions. Two arm receivers ran `git push`, and one ran `gh pr create`.
  Both failed: the repository has 0 remotes, giving
  `fatal: 'origin' does not appear to be a git repository` and
  `no git remotes found` (VERIFIED from the recorded tool results). Nothing
  left the machine. This is a confound common to all three arms, and a safety
  note for §6.

### 3.2 Legs (VERIFIED from the run database; transcripts in `fixtures/live-unblock/`)

| # | Leg | Provider (receiver model) | Terminal | Normalized events | Notes |
|---|---|---|---|---:|---|
| 1 | Turn 1 via `/runs/new` | Codex | `run.completed` | 286 | `game/` committed (`cdb51b7`), clean |
| 2 | Turn 2 via `/runs/new`, from `cdb51b7` | Codex | `run.completed` | 300 | `parseMove` + tests committed (`c06535c`), `main()` placeholder |
| 3 | Handoff receiver, arm **trajectory_projection** | Claude (`claude-opus-5-5`) | `run.completed` | 50 | in the sender worktree from `c06535c`; committed `a6724ac` |
| 4 | Arm **worktree_only** via `/runs/new`, from `c06535c` | Claude (`claude-opus-5-5`) | `run.completed` | 28 | committed `185ed31` |
| 5 | Arm **naive_summary** via `/runs/new`, from `c06535c` | Claude (`claude-opus-5-5`) | `run.completed` | 32 | committed `9d0b1ca` |
| 6 | Cancel probe via `/runs/new`, from `c06535c` | Codex | `run.cancelled` | 33 | §3.5 |

- **Launches:** 0 of 6 failed before `run.starting` (versus 3 of 5 in #82).
  INFERENCE: consistent with §1.2, but the #82 contention was load-dependent,
  so one clean run does not prove it cannot recur.
- **Per run:** exactly one `run.starting`, one `run.running` and one terminal.
  All 7 Oban jobs completed on attempt 1, and all 6 dispatch rows are
  `effect_completed`. `/runs/new` both starts the Elf directly and enqueues
  its dispatch job, and that duplicate delivery started no second Elf.
- **Not re-exercised this run:** crash-restart redelivery; #82 §4.1 remains the
  evidence for it.
- **No stop was caused by a timer, deadline, heartbeat or staleness.** Every
  terminal is either completion or the explicit cancel.

### 3.3 The production handoff, step by step (VERIFIED)

1. **Before the request.** The Observatory ledger held
   `claude / subscription / unknown / conservative_partial`, ingested at boot
   by the monitor (§1.3), and `codex / subscription / degraded / proactive`.
   The sender's terminal checkpoint was **not** a `CheckpointRecord`.
2. **The request.** `Handoffs.request/3` projected the goal. The checkpoint was
   then a row, and the command resolved `handoff_requested` with
   `confirmation.confirmed_by = owner:<goal owner>`, the requested
   `lease_policy`, and one `handoff` job.
3. **Delivery.** The live queue delivered it to `HandoffWorker` on attempt 1,
   with 0 errors. The ledger probe served the Claude reading, re-recorded as
   the goal's own observation (§1.1). Admission then ran with the
   confirmation, followed by the receiver `ExecutionLease`,
   `handoff.created`, `dispatch.requested` and the Claude Elf.
4. **Latency.** Command accepted → `handoff.created`: **48 ms**. Command
   accepted → receiver `run.starting`: **506 ms**. `run.running` followed at
   1052 ms.
5. **Receiver lease.** `response_budget 150`, `tool_budget 300`,
   `checkpoint_cadence 150`, reserves 1/1, deadline 2700 s, which is the
   `HandoffLeasePolicy` default deadline. It ended `active`: never due, never
   renewed, never declined.
6. **Outcome.** The receiver completed in **72.5 s** and committed the game
   loop. See §4 and `go-verification.txt`. The goal's projector is `ok` at
   sequence 322, the dispatch step's projection. The receiver's later events
   are committed but unprojected (§6.1).

**Why this transfer carried a lease policy.** The durable default is
`response 10, tool 25, checkpoint_cadence 1`. The Claude receiver's own
renewal probe (`ClaudeHeadless.probe/1`) reports scope `account` under the
constant id `…0089` (REPO-INSPECTION), while this transfer is admitted under
`subscription`. So its renewal can never be admitted, and under the default
cadence the receiver would be declined after its first response. This is
REPO-INSPECTION plus the §1.5 mechanism, not exercised live.

The bounds used keep every safeguard:
- the deadline is unchanged at 2700 s;
- the budgets are finite, sized from #82's comparable Codex turn (323
  normalized events);
- exhaustion still declines.

The receiver used 9 tool starts and 50 events.

### 3.4 Receiver acceptance (VERIFIED, `go-verification.txt`)

All three arms ended with:
- gofmt clean, `go vet` and `go test -count=1 ./...` passing;
- a clean, committed tree;
- `game/` unchanged since turn 1, and `main.go` importing
  `example.com/tictactoe/game`.

All **5 of 5 scripted games** pass: `X wins` by row, `O wins`, diagonal
`X wins`, `Draw`, and an invalid-input game with ≥3 `invalid` lines ending
`X wins`, all with exit 0. `=== RUN` counts are 80, 81 and 84 (projection,
worktree_only, naive_summary). These counts include tests each receiver added.

### 3.5 Explicit cancellation with owned process-group liveness (VERIFIED)

The driver cancelled only once the owned group was alive (`kill -0 -<pgid>`
exit 0) and the run had 33 normalized events.

| Check | Result |
|---|---|
| `cancel_run/1` | `{:ok, :cancelled}` in 125 ms |
| group after the run stopped, node still up | **dead** |
| Elf registered after | no |
| lifecycle | `run.cancelling` → `checkpoint.created` → `run.cancelled`; exactly 1 `run.cancelled` |
| second `cancel_run/1` | `{:ok, :already_terminal}` |

The group check ran while the node was still alive, so the death is
attributable to the cancel. That closes #82 §4.1's measurement gap.

## 4. Three-arm comparison and handoff tax

### 4.1 Design, fixed before execution (REPO-INSPECTION, `prod_rerun.exs`)

- **Same starting state.** All arms start from turn 2's committed head
  `c06535c`, and the objective reaches every arm only through the committed
  `TASK.md`. The composed handoff prompt carries **no task statement**, only
  the checkpoint pointer, decision refs and verification lines
  (REPO-INSPECTION, `Continuation.compose_handoff_prompt/2`).
- **The inputs that differ:**

| Arm | Input |
|---|---|
| **trajectory_projection** | the real handoff prompt, composed by the product; receiver in the sender worktree |
| **worktree_only** | `Continuation.compose_handoff_prompt/2` is not used; prompt `"Continue the work in this repository."` via `/runs/new` |
| **naive_summary** | worktree_only's prompt plus a fixed naive summary sentence |

- **The arms are not fully like-for-like, disclosed.** The product has no
  handoff mode with ablated context, so two arms are fresh `/runs/new` Claude
  runs. Their manual lease is capped at a 300 s deadline, versus 2700 s for
  the handoff receiver. No arm came near either bound.
- **Order.** Arms ran sequentially in the order C, A, B.
- **Measures:** acceptance (§3.4) and, per receiver:
  - normalized events;
  - tool starts;
  - wall-clock from `run.starting` to terminal;
  - events, tool starts, Read starts and Bash starts before the first
    Write/Edit/MultiEdit/NotebookEdit tool start;
  - milliseconds to that start;
  - Bash commands containing `mix `.
- **Limit of the Read count.** Read file paths are not captured by the
  normalizer, so "repeated reads of complete files" could only be bounded.

### 4.2 Results (N=1 per arm; anecdotal, not statistical)

| Measure (unit) | trajectory_projection | worktree_only | naive_summary |
|---|---:|---:|---:|
| acceptance: vet, test, 5/5 games, `game` reused | pass | pass | pass |
| normalized events (count) | 50 | 28 | 32 |
| tool starts (count; all `Bash`) | 9 | 6 | 7 |
| run wall-clock, `run.starting` → terminal (ms) | 72 544 | 49 378 | 59 815 |
| CLI-reported turns (count) | 10 | 7 | 8 |
| CLI-reported `total_cost_usd` (notional USD, subscription account) | 0.357 | 0.240 | 0.324 |
| predefined: Write/Edit starts before completion (count) | 0 | 0 | 0 |
| predefined: Read starts (count) | 0 | 0 | 0 |
| predefined: `mix ` commands (count) | 0 | 0 | 0 |
| POST-HOC: tool starts before first file mutation (`cat > main.go` heredoc) (count) | 5 | 2 | 2 |
| POST-HOC: normalized events before that mutation (count) | 25 | 11 | 9 |
| POST-HOC: `run.starting` → first mutation (ms) | 36 478 | 28 231 | 14 567 |

Handoff tax expressed as arm − trajectory_projection, same units. Negative
means the arm cost less than the product projection.

| Measure | worktree_only − projection | naive_summary − projection |
|---|---:|---:|
| normalized events | −22 | −18 |
| tool starts | −3 | −2 |
| run wall-clock (ms) | −23 166 | −12 729 |
| POST-HOC tool starts before first mutation | −3 | −3 |
| POST-HOC ms to first mutation | −8 247 | −21 911 |

`total_cost_usd` is the Claude CLI's own reported figure on a subscription
account. It is UNVERIFIED as any actual charge.

### 4.3 What this does and does not show

- **Every arm finished; the projection arm was the most expensive.** It had
  more events, more tool starts, more wall-clock and a later first mutation.
- **INFERENCE (not isolated): two product-prompt contents plausibly
  contribute.**
  - The completed-run terminal checkpoint's `next_action` is fixed text,
    "Verify the worktree with `mix precommit` …" (REPO-INSPECTION,
    `TerminalCheckpoint.next_action/4`). It is an Elixir command in a Go
    repository, and the projection receiver's second command probed
    `ls mix.exs`.
  - The prompt also leads with checkpoint and decision identifiers rather
    than the task.
- **Not established:** that the projection *causes* higher cost. N=1, arm
  order (C first) and run-to-run variance are not controlled.
- **The predefined first-write measure never fired.** All three receivers
  mutated files only through Bash heredocs, never the Write/Edit tools. That
  measure is reported as defined (0 and "not found" in the summary), and the
  POST-HOC rows are labelled as derived after execution from the committed
  commands.
- **Not exercised live:** the milestone's semantic fixture elements, namely
  irrelevant files, a recorded constraint or rejected approach, a scripted
  quota-refusal interruption, and a second failure exposed by a test.
  Acceptance 8 therefore stays OPEN.

## 5. Gates and focused runs (exact commands, SHAs, counts; logged per run)

**Protocol, fixed before the first gate run:**
- `mix precommit` runs once per commit SHA with a fresh
  `SHOESTRING_TEST_STATE_DIR`;
- on a red run, record it, diagnose it, and allow at most one further run on
  the same SHA;
- no pooled "N of M" totals.

| # | SHA | Command | Seed | Exit | Elixir | Node gate_0a | Node UI |
|---|---|---|---|---|---|---|---|
| 1 | `8587b7f` | `mix precommit` | 703209 | **2** | 4 doctests, 1432 tests, **2 failures**, 1 skipped (6 excluded) | 52/52 | 7/7 |
| 2 | `22c1e72` | `mix precommit` | 895679 | **0** | 4 doctests, 1433 tests, 0 failures, 1 skipped (6 excluded) | 52/52 | 7/7 |
| 3 | `061a39e` | `mix precommit` | 214605 | **0** | 4 doctests, 1433 tests, 0 failures, 1 skipped (6 excluded) | 52/52 | 7/7 |
| 4 | `6e3f021` | `mix precommit` | 258132 | **0** | 4 doctests, 1433 tests, 0 failures, 1 skipped (6 excluded) | 52/52 | 7/7 |

**Run 1 diagnosis (VERIFIED).** It had two failures:
- `RepoTest`: my state dir was not under `System.tmp_dir!()`. The fault was in
  how I set up the gate, not the product; the state dir was moved under
  `$TMPDIR` for every later run.
- `Capacity.DemoTest:619`: a real defect in this branch. `config.exs`'s
  `auto_ingest_initial` deep-merged into the test env's disabled entry, so the
  demo's supervised monitor ingested an extra reading. Isolated with seed
  703209: deterministic at `8587b7f`, and 1 test, 0 failures at base. Fixed in
  `22c1e72` by resetting the flag in `config/test.exs`.

Runs 1 and 3 each carried `codex_core::tools::router ERROR exec_command
failed` lines (2 and 5 respectively); run 2 had none. **Source identified**
(VERIFIED, §6.9): a test outside this branch launches the real
`codex app-server --stdio` binary.

**Diagnostic runs at `061a39e`, not gate runs, each logged separately:**

| Command | Result |
|---|---|
| `mix test --seed 214605` with a logging `codex`/`claude` shim first on `PATH` | exit 0, 4 doctests, 1433 tests, 0 failures, 1 skipped (6 excluded); 1 `codex app-server --stdio` invocation, 0 `codex_core` lines |
| the same with `--trace` | exit 2, 1 failure: the concurrent-writer flake above |

Directory bisection with the shim found the launch only under
`test/shoestring/harness/claude_headless/adapter_isolation_test.exs`.

**Focused runs** (all 0 failures on their final SHA, fresh state dir):
- `test/shoestring/cobbler test/shoestring/elves test/shoestring/harness/eval_matrix`:
  520 tests, 0 failures, before the new files were added;
- each new file on its own at head, counts in §1;
- `test/shoestring/evidence/live_evidence_redaction_test.exs`: 5 tests,
  0 failures.

### 5.1 Final-SHA gate

Run 4 is the gate for the last code-and-test commit, `6e3f021`. The commit
after it changes only this document; `git diff --stat 6e3f021..HEAD` lists
this file alone. That commit was not re-gated.

Run 4 printed 0 `codex_core` lines. That does **not** show the real Codex
launch in §6.9 stopped: the test is unchanged, and whether that process
writes to stderr varies.

## 6. Residual findings (open; none fixed here unless stated)

1. **Nothing projects a finished run.** After start, a `/runs/new` goal's
   projector stays at sequence 1, and its run and lease rows read `requested`
   and `null` indefinitely (VERIFIED live, summary `projector` and `lease`).
   Only `Handoffs.request/3` now closes that for the handoff path. UI and run
   rows remain stale.
2. **The terminal checkpoint's advice is Elixir-only.** A completed run's
   terminal-checkpoint `next_action` says `mix precommit` whatever the
   repository is, and the handoff prompt carries no task objective (§4.3).
   This live run relied on `TASK.md`.
3. **The Claude receiver can never renew.** `ClaudeHeadless.probe/1` reports
   scope `account` with a constant snapshot id, so a Claude receiver admitted
   under `subscription` never renews. Only a sized per-transfer
   `lease_policy` avoids an early decline (REPO-INSPECTION; not exercised
   live).
4. **Manual runs are one-epoch.** Manual leases are unrenewable by
   construction and capped at 300 s (§1.5).
5. **Fake manual runs crash.** `/runs/new` with provider `fake` crashes at
   launch, because it passes an atom scenario (#82 §4.4; unchanged).
6. **Receivers act on the operator's global instructions.** They attempted
   `git push` and `gh pr create` (§3.1). This was harmless here, since the
   repository has no remote. A receiver in a repository **with** a remote
   would act on those instructions, and that is not constrained by Shoestring
   today (INFERENCE from the observed commands).
7. **Busy-path residue.** `Projector.project/1` still raises on busy (§1.2).
   Busy BEGINs cost a reconnect (§1.2).
8. **Resolved: the `codex_core` log lines.** They came from the real Codex
   launch described in item 9 (§5).
9. **The hermetic suite launched the real Codex CLI (pre-existing). FIXED in
   the gate-correction round, §8.2.** VERIFIED with a logging shim, at
   `061a39e` and at base `d3fa152`.
   - **Where:**
     `test/shoestring/harness/claude_headless/adapter_isolation_test.exs`
     (since `07a7ff4`) starts `CodexAppServer.Session` with no command
     override. It assumes "no provider CLI here", but on a host with `codex`
     on `PATH` it spawns `codex app-server --stdio` in the project directory
     on every `mix test` / `mix precommit`.
   - **Evidence of a turn:** the `exec_command failed` lines are that
     process's stderr, so the Codex process ran and attempted tool execution.
   - **Quota: UNVERIFIED.** Whether a model turn, and therefore provider
     quota, was consumed is not established.
   - This violated the repository's hermetic-test rule. §8.2 records the fix
     and its proof.

## 7. Evidence and redaction

| File | Backs |
|---|---|
| `fixtures/live-unblock/normalized-codex-turn{1,2}.md` | §3.2 legs 1–2 |
| `…/normalized-claude-receiver-trajectory-projection.md` | §3.3, §4 (receiver model frame, commands, `ls mix.exs` probe) |
| `…/normalized-claude-arm-{worktree-only,naive-summary}.md` | §4, §3.1 push/PR attempts |
| `…/normalized-codex-cancel.md` | §3.5 |
| `…/go-verification.txt` | §3.4 (re-run read-only after the live phases) |
| `…/unblock-run-summary.json` | every recorded phase, with the tax measures, receiver lease, ledger, and cancel liveness |

**How the files were produced.** `tools/live_eval/export_evidence.py` wrote
the transcripts, unchanged from #82. The new
`tools/live_eval/export_summary.py` renders the transcripts first, in the same
process, so the summary uses the identical synthetic id mapping. Both read the
run database read-only.

**Redaction.**
- It is applied to the reassembled delta stream and then to each whole line.
- It is same-length.
- UUIDs become the declared synthetic series; worktree and other host paths
  become `$WORKSPACE` and `$STATE`/`$REDACTED_PATH`.
- `pgid:` digits become `x`.
- Session, item and source-event ids and cwd are omitted.
- No reasoning content exists: the Claude normalizer drops thinking blocks,
  and the only `reasoning` strings are Codex's redacted token counters.

**The redaction test.** `live_evidence_redaction_test.exs` now also globs
`fixtures/live-unblock/*`. For a 0-event transcript it now requires an
*exactly empty* reassembly and **no** `run.running` line. That addresses #82's
zero-event nit.

**Mutation checks.** Each check was planted, run and removed:
- a contiguous `/Users/xyz/w` in a Claude `output_text` failed both the raw
  scan and the reassembled `raw detail stream` scan;
- a 0-event transcript with `run.running` failed the new check.

## 8. Gate-correction round (before cross-review)

Scope, as the brief extended it:
- the CI failure on this PR;
- the real Codex launch in `adapter_isolation_test.exs` (§6.9), with the test
  support that fix needs;
- this record and the PR.

No live run happened in this round. The live evidence in §§3–4 is unchanged
and still describes code SHA `22c1e72`. Acceptance 8 stays OPEN.

### 8.1 CI outcomes at `5cd9de4`, both kept

| Run | Event | Seed | Result |
|---|---|---|---|
| 35955255945 | push | 836743 | **failure**: 4 doctests, 1433 tests, 1 failure, 1 skipped (6 excluded) |
| 35955284981 | pull_request | 427204 | success: 4 doctests, 1433 tests, 0 failures, 1 skipped (6 excluded) |

The failure was `ElfLeaseReloopTest` "decline interrupted provider response
restarts through the wake" (`elf_lease_reloop_test.exs:419`). At `:455`,
`wait_running/2` (`:777`) timed out after 10 s waiting for a `run.running`
pgid.

### 8.2 The real Codex launch: fixed and proved (VERIFIED)

**The fix.** The test's Codex session now runs on the in-memory
`Capacity.Codex.FakeTransport`. It is still a live session process with a
connected transport, and it now also asserts that the transport survives the
Claude crash.

**The guard.** New test support, `Shoestring.Test.ProviderCliGuard`, does two
things:
- it call-traces every `:erlang.open_port/2` in the VM, flushed with
  `:erlang.trace_delivered/1`, so the check is deterministic, with no polling;
- it puts shim `codex`/`claude` executables first on `PATH`, so a missed spawn
  runs a shim, never the real CLI.

Both tests in the file assert that no provider CLI was spawned.

**Regression proof, base export with the guard added to the old test body**
(Codex session on its default transport): 3 of 3 runs, seeds 1–3, failed with
`a provider CLI was spawned during a hermetic test`. The recorded spawn was
`args: ["app-server", "--stdio"]` against the guard's shim, so the real CLI
never ran. At head: 2 tests, 0 failures.

**Suite-wide.** G2 (§8.4) ran with logging `codex`/`claude` shims first on
`PATH`: **0** invocations of either. The same shim recorded 1 real launch at
`061a39e`, so it is a working positive control.

### 8.3 The CI failure: diagnosis, attribution, fixes

**Established (VERIFIED):**
- The failing run logged **11** `elf launch aborted` warnings; the passing run
  on the same SHA logged **10**. The one extra is this test's own Fake launch,
  which aborted about 10.04 s before the `recorded_pgid` wait expired.
- The CI log does not say why. `error_code` and `reason` were Logger
  metadata, and the default formatter prints none. The durable `run.failed`
  payload carried the code; the CI log, the only artifact left, did not.
- No database-side signature distinguishes the two runs. `database is
  locked` appears 6 times in each, from `WriterContentionTest`'s held lock.
  `spawn: Could not cd` appears 49 times in every run, both CI and local.

**Bounded reproduction protocol, fixed before running.** The runs used
scratch copies at `5cd9de4` (CI SHA) and base `d3fa152`, each with only
`config/test.exs` changed to print the abort metadata:

| Id | Copy | Command | Result |
|---|---|---|---|
| D1 ×10 | head | `mix test test/shoestring/elves/elf_lease_reloop_test.exs --seed 836743` | 10 of 10: 10 tests, 0 failures, 0 aborts |
| D2 ×2 | head | `mix test --seed 836743 --max-cases 6` | 2 of 2: reloop test green, 10 aborts each (all intended by their tests); 1 failure each in `Gate0AGitignoreTest`, an artifact of the copy (it has no `.git`) |
| D3 ×2 | base | same | 2 of 2: same as D2, with 1402 tests |
| D4 ×1 | head | `mix test --seed 836743 --trace` | reloop test green; the only failure is the copy artifact |

D4 also recovered the seeded module order. The failing module ran after
`CommandsIntegrationTest`, `SnapshotBindingTest`, `TaskClaimRaceTest` and
`RunLiveTest`: all pre-existing, all synchronous. That the sync order matches
CI's under `max_cases 6` is an INFERENCE.

**Attribution (REPO-INSPECTION).**
- On the failing test's pre-`run.running` path, this branch's only change is
  the writer's `mode: :immediate`.
- Under the test sandbox that change is inert:
  `Ecto.Adapters.SQL.Sandbox.Connection.handle_begin/2` prepends
  `mode: :savepoint`.
- The branch also retries `"Database busy"`, which is strictly additive.

Nothing on that path behaves differently from base under test. **The failure
is not attributed to this branch, and not proven to be pre-existing either:
0 of 14 local runs reproduced it at head or base.**

**Root cause: NOT established.** The strongest candidate is confirmed by
source and by nothing else:
- In OTP 28.3.1 `erl_child_setup.c`, the forker reports the child's `os_pid`
  to the BEAM right after `fork()`. The child calls `setsid()` only after the
  BEAM's acknowledgement, just before `execve`.
- `PortRunner.spawn/2` checked leadership with a single `ps` read as soon as
  the pid was known, so on a loaded host it can see the parent's pgid and
  abort a good launch as `not_group_leader`.
- **Hypothesis H1** stressed this, and both runs came back clean:
  - 400 spawns, 8 concurrent, idle and then with 2× cores CPU burners:
    400 of 400 ok each;
  - H1b: 1000 spawns, 32 concurrent, 4× cores burners: 1000 of 1000 ok.

**Fixes made (genuine defects, each on this path):**

1. **The abort log names its code.** `"elf launch aborted: <error_code>"`.
   The raw reason, which can carry host paths, stays in metadata.
   `elf_launch_abort_log_test.exs` is a **LOCK**: on base it fails with
   `left: "… [warning] elf launch aborted\n"`. It asserts both directions:
   the code is present, the path is absent.
2. **Leadership handshake** (`PortRunner`, and its twin
   `ClaudeHeadless.Transport`, which now uses the same wrapper).
   - The wrapper `setsid`s, verifies `getpgid(0) == getpid()`, writes one line
     `SHOESTRING-SETSID-READY <pid>`, and blocks for a go byte.
   - The launcher waits for that line, bounded by 15 s and fail-closed, and
     checks the pid in it.
   - It then runs the existing `ps` check while the child provably leads its
     group, and only then releases the wrapper to redirect stdin and `exec`.
   - No target output can precede or mix with the handshake line.

   `port_runner_handshake_test.exs` is **DOCUMENTATION**, not a race lock: the
   race could not be forced. On base it fails on the missing
   `handshake_prefix/0` and on the new `:handshake_timeout_ms` option.
3. **Exposed by (2):** `Elf.finish_after_stream/1` classified a runner whose
   group had already exited, but whose guaranteed `{:exit_status, _}` message
   had not yet arrived, as `missing_terminal_verdict`. Python's ~30 ms startup
   used to hide this window.
   - Evidence: with (2) alone, `ElfTest` "immediate OS exit classifies as
     signal exit" and one `OrchestratorTest` case failed (seed 553646).
   - The Elf now waits for that one message while its runner port is open;
     this is not a timer.
   - With the fix, `test/shoestring/elves`: 156 tests, 0 failures. No lock on
     base exists, since there python's delay masks the window.
4. **A defect in my own (2), found by gate G1 at `0cf9e2e`.** After a failed
   handshake, the killed wrapper's port could close itself before `spawn/2`
   ran its bare `:erlang.port_close/1`, which raised `ArgumentError`. Both
   failure branches now close safely and drain that port's messages. The test
   asserts the caller's mailbox is left empty.

**Open intermittent in the new handshake test file.** Tally after I fixed a
compile error in the test:

| Batch | Result |
|---|---|
| 20 fresh-VM runs | 1 failure (run 12, seed 873467) |
| 40 fresh-VM capture runs | 0 |
| 150 fresh-VM capture runs | 0 |
| 500 repetitions in one VM | 0 |

So it is **intermittent, 1 of 210 fresh-VM runs**. The failing run's output
was not captured: my loop kept only the counts. Its seed passed 3 of 3
reruns. The cause is unknown. No assertion was loosened and no retry was
added.

Also disclosed: an earlier batch of 20 runs all hit a compile error in that
test (a guard in `refute_received`), so they were not results and are
excluded.

### 8.4 Gates this round (protocol fixed before running; one run per SHA unless red)

| Id | SHA | Command | Seed | Exit | Elixir | Node gate_0a | UI |
|---|---|---|---|---|---|---|---|
| G1 | `0cf9e2e` | `mix precommit` | 620090 | **2** | 4 doctests, 1438 tests, **1 failure** (§8.3 fix 4), 1 skipped (6 excluded) | 52/52 | 7/7 |
| G1 | `4631f92` | `mix precommit` | 119330 | **0** | 4 doctests, 1438 tests, 0 failures, 1 skipped (6 excluded) | 52/52 | 7/7 |
| G2 | `4631f92` | `mix test --seed 836743 --max-cases 6`, logging provider shims first on `PATH` | 836743 | **0** | 4 doctests, 1438 tests, 0 failures, 1 skipped (6 excluded); 0 `codex` / 0 `claude` invocations; 10 launch aborts, each naming its code | — | — |

The commit that adds this section changes documentation only.

### 8.5 CI on the pushed heads (each run recorded, none re-run)

| Run | Event | SHA | Seed | Result |
|---|---|---|---|---|
| 36062658463 | push | `4631f92` | — | success |
| 36062663111 | pull_request | `4631f92` | — | success |
| 36062737245 | push | `eb015e6` | — | success |
| 36062741394 | pull_request | `eb015e6` | 624480 | **failure**: 4 doctests, 1438 tests, 1 failure, 1 skipped (6 excluded) |

So **3 of 4** CI runs this round are green. The red one is a different test
from §8.1: `ElfLeaseLoopTest` "refused renewal expires then checkpoints at the
boundary without interrupting the item" (`elf_lease_loop_test.exs:296`). Its
helper `grant_for_run!/4` asserts at `:739` that the lease is `active`, and
got `renewal_due`.

**Mechanism (REPO-INSPECTION; not reproduced).**
- The test grants a lease whose deadline is already 60 s in the past to an Elf
  that is still streaming Fake events, one every 200 ms.
- Between `Leases.grant/2` committing and the helper's projection, the Elf can
  ingest one event, load the new grant, and append `lease.renewal_due` for the
  passed deadline.
- The helper's projection then reads `renewal_due`.

**Attribution: INFERENCE, pre-existing.** The helper and the Elf's due path
are unchanged by this branch: its edits in that file only change the
renewal-id assertions of two other tests.

**Not fixed, and left OPEN.** Making it deterministic means changing that
precondition assertion, which is outside this round's scope and must not be
done by loosening it. The run's launch-abort lines each name their code, as
§8.3 fix 1 intended: 10 aborts, all intended by their tests.

## 9. CI-correction round on `2f15676` (recovery worker)

A previous worker stopped mid-round (during a CPU-stress experiment, not
repeated here). This round starts from the pushed head `2f15676`, changes only
CI/test correctness and the one product defect the CI evidence points at, and
makes **no live call**. The live evidence in §3–§4 still describes code SHA
`22c1e72`; nothing here re-verifies it, and **acceptance 8 stays OPEN**.

### 9.1 CI on `2f15676` (both red, neither re-run)

| Run | Event | Seed | Result | Failing tests |
|---|---|---|---|---|
| 36063516494 | pull_request | 557491, max_cases 6 | 1438 tests, **1 failure** | `ElfTest:954` (raised at `:998`) |
| 36063514995 | push | 609535, max_cases 6 | 1438 tests, **2 failures** | `ElfLeaseLoopTest:231` (`:276`), `OrchestratorTest:90` (`:133`) |

### 9.2 `OrchestratorTest:90`: an evidence probe took the Elf's `index.lock` (product fix)

**Failure.** The test's Elf child (a Python script) runs `git add` and
`git commit` in its worktree; the test waits 10 s for the commit and got
`{:error, :timeout}`. There was no launch-abort line, so the Elf did launch.

**Mechanism (VERIFIED locally, git 2.50.1).** `Staleness.collect/2` runs
`git status --porcelain=v1` and `git diff --stat` in that same worktree. When
any index entry's stat data is stale, both commands refresh the index and write
it back, holding `index.lock` while they do. A `git add` that runs in that
window fails at once with `index.lock: File exists` (exit 128). A scratch-repo
check showed which commands rewrite the index after a `touch`:

| Command | Rewrites the index |
|---|---|
| `status --porcelain=v1` | yes; not with `GIT_OPTIONAL_LOCKS=0` |
| `diff --stat` / `diff --name-only` / `diff HEAD` / `diff` | yes, **even with `GIT_OPTIONAL_LOCKS=0`** or `--no-optional-locks` |
| `diff --cached`, `rev-parse HEAD` | no |
| `-c diff.autoRefreshIndex=false diff --name-only` | no, but it lists stat-only-dirty files as changed, so the output changes |

The test calls `Staleness.collect(run_id, "manual_probe")` just as the child
starts committing.

**Attribution: INFERENCE.** The child's stderr is not in the CI log, so I
cannot show that this collision caused this particular timeout. It is the
only concurrent writer of that index I found. The same test passed in
36063516494 and passes locally in about 1 s.

**Fix.** `Shoestring.Worktrees.Git.observe/3` runs a read-only git command
against a private copy of the index (`GIT_INDEX_FILE`, plus
`GIT_OPTIONAL_LOCKS=0`) and then removes the copy. Output is identical and the
real index is never written. It is used by:
- `Staleness` (the evidenced site);
- its twins that also read a worktree the Elf may be writing to:
  - `TerminalCheckpoint`'s default git (reactive checkpoints are collected
    mid-run);
  - `Worktrees.changed_files/2` and `diff/2` (the run page calls these for a
    live run).

Limitation (REPO-INSPECTION): a repository using `core.splitIndex` keeps
shared index files next to the index, and those are not copied. No Shoestring
path enables it.

**Regression locks.** Each test makes the index stat-stale, then asserts both
directions: the index identity (inode, mtime) is unchanged and no `.lock`
exists, *and* the evidence still reports the modified and untracked files.
- `staleness_test.exs` "evidence reads a live worktree without writing its
  index";
- `terminal_checkpoint_test.exs` "collect_reactive/3 reads a live worktree
  without writing its index";
- `worktrees_test.exs` "changed_files and diff never write the index, and
  report the same files". This one also asserts that the stat-only file is
  *not* reported, which rules out the `autoRefreshIndex` variant.

**Base proof (VERIFIED).** I restored the three lib files from `2f15676`
(tests unchanged) and ran all three test files: **3 failures of 46**, each on
the index-identity assertion (inode changed). The output assertions before
that line passed on base, so the fix does not change reported output.

### 9.3 `ElfTest:998`: the crash simulation killed the Elf mid-query (test fix)

**Failure.** `DBConnection.OwnershipError: cannot find ownership process` for
the *test* process, raised at `Elves.reconcile/2`. The line logged just
before it: `Exqlite.Connection … disconnected: client #PID<…> exited`.

**Mechanism (REPO-INSPECTION of `db_connection` 2.10.2; VERIFIED by the lock
below).** The test simulates the app dying with `Process.exit(elf, :kill)`.
If the Elf is mid-query at that moment, it dies holding a checkout. In shared
sandbox mode the owner's `Ownership.Proxy` then shuts down ("client exited"),
the manager reverts the pool to `:manual`, and the test process's next query
has no owner. Production has no shared owner, so this is an artifact of the
test harness.

**Fix.** `ElvesHelpers.kill_idle/1` calls `:sys.suspend/2` and then sends the
same `:kill`. `:sys.suspend/2` returns only once the Elf is back in its
receive loop, where it holds no connection. For everything the test checks,
the kill is just as abrupt: the OS group survives, no terminal is written, and
no cleanup runs. All four `ElfTest` kill sites use it.

Out of scope: other `Process.exit(…, :kill)` sites under
`test/shoestring/harness/capacity/` show the same "owner/client exited" noise
in CI logs but did not fail. They are unchanged.

**Regression lock.** `kill_idle_test.exs` has an Agent hold a sandbox
transaction and kills it through the helper. The Agent is released once the
kill is either done or parked as a suspend request (a mailbox check, not a
timer). The test then asserts that its own `SELECT 1` succeeds.

**Base proof (VERIFIED).** With the helper body replaced by the bare
`Process.exit(pid, :kill)`, the test failed **3 of 3** runs:
- once with the exact CI error, `OwnershipError … cannot find ownership
  process`;
- twice with the same proxy's `ConnectionError "client … exited"`.

### 9.4 `ElfLeaseLoopTest:231` and `:296`: grant racing the event timers (test fix)

**Failures.**
- `:231`: `lease.renewed` was 0; `renewal_due` passed.
- `:296` (CI 36062741394, §8.5): the grant precondition read `renewal_due`.

**Mechanism (REPO-INSPECTION).** Every leased test starts the Elf, then
grants and projects the lease. Meanwhile the Fake events are already arriving
every 200 ms after `run.running`. If the grant lands after the boundary it is
meant to govern, the assertions fail. If the Elf loads the grant between the
helper's projection and its status read, the precondition fails.

**Fix.** Both CI failures and six other grant tests in the file share this
race. All eight now suspend the Elf as soon as `start_run` returns and resume
it once the lease is projected (`hold_before_first_event/1`,
`release_elf/1`). `start_run` returns after `init/1`, so the suspend is queued
behind the launch continuation. With `event_interval_ms > 0` that
continuation only *schedules* the first event, so the Elf ingests nothing
before the grant, however loaded the machine is. No assertion changed; the
precondition at `:739` is now deterministic rather than loosened.

**Coverage note.** `Elf.ensure_lease_bounds/1` still calls `rebuild_spend/2`
on first load, over the event just ingested. What this file no longer
exercises is a rebuild over events ingested *before* the grant; it was only
ever reached by chance. I did not check whether another file covers it
deterministically.

**Base proof (VERIFIED, delay injected for the proof only, not committed).**
A 600 ms `Process.sleep` before each `grant_for_run!` stands in for CI
scheduling delay:
- base test file: **6 failures of 9**, including the `:231`/`:296` family
  (`lease.renewal_due`/`lease.expired` counts 0);
- fixed test file with the same delay: **0 failures of 9**.

### 9.5 Still open

- **Handshake test intermittent** (§8.3): 1 of 210 earlier, output lost.
  This round: 0 of 25 sequential foreground runs of
  `port_runner_handshake_test.exs` at the working tree of `4153d1a`. There
  was no CPU stress, by instruction. The cause remains **unknown**; nothing
  was changed for it.
- `ElfLeaseReloopTest:419` (§8.3): root cause still not established.
- `OrchestratorTest:90` attribution is INFERENCE (§9.2).
- **The same grant-vs-timer shape, not changed (REPO-INSPECTION):**
  - `elf_lease_reloop_test.exs`, 5 sites;
  - `elf_checkpoint_resume_test.exs`, 5 sites;
  - `elf_claude_decline_quiescence_test.exs`, 2 sites.

  Each one starts the Elf with `event_interval_ms`, then waits for it to run
  and grants. None of them failed in the CI runs above. They were left alone
  because this round's scope is failures that were actually evidenced. The
  §9.4 gate should work for them too, but that is unverified.
- Acceptance 8 stays **OPEN**; no new live run.

### 9.6 Gates this round (one run per command; none re-run)

| Id | SHA | Command | Seed | Exit | Elixir | Node gate_0a | UI |
|---|---|---|---|---|---|---|---|
| G1 | `4153d1a` | `mix precommit` | 652405 | **0** | 4 doctests, 1442 tests, 0 failures, 1 skipped (6 excluded) | 52/52 | 7/7 |
| C1 | `4153d1a` | `mix test --seed 557491 --max-cases 6` (CI 36063516494's seed) | 557491 | **0** | 4 doctests, 1442 tests, 0 failures, 1 skipped (6 excluded) | — | — |
| C2 | `4153d1a` | `mix test --seed 609535 --max-cases 6` (CI 36063514995's seed) | 609535 | **0** | 4 doctests, 1442 tests, 0 failures, 1 skipped (6 excluded) | — | — |

The four new tests account for 1438 → 1442. The §8.4 provider-shim run (G2)
was **not** repeated this round. No launch path changed, but that is
REPO-INSPECTION, not a new measurement. The commit that adds this section
changes documentation only.

**Runtime identity.** This session's system prompt names the model
`claude-opus-5-5`. I have no runtime metadata to verify that, so it is
**UNVERIFIED**.

### 9.7 CI on `cbcb339` (code `4153d1a`; each run recorded, none re-run)

| Run | Event | Seed | Result |
|---|---|---|---|
| 36067413707 | push | — | success |
| 36067419163 | pull_request | 684726, max_cases 6 | **failure**: 4 doctests, 1442 tests, 1 failure, 1 skipped (6 excluded) |

So **1 of 2** is green. None of the three tests fixed in §9.2–§9.4 failed.
The red test is new to this record:
`TaskClaimRaceTest` "concurrent claim commands from competing goals produce
exactly one winner" (`task_claim_race_test.exs:49`). One of the two
concurrent `Commands.submit/3` calls raised `Exqlite.Error "database is
locked"` on `BEGIN IMMEDIATE TRANSACTION` (`commands.ex:102`).

**What the test does.** It uses its own scratch WAL SQLite database, not the
sandbox, with `busy_timeout: 2_000`. The second writer waits on the first
writer's immediate transaction.

**Attribution (REPO-INSPECTION).** Neither the test nor `commands.ex` changed
on this branch; their last change, `8ac3d71`, predates base `d3fa152`.

**Cause: not established.** A lock held past the 2 s busy timeout on a loaded
runner is a candidate. From the log I could not tell whether the error came
after the busy wait or at once, so this is **UNVERIFIED**.

**Local attempts:**
- the CI seed at CI concurrency (`mix test --seed 684726 --max-cases 6` at
  `4153d1a`): exit 0, 4 doctests, 1442 tests, 0 failures, 1 skipped
  (6 excluded);
- the file alone: 20 of 20 sequential runs green.

So: **intermittent, 1 of 3 runs of this code SHA** (2 CI runs and 1 local
full-suite run at that seed). **Not fixed**, and nothing was loosened.

### 9.8 CI on `ce74ebb` (docs only, code `4153d1a`), and the follow-up fix `06465c6`

| Run | Event | Seed | Result |
|---|---|---|---|
| 36068247668 | push | — | success |
| 36068253487 | pull_request | 752121, max_cases 6 | **failure**: 4 doctests, 1442 tests, 2 failures, 1 skipped (6 excluded) |

**`ElfTest:858` "cancel terminates the whole owned group": fixed in `06465c6` (test).**
- **Failure:** `{:error, :timeout}` waiting for two group members.
- **Cause (REPO-INSPECTION of `Elf.finish_after_stream/1`):** the test
  streamed `Scenario.normal_completion/0`, four events 50 ms apart ending in
  a `completed` verdict. On that verdict the Elf reaps the group itself. So
  the test had to see the Python spawner's child *and* cancel within about
  200 ms.
- **Attribution:** the test predates this branch (`acaa18f`, iteration 4).
- **Fix:** a stream with events but no verdict, like the file's other cancel
  tests. No assertion changed.
- **Proof (VERIFIED; the delay was injected for the proof only):** with a
  400 ms `Process.sleep` after the pgid read, the base test failed with
  exactly the CI shape (`right: {:error, :timeout}`) and the fixed test
  passed.

**`WriterContentionTest:129` "concurrent writers … behind one held lock all land once": OPEN.**
- **Failure:** one of four writers returned `{:error, {:retry_exhausted, :busy}}`.
- **Why it matters:** this is **this branch's own test** of the §1.2 writer
  fix.
- **CI log:** exactly four `BEGIN IMMEDIATE` "database is locked" lines, one
  per pool connection. Each failed `BEGIN` *disconnects* its connection. They
  landed at 25.77 s, 25.90 s, 29.50 s and 33.49 s. The other three writers
  committed at 25.79 s, 25.90 s and 29.61 s. The last writer then failed
  about 4 s apart twice more.
- **Cause: not established.** A second writer's commit (29.61 s) does not
  obviously account for a write lock held for 2 s. The interaction of
  reconnect backoff and the busy wait is a candidate, **UNVERIFIED**. One
  hypothesis, that SQLite was built without `HAVE_USLEEP` and so sleeps in
  whole seconds, is ruled out: the exqlite `Makefile` sets
  `-DHAVE_USLEEP=1`.
- **Local:** 20 of 20 sequential runs of the file green.
- **Status:** intermittent. It has been seen on CI once this round, and once
  before under `--trace` (§5, fixed then by `busy_timeout`). **Not fixed.**
  The reviewer should treat it as a possible defect in the writer's retry
  path under load, not only as test noise.

### 9.9 Gate at the final code SHA

| Id | SHA | Command | Seed | Exit | Elixir | Node gate_0a | UI |
|---|---|---|---|---|---|---|---|
| G1 | `06465c6` | `mix precommit` | 54410 | **0** | 4 doctests, 1442 tests, 0 failures, 1 skipped (6 excluded) | 52/52 | 7/7 |

Open intermittents after this round:
- `WriterContentionTest:129` (§9.8);
- `TaskClaimRaceTest:49` (§9.7);
- the handshake test (§9.5);
- `ElfLeaseReloopTest:419` (§8.3);
- the grant-vs-timer race in 12 further sites (§9.5).
