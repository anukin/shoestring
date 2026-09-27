# Iteration-5 live closeout: one bounded Go Tic-Tac-Toe sequence on merged `main`

Branch `polly/iter5-live-closeout-opus`, base `1566acd` (#84 merged). This is
the single live sequence that `final-acceptance.md` §8.4 left pending: the
fixes for findings 1, 2, 3, 4 and 6 had been locked hermetically but never run
live. Claim labels follow this directory's `README.md`. An explanation that was
not isolated is marked **INFERENCE**.

**No source, test or driver file was changed.** This branch adds evidence
only: this file, five fixtures in `fixtures/live-final/` (`closeout-*`), a
pointer in `final-acceptance.md` §9, a milestone addendum, and a README line.

## 0. Result

| Contract item | Status | Where |
|---|---|---|
| Every phase records its actual code identity (finding 6) | **VERIFIED**: 6 of 6 phase records carry `code.sha = 1566acdaa1e2…`, `dirty: false`, `status_lines: []` | §3 |
| Production-path cross-provider handoff completes; fixture checks pass | **VERIFIED**. Codex sender, then `Handoffs.request/3`, then the live `handoff` queue, then `HandoffWorker` with the `:prod` probe. Owner-confirmed admission, receiver lease, live `dispatch` queue, Claude Elf, `run.completed`. Job attempt 1, no errors. Every M1 check passed, C1 0 violations, R1 honoured | §4 |
| Claude receiver model is `claude-opus-5-5` | **VERIFIED from the receiver's own `system`/`init` frame** (the only frame that carries a model): `claude-opus-5-5` | §4 |
| Settled replay adds zero new jobs (finding 4) | **VERIFIED, compared explicitly**: handoff jobs 1 → 1 (**0 new**); runs in goal 2 → 2 (0 new); `handoff.created` stays 1; the replay resolved to the original receiver with `job?: false` | §6 |
| Manual-scope wake settles once as `require_confirmation` / `manual_scope_not_resumable`, with no duplicate decision or dispatch (finding 1) | **NOT EXERCISED.** The lease-stop run never declined: no `lease.expired`, no `run.suspended`, so no `lease_decline_recheck` wake was scheduled. 0 wakeup rows, 0 wakeup jobs, 0 wake decisions. The absence of duplicates is vacuous. Finding 1 stays **LIVE-UNVERIFIED** | §5 |
| A declined run's session status is recorded and tells a missing session apart from a valid completion (finding 2) | **Partly.** No run declined, so the declined case did not arise. The one stopped run ended `run.interrupted` from Codex's own `interrupted` result, not a completion. `session_at_end` was recorded as `{"session": "none"}` after that terminal. `session_status` covers Codex only, not Claude (REPO-INSPECTION of the driver) | §5 |
| Checkpoint reports unfinished items (finding 3) | **VERIFIED live**: the terminal checkpoint names the one item with a recorded start and no completion (`not completed: command … ordinal 134 (start recorded, no completion recorded before this checkpoint)`) | §5 |
| Lease stop at a safe boundary | **Not met. New finding.** The first event after the 60 s deadline was a Codex command START (a heredoc that writes files). `lease.renewal_due` was appended 19 ms later. The turn was then **interrupted 2.5 s later with no completion recorded for that command**. The renewal/decline sequence never ran: no `lease.expired`, no suspend, no wake, and the lease row is still `active`. The command's files are on disk, uncommitted. Mechanism not established | §5, §7 |
| Source checkout untouched | **VERIFIED**: identical read-only snapshot before the first boot and after the last | §8 |
| Gate | See §9 (measured on the committed evidence tree) | §9 |

Finding 2's original trigger (a decline at a tool START that left a run
`suspended` with no terminal) was removed by `2fe62ab` before this run.
Nothing here reproduces it, and this record claims no reproduction.

Acceptance 8 was **not re-run** (§10).

## 1. Authorization and budget

The user's instruction was: "for 1, use claude and check everything with
opus-5.5". It authorized ONE bounded sequence, `setup → turn1 → turn2 →
handoff → lease_stop → audit`, with the existing driver bounds. It authorized
no ablation arms, retries or extra trials. Spent: exactly that sequence, each
phase once, with 3 Codex runs and 1 Claude run. `selftest` (no provider) was not
run: it is not in the authorized list. No phase was repeated.

## 2. Setup, bounds and environment

**Isolated state (VERIFIED).** A fresh `mktemp -d` state directory under the
per-user temp root, never the user's
`~/Library/Application Support/Shoestring`. The database was built as §8.1
requires, not with `mix ecto.migrate`:

    MIX_ENV=prod SHOESTRING_STATE_DIR=<fresh dir> SECRET_KEY_BASE=<random> \
      mix run --no-start -e 'Shoestring.Release.migrate()' < /dev/null

It applied 16 versions (`20260830012112`…`20260919034454`), exit 0. A rerun
printed `Migrations already up`. `SECRET_KEY_BASE` was random per sequence and
is not committed.

**Build.** `deps/` was copied from the source checkout (a read-only copy;
`mix.lock` byte-identical) and compiled with `MIX_ENV=prod` in this worktree.
The worktree stayed clean (`git status --porcelain` empty), and the per-phase
code identity confirms it.

**Driver bounds, inspected before running** (REPO-INSPECTION of
`tools/live_eval/final_acceptance.exs` at `1566acd`):

| Phase | Provider | Run bounds (form → `/runs/new` or lease policy) | Driver waits |
|---|---|---|---|
| setup | none | `go vet` / `go test` 120 s each | — |
| turn1, turn2 | Codex | timeout 900 s, max events 4000, manual lease 300 s | stop 900 s |
| handoff | Claude receiver | lease policy: responses 150, tools 300, cadence 150, reserves 1/1, deadline 2700 s | delivery 480 s; run created 300 s; stop 2800 s; each Go check 300 s, each game 10 s |
| lease_stop | Codex | manual lease **60 s**, timeout 900 s, max events 4000 | stop 900 s; wake observation 150 s; any continuation: ready 300 s, stop 180 s, then explicit cancel |
| audit | none | replay + 10 s settle | — |

Every phase also sleeps a 10 s boot settle (`LIVE_SETTLE_S`). No bound was
hit (§3).

**Capacity before spend (VERIFIED, ledger read-only after `setup`'s boot).**
Codex: `degraded` / `proactive` (CLI 0.157.1 is untested), plan `plus`,
primary window 21 % used, secondary 3 %. Claude: `unknown` /
`conservative_partial`
(`rate_limits_absent_before_first_response_or_unsupported_subscription`).
Claude capacity cannot be read without spending, so the handoff went through
the product's owner-confirmation contract, as in #83/#84. The receiver
reported five-hour utilization 0.08 → 0.10 in its own frames.

**Deviations, disclosed:**

1. **turn1 ran as a harness-tracked background command** (outer bound
   1200 s). The Bash tool caps a foreground command at 600 s, below the
   driver's 900 s wait, and a tool timeout would have killed a live Elf. The
   standing contract says to run every command in the foreground. The
   operator then ruled out further background launches. turn1 was not
   relaunched or killed: it was awaited to its own exit (exit 0, 144 s).
   **Every later phase ran in the foreground with an outer `timeout` of
   590 s** (300 s for audit). That is below the driver's own 900 s and
   2800 s waits, so the 590 s cap was the binding bound for turn2, handoff and
   lease_stop. None reached it: 100 s, 70 s, 269 s.
2. **Environment.** The node ran with this Claude Code session's link and
   identity variables removed (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`,
   `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`,
   `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`,
   `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_CODE_EXECPATH`, `CLAUDE_PID`,
   `CLAUDE_EFFORT`, `AI_AGENT`, two `CLAUDE_CODE_DISABLE_*` UI flags). The
   receiver CLI therefore ran as it would from the operator's shell, and was
   not attached to the orchestrating session. The CLI gets no `--model`
   (REPO-INSPECTION, `ClaudeHeadless.build_argv/2`). The model came from the
   operator's settings (`opus`), and the receiver's `init` frame reported
   `claude-opus-5-5`.

## 3. Phases and code identity (VERIFIED, committed summary)

| # | Phase | Recorded at (UTC, 2026-09-27) | `code.sha` / dirty | Wall | Outcome |
|---|---|---|---|---|---|
| 0 | setup | 03:40:26 | `1566acd…` / false | 12 s | baseline `7abe915`; `go vet` exit 1 (`copylocks` in `legacy/scoreboard`), `go test` exit 0 |
| 1 | turn1 | 03:43:08 | `1566acd…` / false | 144 s | Codex `…002`: `run.completed`, 369 normalized events, head `47e3b26`, clean |
| 2 | turn2 | 03:45:03 | `1566acd…` / false | 100 s | Codex `…006`: `run.completed`, 344 events, head `d23fdaa`, clean; claim kept for the handoff |
| 3 | handoff | 03:46:18 | `1566acd…` / false | 70 s | `handoff_created`; Claude `…009`: `run.completed` (§4) |
| 4 | lease_stop | 03:50:54 | `1566acd…` / false | 269 s | Codex `…014`: `run.interrupted` without a decline (§5) |
| 5 | audit | 03:52:36 | `1566acd…` / false | 21 s | replay converged with 0 new jobs; 4 invariants true (§6) |

Every phase exited 0 and wrote exactly one `RESULT` line, so no node boot went
unrecorded. Run ids are the synthetic `55555555-0000-4000-9000-…` series of
the committed fixtures.

## 4. Handoff (acceptance-7 path), VERIFIED from committed events

- **Request.** The driver called `Handoffs.request/3` once. The command was
  `resolved` with `confirmation.confirmed_by: owner:…`, intent
  `supervised_execution`, target `claude`/`subscription`, and the per-transfer
  lease policy above. The `handoff` job ran once (`completed`, attempt 1 of 5,
  no errors). The worker's probe was the configured
  `{Shoestring.Cobbler.WakeupObserve, :observe, []}` (phase log). The driver
  never calls `Handoffs.perform/3`, injects an observation, appends an event
  or calls the projector (REPO-INSPECTION).
- **Order.** The goal's event order after the sender's `run.completed` was
  `cobbler.command.accepted → capacity.snapshot_observed →
  admission.decided → run.requested → lease.proposed → lease.granted →
  lease.active → handoff.created → dispatch.requested → run.starting →
  run.running → checkpoint.created → run.completed`.
- **Latency (H).** Command row → `handoff.created` 45 ms → receiver
  `run.starting` 361 ms → `run.running` 896 ms.
- **Receiver model.** The one `system`/`init` frame reports `claude-opus-5-5`.
  The other 28 `system` frames are `thinking_tokens` counters with no model
  and no content. `tax.receiver_models = ["claude-opus-5-5"]`.
- **Receiver behaviour (M5–M7).** 50 normalized events, 6 tool starts (all
  `Bash`), 7 CLI turns, notional `total_cost_usd` 0.275 (subscription, not a
  charge), 55.8 s run. Before the first mutation: 2 tool starts, 1 verify
  command, 1 `game/` read. First mutation at 21.0 s: a `sed -i` fixing the
  `legacy/scoreboard` value receiver, then the `main.go` loop. 0 `mix`
  commands. Prompt: 3 088 characters.
- **Fixture checks (M1–M4).** The checks ran on the sender worktree after the
  receiver, head `ce983d9` ("Complete the game loop and fix go vet in legacy
  scoreboard"), clean. `gofmt` clean; `go vet`, `go test -count=1` and build
  pass. All 5 scripted games pass (`X wins`, `O wins`, `X wins`, `Draw`,
  `X wins` with ≥3 `invalid` lines). `game/` is unchanged since turn 1 and
  `main.go` imports `game`, so **acceptance: true**. C1: 0 violating lines.
  R1: `legacy/` present, listed, untagged, and vet passes. M4 rework: 1
  deleted line.

This is the first live handoff since #84's fixes (`b474253`, `4d5975e`,
`6080764`, `0750ff5`, `8d91f80`) and the `2fe62ab` `LeaseBounds` change. §3.3
of `final-acceptance.md` could only say the tip's handoff path "did not run
live". It has now run live, at `1566acd`.

## 5. Lease stop (VERIFIED from committed summary + read-only DB)

Run `…014`, Codex, 60 s manual lease (deadline 03:47:36.64), prompt: the
`engine/` + `DESIGN.md` task.

| Time (UTC) | Seq | Event |
|---|---|---|
| 03:46:36.85 | 11 | `run.running` |
| 03:47:01.607 | 145 | last event before the gap (an `agentMessage` output) |
| 03:47:36.64 | — | lease deadline passes; no event arrives for 80 s |
| 03:48:21.476 | 146 | Codex command **START** (`inProgress`): `mkdir -p engine && cat > DESIGN.md <<'EOF' …` (a compound heredoc write) |
| 03:48:21.495 | 147 | `lease.renewal_due` |
| 03:48:22.482–24.019 | 148–151 | token-usage / rate-limit updates |
| 03:48:24.021 | 152–153 | `thread/status/changed: idle`; turn result `interrupted` (`codex-app-server:interrupted: true`, turn duration 107 179 ms) |
| 03:48:24.236 | 154 | `checkpoint.created` (terminal, `checkpoint-fallback-v1`, no model) |
| 03:48:24.240 | 155 | `run.interrupted` |

What this shows:

- **No completion was recorded for the command started at seq 146.** The
  turn was interrupted 2.5 s after `renewal_due`. Only Shoestring drives this
  app-server session, and the driver issued no cancel in this phase
  (`continuation: null`, no `cancel_run/1`). The interrupt therefore came from
  the Elf's lease safe-stop path (INFERENCE, strong: the only other
  `turn/interrupt` sender is explicit cancellation). The Codex
  `Session.request_safe_stop/1` contract is to defer the interrupt until the
  in-flight item's `item/completed` (REPO-INSPECTION,
  `codex_app_server/session.ex`). Either the session did not consider this
  item in flight, or its completion was not delivered. Raw provider frames
  are not retained, so **the mechanism is not established**. A possible cause
  (UNVERIFIED): `in_flight_item` is one slot, cleared by any
  `item/completed`, including items the normalizer does not record.
- **The renewal/decline sequence never ran.** It runs only at an
  `item.completed` boundary (REPO-INSPECTION, `Elf.renew_path/2`), and none
  followed. So there was no `lease.expired`, no `run.pausing` /
  `run.suspended`, no `lease_decline_recheck` wake, and the
  `ExecutionLeaseRecord` is still `active` after the terminal (responses
  2/4000, tools 5/4000).
- **Files on disk.** The worktree holds untracked `DESIGN.md` (5 810 bytes)
  and `engine/position.go` + `engine/position_test.go`, uncommitted at
  `d23fdaa`. Whether the compound command finished is unknown.
- **Checkpoint (finding 3, VERIFIED).** The checkpoint lists the item as
  `not completed: command item-started-exec-… ordinal 134 (start recorded, no
  completion recorded before this checkpoint)`, followed by `last safe
  boundary: lease.renewal_due at sequence 147`. Its `next_action` asks the
  next session to re-verify from the checkpoint.
- **Finding 1 not exercised.** At the end of the 150 s observation, and again
  after the audit boot: 0 `cobbler_wakeups` rows, 0 `wakeup` Oban jobs, 0
  `wakeup-decision:%` admission events. Also no continuation dispatch (the
  goal still has 1 run). Nothing is duplicated, and nothing was there to
  duplicate.
- **Session status (finding 2 diagnostics).** `session_at_end: {"session":
  "none"}`, read 150 s after the terminal. The terminal is Codex's own
  `interrupted` result, not a simulated completion. `session_status/1` probes
  only `CodexAppServer` sessions; a Claude session would read `none` too
  (REPO-INSPECTION).
- **Timers.** No timer or staleness stopped the run on its own: the lease
  deadline acted only when an event arrived (inline evaluation on ingest).
  But what it then did, interrupting at a START without a recorded
  completion, is what the locked rule "Leases renew only at safe harness
  boundaries" forbids. This was observed, not inferred.

## 6. Replay and restart (audit phase, VERIFIED)

The replay used the identical `run.handoff` request (same `command_id`
`live-handoff-<sender>`) against the settled transfer:

| | before | after | delta |
|---|---|---|---|
| handoff Oban jobs (all states) | 1 | 1 | **0** |
| runs in the handoff goal | 2 | 2 | 0 |
| `handoff.created` in the goal | — | 1 | — |

The driver records these counts but does not compare them; the comparison
above is explicit. Result: `{"status": "resolved", "handoff_id": <original
receiver>, "job?": false}`. After the audit boot the DB still holds exactly 1
handoff job (`completed`, attempt 1, no errors). **Finding 4's settled-replay
case is VERIFIED live.** The late-delivery and crash-window sub-cases were
not exercised.

Invariants over 4 runs and 6 node boots, all `true`:
`at_most_one_starting_per_run`, `at_most_one_terminal_per_run`,
`every_stop_has_checkpoint_before_it` (3 completed, 1 interrupted, 1
checkpoint each), `one_dispatch_row_per_started_run`. Final Oban state:
dispatch 2 `completed` + 2 `cancelled` (the two `effect_deferred /
run_state_advanced` rows), handoff 1 `completed`, wakeup none.

## 7. Findings

1. **NEW: a lease-deadline stop interrupted a Codex turn at a command START
   with no completion recorded, and the decline sequence never ran** (§5).
   This is a defect on the lease safety path at `1566acd`. **Not fixed**: it
   is outside this brief's evidence-only scope. Its consequences, all
   observed: an in-flight write was possibly cut; no `lease.expired`,
   suspend or recheck wake; the lease row stays `active`; and the manual-scope
   wake path (finding 1) is unreachable in this shape. Next step, not taken:
   retain raw app-server frames for a deadline stop, or lock
   `request_safe_stop` against an interleaved non-command `item/completed`.
2. **Finding 1** (manual-scope recheck): still **LIVE-UNVERIFIED**; no wake
   arose.
3. **Finding 2**: the declined-run case did not arise. Session diagnostics
   were recorded for the interrupted run. It stays open for the declined case.
4. **Finding 3**: unfinished-item naming VERIFIED live (Codex). The
   provider-side race itself was not observed in this shape.
5. **Finding 4**: settled replay VERIFIED live (0 new jobs).
6. **Finding 6**: per-phase code identity VERIFIED live (6 of 6).
7. Carried, not re-examined: run rows are not projected after start (the
   summary shows `run_row_status: requested` on completed runs).

## 8. Source checkout (VERIFIED)

A read-only snapshot (`GIT_OPTIONAL_LOCKS=0`, `git diff HEAD` against a
private index copy, the index never written) was taken before `setup` and
after `audit`, and the two are identical: HEAD `1566acd`, porcelain
`?? .github/hooks/ ?? .pi/`, index SHA-256 `f7cfaa54…` with its mtime
unchanged, `git diff HEAD` SHA-256 of the empty string, 4 stashes. After the
sequence, no `beam.smp`, `codex app-server --stdio` or `claude --print`
process from this sequence was left running.

## 9. Gate

Measured on the committed evidence tree; the exact command, counts, exit
status and SHA are in the PR description. This file does not restate them, so
that no figure here predates the commit it describes.

## 10. Acceptance 8 (unchanged, not re-run)

The comparison was not repeated. `final-acceptance.md` §4 and §8.3 stand:

- the pre-registered cycle's projection arm **failed** (the receiver adopted
  the sender session's stop limit);
- after the post-hoc label fix, projection passed 2 of 2 but showed **no
  consistent advantage** over `worktree_only`;
- the milestone fixture's **scripted quota refusal was never reproduced**.

The receiver in §4 is the product's own arm on a fresh sender. It is N=1 and
has no same-cycle comparison arm, so it is not evidence for or against
Acceptance 8. An independent Claude review concluded that "measured, no
advantage shown" meets the existing contract. Promoting it is the human
reviewer's call.

## 11. Fixtures

In `fixtures/live-final/` (covered by `live_evidence_redaction_test.exs`'s
existing `live-final/*` glob), produced by `tools/live_eval/export_evidence.py`
and `export_summary.py` from the read-only DB, in one label order so both use
the same mapping (16 synthetic UUIDs, 18 synthetic prefixed ids):

- `closeout-summary.json`: the 6 phase records;
- `normalized-closeout-codex-turn1.md` (369 events), `-codex-turn2.md`
  (344), `-claude-receiver.md` (50), `-codex-lease-stop.md` (140).

The synthetic series restarts per export, so `…002` etc. here are not the
same runs as in `final-acceptance-summary.json`. Beyond the test, scans for
host paths, login name, state-dir name, credential shapes, reasoning keys,
non-synthetic UUIDs and prefixed ids, and the random secret all came back
clean. They ran over the raw bytes, the reassembled delta stream (escaped and
unescaped) and the newline-joined text.
