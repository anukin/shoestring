# Live production-path acceptance rerun (iterations 4/5, Go Tic-Tac-Toe)

Date: 2026-09-23. Branch `polly/iter5-live-production-rerun`, base
`0f96798403cbc02ee49f0f951b2f2c6964443ca2` (#79–#81 merged).

**Result: the production path is blocked before the receiver. No acceptance
gate closes. Iteration 6 stays locked.**

This rerun was supposed to drive the real Codex → Claude path end to end on
current `main`, run the three-arm ablation live, and measure handoff tax. It
ran on a production-configured node. It found three production defects on that
path, two of them deterministic. Per the brief, they are documented and **not**
patched or bypassed. So the Claude receiver never ran, the ablation never ran,
and no handoff tax was measured.

Claim labels follow this directory's `README.md` (`VERIFIED`,
`REPO-INSPECTION`, `SCHEMA-ONLY`, `UNVERIFIED`).

---

## 0. Gate status after this run

| Gate | Status | Why |
|---|---|---|
| Acceptance 7: a real cross-provider handoff on the production path | **OPEN** | Blocked twice before the receiver: §3.1 (no Claude observation ever reaches the configured probe) and §3.2 (the sender goal's projector wedges, so the canonical checkpoint is never a row). |
| Acceptance 8: semantic eval showing receiver behaviour and handoff tax | **OPEN** | No arm could reach a receiver on the production path. Nothing fixture-authored was substituted. |
| Iteration-4 hard dependency | Unchanged | Closed by #78 for the item it named. This run adds a third production defect in the same execution path (§3.3). |

## 1. Runtime model prerequisite (VERIFIED)

The brief required Claude Code on Opus 5.5, confirmed from runtime metadata
rather than self-identification. `~/.claude/settings.json` sets `model: opus`,
and `ClaudeHeadless` passes no `--model` flag (REPO-INSPECTION:
`claude_headless/session.ex:691`). The exact argv Shoestring uses was launched,
with `stdin` closed, and killed after its first stream-json frame:

    {'type': 'system', 'subtype': 'init', 'model': 'claude-opus-5-5',
     'claude_code_version': '2.1.281', 'apiKeySource': 'none'}

**What this does and does not prove.** It proves that the **receiver command**
Shoestring launches (`claude --print …`, no `--model`, resolved through
`~/.claude/settings.json`) resolves to `claude-opus-5-5` on this machine. It does
**not** prove the runtime model of the orchestrated worker (the agent that ran
this rerun and wrote this document). That worker's model is **UNVERIFIED** from
runtime metadata: its process argv carries no `--model` flag, and no model
environment variable is set. The harness-supplied session context names
`claude-opus-5-5`, but that is configuration text the worker was given, not an
observation. The worker resolving through the same `settings.json` is an
inference, not a measurement.

**Honest limit.** The process was killed after the `init` frame. I did not
verify whether an API request had already been sent. The receiver never ran
(§3), so no receiver `claude-headless:model` event exists to corroborate this.

## 2. What ran, and how

### 2.1 Node and scope

- `MIX_ENV=prod`, with a disposable `SHOESTRING_STATE_DIR` outside the source
  checkout, migrated with `Shoestring.Release.migrate/0`. A random
  `SECRET_KEY_BASE`. No web server (`PHX_SERVER` unset).
- Therefore everything production configures was live (VERIFIED, printed by the
  driver on every boot): `:handoff_observe` and `:wakeup_observe` =
  `{Shoestring.Cobbler.WakeupObserve, :observe, []}`; `:dispatch_effect` =
  `Shoestring.Harness.Dispatch.ElfEffect`; both capacity monitors enabled;
  Oban `dispatch/wakeup/handoff` queues executing (`testing: nil`); and the
  boot reconcilers running.
- One disposable Go repository: `example.com/tictactoe`, one baseline commit,
  under the manual-run allowed root. No production or user data.
- Source checkout untouched (VERIFIED: `git status --short` before and after
  shows only the two pre-existing untracked paths). One unrelated
  `codex app-server` process, started before this session from the user's
  checkout, was left alone.

### 2.2 Entry points (no bypasses)

`tools/live_eval/prod_rerun.exs` is the committed driver. It calls only product
entry points:

- **Task turns:** the real `/runs/new` submit handler,
  `ShoestringWeb.RunNewLive.handle_event("start_run", …)`, invoked in-process
  with the form's params. That is manual admission → `task.claim` → lease grant
  → durable dispatch → `Elves.start_elf`. **Disclosed limit:** the
  websocket/HTML transport is not exercised; the handler is.
- **Claim release:** a durable `task.release` Cobbler command.
- **Handoff:** `Shoestring.Cobbler.Handoffs.request/3`, i.e. the durable
  `run.handoff` intent plus its `handoff`-queue delivery. The live queue
  delivers it to `HandoffWorker` and the configured probe. The driver never
  calls `Handoffs.perform/3`, never injects an observation, and never appends an
  event.
- **Cancellation:** the operator's explicit `Shoestring.Elves.cancel_run/1`.

The driver reads stops from the committed trajectory, not from the run row,
because §3.2 leaves the row stale. Two harness-side changes were made during the
run and are disclosed: a 10-second settle after boot before submitting (§3.3),
and rescuing a raised exception from its own read-only `Projector.project/1`
call (§4.4).

### 2.3 Task and arm criteria, fixed before execution

- **Turn 1 (Codex):** implement only package `game`: `Player` with `X`/`O`,
  `New`, `Move` (0-based, errors for out-of-range, occupied and after-game-over),
  `Turn`, `Winner`, `Full`, `Render`, plus table tests. Standard library only,
  no CLI, then commit. Mechanical check: `gofmt -l .` empty, `go vet ./...` and
  `go test ./...` pass, the API surface is present.
- **Turn 2 (Codex), a second run from turn 1's commit:** only `parseMove`
  plus its tests in `main.go`. `game` stays unchanged.
- **Handoff:** from the latest Codex sender's canonical checkpoint (its Elf
  terminal checkpoint) to `claude` / `claude_headless_stream_json`, scope
  `subscription` (the Claude monitor's scope), `confirmation: {intent:
  supervised_execution}`. No `lease_policy`, so the merged durable default
  applies.
- **Receiver acceptance (planned, never reachable):** the full CLI. `X wins`,
  `O wins`, diagonal and `Draw` games end on that exact final line with exit 0.
  Invalid input prints a line beginning `invalid` and re-prompts.
  `go test ./...` passes and `game` is reused, not reimplemented.
- **Three arms (planned, never reachable):** comparable copies of the same
  sender state, handed off with (a) the worktree only, (b) a naive summary,
  (c) the trajectory projection. Handoff tax was to be the receiver's
  normalized events and commands before its first new-file write, repeated
  reads of already-complete files, and wall-clock milliseconds from
  `run.starting` to first write. Each would be reported per arm as
  `arm − trajectory-projection`, with units, and N=1 per arm stated as
  anecdotal.

**Interpretation flagged:** "second turn" is read as a second Codex run in the
same repository based on turn 1's commit. `/runs/new` creates a new goal per
submission, and the wake path (the only same-goal same-provider continuation)
would observe with scope `account:manual`, which no ledger reading carries
(REPO-INSPECTION of `Wakeups.observe_scoping/1`; not exercised).

### 2.4 Legs

| # | Leg | Terminal | Normalized events | Notes |
|---|---|---|---:|---|
| P0 | Fake sender + handoff (no provider) | `run.failed` `elf_launch_crashed` | 0 | proves §3.1 with zero model turns; the Fake crash is §4.2 |
| 1 | Codex turn 1 | `run.completed` | 323 | goal projector wedged at sequence 49 (§3.2) |
| 2 | Codex turn 2, attempt 1 | `run.failed` `transport/database_error` | 0 | no `run.starting`, no provider process (§3.3) |
| 3 | Codex turn 2, attempt 2 (one diagnosed retry) | `run.failed` `transport/database_error` | 0 | same (§3.3) |
| 4 | Handoff from turn 1 | command **rejected** `handoff_checkpoint_not_found` | – | no delivery attempt, no receiver (§3.2) |
| 5 | Codex cancel probe, attempt 1 | `run.cancelled` after crash recovery | 62 | §4.1 |
| 6 | Codex cancel probe, attempt 2 | `run.failed` `transport/database_error` | 0 | §3.3; provider attempts stopped here |

All values are VERIFIED from the run database. Transcripts:
`fixtures/live-prod-rerun/`.

## 3. Production defects that block the genuine path

### 3.1 BLOCKER — no Claude observation ever reaches the configured handoff probe (VERIFIED)

`HandoffWorker` observes the receiver through `WakeupObserve.observe/1`, which
reads only the Observatory ledger. In the production configuration nothing
writes a Claude reading into that ledger:

- `ClaudeMonitor` ingests only on a statusLine callback
  (`receive_status_line/3`), and `lib/` has no caller of it. The router has no
  statusLine route (REPO-INSPECTION: `router.ex`; a grep for
  `receive_status_line` in `lib/` finds only the definition).
- Its `auto_ingest_initial` option defaults to `false`, and `config/config.exs`
  sets `claude: [enabled: true]` only.
- Running `ClaudeHeadless` does not feed the ledger (REPO-INSPECTION: no
  `Observatory` reference under `harness/claude_headless*`).

Observed on the node 45 s after boot (VERIFIED): the ledger holds exactly one
reading, `codex / subscription / degraded / proactive`. `ClaudeMonitor.status/0`
reports `callback_count: 0` with the pre-first-response reason. A durable
`run.handoff` intent with a valid owner-derived confirmation resolved to
`handoff_requested`. The live `handoff` queue then delivered it to
`HandoffWorker`, which failed with

    {:error, {:observation_failed, :no_observation_for_provider}}

on every attempt observed. There was no `handoff.created`, receiver run, lease
or dispatch. The goal still projects `:ok`. The failure is classified
retriable, so the intent stays unsettled and `HandoffReconciler` re-enqueues it
on every boot. It can never succeed.

This is why #79's D1 fix did not make the path work live: #79 tested the
`:prod` MFA against a ledger its tests populated (`ingest_eligible!/0`), and the
deployed node never populates it for Claude.

**Not fixed.** Choosing how a Claude reading should reach the ledger is a
product decision:

- enable `auto_ingest_initial`, which yields an honest `unknown /
  conservative_partial` reading that admission turns into
  `require_confirmation`, answerable by the intent's confirmation;
- add a statusLine route;
- or let headless runs report.

Enabling any of these here would have been a scratch replacement of the
configured component.

### 3.2 BLOCKER — the Elf's lease-renewal boundary wedges the sender goal's projector (VERIFIED)

This is the D1 twin, in a third path. #79 re-identified the handoff probe's
ledger snapshot to a goal-local id. The **lease renewal** path still re-appends
the Observatory-owned snapshot under the work goal with its original id:

1. `RunNewLive`'s manual admission proposes `checkpoint_cadence: 1`, so the
   lease is `renewal_due` after the first response (turn 1: `lease.renewal_due`
   at sequence 49, 4.3 s after `run.starting`).
2. At the safe boundary the Elf probes through `CodexAppServer.probe/1` →
   `CodexMonitor.observe/1`. That returns the monitor's current snapshot, which
   the monitor has already ingested into the ledger under the protected
   Observatory goal (REPO-INSPECTION: `codex_app_server.ex:468`).
3. `LeaseRenewal.persist_renewal_snapshot/5` appends it as
   `capacity.snapshot_observed` under the work goal with the **same** id
   (sequence 50, idempotency key `lease-renewal-snapshot:<lease>:<snapshot>`).
4. `Projector.project/1` refuses it, and the goal's `harness` projector is left
   at `{49, "failed"}` with `{:capacity_snapshot_not_owned, <snapshot id>}`.
   VERIFIED: the snapshot row's `goal_id` is the Observatory goal, and the same
   id appears at Observatory sequence 1 and work-goal sequence 50.

Consequences observed on turn 1 (VERIFIED):

- renewal "failed at boundary" 14 times in the node log, and the Elf worked on;
- `run.completed` and the terminal `checkpoint.created` were committed but never
  projected, so the run row still reads `running`;
- no `CheckpointRecord` exists for the canonical checkpoint, so the durable
  `run.handoff` request is **rejected at request time** with
  `handoff_checkpoint_not_found` (`Commands.validate_handoff_reference/3`).
  There was no delivery attempt and no receiver.

With the monitor running (the prod default) and a Codex manual run reaching its
first boundary, this is deterministic by inspection. It happened on the one
Codex run that got past launch and reached a boundary with a response.
UNVERIFIED: the recovered cancel-probe run (§4.1) did **not** wedge; it recorded
no `lease.renewal_due` in its 15 s. I did not establish why.

**Not fixed.** The repair belongs with #79's `localize_snapshot/3`, applied in
`LeaseRenewal` (and in `Wakeups.persist_snapshot/6`, which #79 already flagged
as an untraced twin). The brief forbids patching it to claim acceptance.

### 3.3 DEFECT — "Database busy" is never recognised as retryable, so launches fail (VERIFIED)

Three of the five Codex runs started through `/runs/new` failed before
`run.starting`: `run.failed` with `transport/database_error`, 0 normalized
events, and no provider process. The Elf's `abort_launch/3` log (logger
metadata enabled by the driver) carries the reason:

    {:database_error, "Database busy\nINSERT INTO \"trajectory_events\" …"}

`Shoestring.Trajectory.Writer.database_error/1` classifies an error as
retryable `:busy` only if the message contains `"database is locked"`,
`"database table is locked"` or `"SQLITE_BUSY"` (REPO-INSPECTION:
`writer.ex:441`). Exqlite's message is `"Database busy"`, so the writer's retry
loop never fires, and the first contended append aborts the launch.

The error arrived ~17–20 ms after `dispatch.requested`, well inside the 2 s
`busy_timeout`. That fits a lock-upgrade conflict, which SQLite does not wait
on. **The concurrent writer was not identified.** The same message appears in
this repository's known test intermittents (`LeaseGrantTest`,
`ElfTerminalCheckpointTest`); the connection is suggested and not verified.

Rate on this node: **intermittent, 3 of 5 launches.** The 10 s post-boot settle
added after the first failure did not help (2 of 3 afterwards). Provider
attempts were stopped after the third failure rather than retried until green.

## 4. What was established

### 4.1 Crash recovery and explicit cancellation of a live Codex Elf (VERIFIED)

Cancel attempt 1 launched: `run.starting` was committed and the Codex process
started. Then the driver's own `Projector.project/1` call raised a raw
`Exqlite.Error` "Database busy" (§4.4), which crashed the script and stopped the
node before `run.running`. On the next boot, which was intended only to cancel
the stranded run:

- the live `dispatch` queue delivered the pending job, and `DispatchWorker` →
  `ElfEffect` started **exactly one** Elf for the run (dispatch
  `effect_completed`). It reached `run.running` and 62 normalized events. This
  was unplanned provider use (~15 s, same task, within the authorization),
  disclosed here;
- `cancel_run/1` with that Elf registered → `{:ok, :cancelled}`, lifecycle tail
  `run.cancelling` → `checkpoint.created` → `run.cancelled`, exactly one
  `run.cancelled`, and the run row `cancelled` with the projector `ok` at 76;
- a second `cancel_run/1` → `{:ok, :already_terminal}` with no new terminal;
- no timer, lease deadline, heartbeat or staleness signal was involved.

**Limits:** process-group liveness was not measured before this cancel. The
group recorded on `run.running` was dead when checked, but only after the node
had exited, so its death is not attributable to the cancel alone. The planned
before/after group check (attempt 2) never ran because that launch failed
(§3.3). #78's measured owned-group cancellation (test env) remains the only
direct evidence of group reaping.

### 4.2 Stop paths actually exercised

| Stop path | Exercised | Evidence |
|---|---|---|
| normal completion → terminal checkpoint + `run.completed` | yes (turn 1) | committed; **not projected** (§3.2) |
| launch failure before `run.starting` → `checkpoint.created` + `run.failed` | yes ×3 (Codex) + P0 (Fake) | projects `ok` (#78's `requested → fail` edge holds live) |
| node crash after `run.starting` → durable redelivery → one Elf | yes | §4.1 |
| explicit cancel with a live Elf | yes | §4.1 |
| explicit cancel, idempotent second call | yes | §4.1 |
| lease decline → suspend → wake | **no** | renewal never reached a decision (§3.2) |
| quota refusal / reactive checkpoint | **no** | not triggered |

### 4.3 Turn-1 artifact (VERIFIED)

`fixtures/live-prod-rerun/go-verification.txt` holds the verbatim output. One
commit on the baseline, a clean tree, `gofmt -l .` empty, and `go vet` and
`go test -count=1 ./...` pass with 35 `=== RUN` entries. The required API
surface is present, and there is no `main.go`, as instructed. Normalized
ordinals are contiguous `1..323`. The Elf logged one "dropped harness event"
warning; no persisted ordinal is missing, and the warning's cause was **not**
established.

### 4.4 Observations, not blockers

- **Fake in prod.** `/runs/new` with provider `fake` crashes at launch in prod
  (`Fake adapter requires opts[:scenario] as a Scenario struct`, seen once with
  a local diagnostic `IO.puts`, reverted and not committed). It is irrelevant to
  the provider path; noted for the UI owner.
- **Duplicate delivery is handled.** `RunNewLive` starts the Elf directly *and*
  enqueues the dispatch job. On turn 1 the worker then recorded
  `dispatch.effect_deferred` (`run_state_advanced`), so no second Elf started.
- **`Projector.project/1` can raise.** It raises a raw `Exqlite.Error` on busy
  rather than returning an error tuple. That crashed the driver once (§4.1).
- **The first `mix ecto.migrate` failed.** In prod on a fresh state dir, the
  first run failed partway through (the first error was not captured). The rerun
  then failed with `table harness_capacity_windows_v2 already exists`.
  `Shoestring.Release.migrate/0` on a fresh DB succeeded. Recorded, not
  diagnosed.

## 5. Durable handoff policy actually in force (VERIFIED)

`HandoffLeasePolicy.default/0` on this node:
`deadline_seconds: 2700, response_budget: 10, tool_budget: 25,
checkpoint_cadence: 1, reserves: {response: 1, tool: 1}`. The intent carried no
`lease_policy`. No receiver lease was ever granted, so none of these bounds was
exercised live.

**UNVERIFIED, flagged for whoever unblocks §3:** a `response_budget` of 10 with
reserve 1 would make a Claude receiver `renewal_due` after about 9 responses,
and the 2700 s deadline would never be reached first.

## 6. Handoff tax

**Not measured.** No receiver ran on any arm. The formula fixed in §2.3 is
recorded so the next run measures exactly that. No fixture-authored number is
substituted.

## 7. Evidence and redaction

| File | Backs |
|---|---|
| `fixtures/live-prod-rerun/normalized-codex-turn1.md` | §2.4 leg 1, §3.2 (renewal snapshot at the lifecycle position, `run.completed`), §4.3 ordinals |
| `…/normalized-codex-turn2-attempt{1,2}.md`, `…/normalized-codex-cancel-attempt2.md` | §3.3: `checkpoint.created` → `run.failed`, no `run.starting`, 0 normalized events |
| `…/normalized-codex-cancel-recovered.md` | §4.1 |
| `…/go-verification.txt` | §4.3 |
| `…/production-rerun-summary.json` | node config, model frame, ledger, P0 worker errors, per-leg outcomes |

`tools/live_eval/export_evidence.py` produced the transcripts from the run
database, read-only. Redaction is applied to the **reassembled** delta stream
and then to each whole line, and every substitution is same-length:

- worktree paths → `$WORKSPACE`, other host paths → `$REDACTED_PATH`;
- UUIDs → the declared synthetic series (v7 keeps its version nibble);
- `pgid:` digits → `x`;
- the operator login name → `$USER` (found by a reassembled-text scan in
  captured `ls -l` output, then added to the exporter).

Item ids, cwd, provider session ids and source event ids are omitted. No
reasoning content exists in these runs; Codex emitted none, and no Claude run
happened. `live_evidence_redaction_test.exs` now also globs
`fixtures/live-prod-rerun/*`.

## 8. What would unblock acceptance 7/8

In order:

1. §3.2 — localize the renewal (and wake) snapshot the way #79 did for handoff.
2. §3.1 — decide and implement how a Claude reading reaches the ledger in the
   deployed configuration.
3. §3.3 — classify `"Database busy"` as retryable in the trajectory writer.

Then rerun this driver unchanged: turn 1, turn 2, handoff, three arms, cancel.
Until all three are fixed, a live run on the production path cannot reach the
receiver. **Iteration 6 must not start.**

## 9. Gate

Command, run in this worktree with a fresh `SHOESTRING_TEST_STATE_DIR` each
time: `mix precommit`. Two runs, both exit 0 (VERIFIED):

| Run | Elixir | Node (`gate_0a`) | Node (UI) |
|---|---|---|---|
| 1 | 4 doctests, 1402 tests, 0 failures, 1 skipped (6 excluded) | 52 / 52 pass | 7 / 7 pass |
| 2 | 4 doctests, 1402 tests, 0 failures, 1 skipped (6 excluded) | 52 / 52 pass | 7 / 7 pass |

No intermittent was observed in these 2 runs. That statement covers these 2
runs only. The independent review run below was red.

### 9.1 Independent exact-SHA gate: RED (reported by the reviewer, not reproduced away)

At `1a00cb9`, an independent `mix precommit` exited **2**:
`4 doctests, 1402 tests, 1 failure, 1 skipped (6 excluded)`, Node 52/52 and
UI 7/7. The failure (ExUnit seed 630171) was:

    test killing the Claude monitor leaves Codex and the observatory UI healthy
      (Shoestring.Harness.Capacity.DisconnectEvalTest)
      disconnect_eval_test.exs:128  CodexMonitor.status(codex_pid)
      left: :sink_error   right: :connected

**Diagnosis: an existing intermittent, not caused by this branch (VERIFIED as
far as stated below).**

- **The branch cannot reach that code.** `git diff --stat 0f96798 1a00cb9`
  touches no file under `lib/` or `config/`. The only test change is
  `live_evidence_redaction_test.exs`, which reads committed files, touches no
  database and starts no process.
- **Mechanism, from the reviewer's log.** Just before the failure, the Codex
  capacity sink logged `rejected snapshot: {:database_error, "Database busy
INSERT
  INTO "trajectory_events" …"}`. A leaked `:healthy_codex_storm` monitor from
  `SupervisionStormEvalTest` was still holding a sandbox connection at that
  moment. That is the residual race `prod-handoff-lease-policy.md` already
  records for CI. A busy `Observatory.ingest` in the test's sink makes
  `CodexMonitor` report `:sink_error` instead of `:connected`. The busy error
  is non-retryable only because of §3.3's misclassification (`Trajectory.Writer`
  does not recognise `"Database busy"`), a production defect this PR reports
  and, per scope, does not fix.
- **Bounded head/base checks** in an additional isolated worktree at base
  `0f96798` (and this worktree at head `1a00cb9`), fresh state dir each time:

| Check | Head `1a00cb9` | Base `0f96798` |
|---|---|---|
| `mix test --seed 630171` (full suite, 1 run each) | exit 2: 1402 tests, **1 failure**: `ObservatoryTest` `observation_summary returns exact windows…`, `{:database_error, "Database busy …"}` from `Observatory.ingest` | exit 2: 1402 tests, **1 failure**: `ElfTerminalCheckpointTest` `interrupted run checkpoints…`, `Exqlite.Error Database busy` in setup |
| `disconnect_eval_test.exs` + `supervision_storm_eval_test.exs` together, ×5 | 5 of 5 green (4 tests, 0 failures) | 5 of 5 green (4 tests, 0 failures) |

  The seed does not reproduce the same test, because the timing is
  load-dependent. Every observed failure, the reviewer's and both of mine, head
  and base, is SQLite `Database busy` under full-suite concurrency. Base fails
  the same way without this branch.

**Hard limitation.** The gate is **not reliably green** at this SHA or at its
base. Across the full-suite runs recorded here the tally is **3 of 6 red**:
the independent run, the seeded head run and the seeded base run, against the
two green precommit runs above and one green exact-SHA `mix precommit` on the
fix-round commit `51b25fd` (seed 268673, exit 0, 4 doctests, 1402 tests,
0 failures, 1 skipped (6 excluded), Node 52/52, UI 7/7). That commit changed
documentation and evidence only. The red runs span head and base. No test was
retried to green, skipped, slept on, or had an assertion weakened, and no fix
was made: the fault is not introduced by this PR, and its root (§3.3 plus the
storm test's connection leak) is out of this round's scope. The two green runs
are real, but they do not make this SHA green. No test was added. The one test
changed is `live_evidence_redaction_test.exs`: it gained the new fixture glob,
and its "reassembled to nothing" stale-parser guard now applies only to
transcripts that declare more than 0 normalized events. Three committed
transcripts honestly declare 0.

A mutation check shows the scans still bite on the new directory. A copy of
the turn-1 transcript with `/Use` + `rs/x` planted in two consecutive deltas
failed with `[delta stream]: absolute host path (reassembled) found at offset
7`. The copy was then removed.

The skipped test and the 6 exclusions are unchanged: the capability-appropriate
`:resume` skip and the `@tag :live` smokes. The live work above ran outside the
gate, through `tools/live_eval/prod_rerun.exs`.
