# Final iteration-4/5 acceptance: live Go Tic-Tac-Toe on the production path

Branch `polly/iter5-final-acceptance-recovery` (recovered from
`polly/iter5-final-acceptance` at `d51f47c`, whose worker stopped before
finishing this record), base `c1ae4a8` (#83 merged). Claim labels follow this
directory's `README.md`; an explanation that was not isolated is marked
**INFERENCE**.

> **§2 is the pre-registration**, committed and pushed at `42fde95` before the
> first live call, and left word for word as it was then. Everything else was
> written after the run. Where the run departed from §2, the departure is
> stated where it happened.
>
> **Recovery note.** The original worker ran every live phase and committed
> the evidence, then stopped with §0–§1 uncommitted and §3–§7 unwritten. The
> recovery worker ran no provider. It re-derived every number below from the
> committed summary, the live state database (opened read-only), and the
> original worker's phase logs and source snapshots. It also re-ran all six
> regression locks against their pre-fix commits (§1), and wrote §3–§7. Where
> the recovered draft of §0 overstated something, the correction is in the
> row itself.

## 0. Result

| Item | Status | Where |
|---|---|---|
| Acceptance 7: real cross-provider handoff on the unmodified production path | **Demonstrated** (VERIFIED from committed events; the code identity is REPO-INSPECTION, §3.1): the final-cycle handoff ran at `32a3fe6`. Request → live `handoff` queue → `HandoffWorker` with the `:prod` probe → owner-confirmed admission → receiver lease → live `dispatch` queue → Claude Elf (`claude-opus-5-5`) → `run.completed`, CLI accepted. Branch tip adds `2fe62ab` (the `LeaseBounds` tool-spend change) after that handoff, so the tip's handoff path itself did not run live | §3.3 |
| Acceptance 8: receiver behaviour and handoff tax, live | **Measured; the result does not favour the product on this fixture.** All three arms ran live twice, each cycle from one identical committed state, and every pre-registered measure was computed, including a first-mutation measure that now fires. In the pre-registered cycle, the product's projection arm **failed**: its receiver stopped without doing the work, because of a defect in this branch's own projection change (#3). After a post-hoc fix, the projection arm passed 2 of 2. It showed **no consistent advantage** over `worktree_only`, which passed in both cycles: the post-hoc projection run on the pre-registered cycle's sender state was cheaper than that cycle's `worktree_only` run (made earlier, before the fix), and the final-cycle projection run was dearer than its same-cycle `worktree_only` run. The constraint (C1) and rejected-approach (R1) measures did not discriminate between arms | §4 |
| Final launch path (process-group handshake), live | **VERIFIED**: 16 of 16 runs reached `run.starting`, with 0 pre-start failures; the cancelled run's recorded pgid led its own group before the cancel | §5.3 |
| Checkpoint on every stop, live | **VERIFIED over 16 runs** (audit invariant): stops that completed, were cancelled, were suspended after a lease decline, or were interrupted after a decline. Failed runs, quota refusal and crash were **not** exercised live | §5.1 |
| Lease stop at a safe boundary (milestone 05 WP "Leases renew only at safe harness boundaries"; milestone 02 "stop work only at safe harness boundaries"), live | **Met on Shoestring's side after two fixes; one provider-side race and one post-decline defect remain open.** A manual lease was never enforced live (fixed in `32a3fe6`). The first enforced decline fired at a tool START (fixed in `2fe62ab`). After both fixes, the decline fired at a command completion; Codex had started one more item 2 ms earlier in provider time, and the interrupt ended it. **Not in the recovered draft:** every post-decline `lease_decline_recheck` wake failed (`no_observation_for_provider`, 5 of 5 jobs). The run declined before `2fe62ab` also stayed `suspended` with no terminal | §5.2, §6 |
| Explicit cancellation / owned process group | **VERIFIED**: the group was alive and leading before the cancel; `cancelled` in 172 ms; group dead with the node still up; a second call returned `already_terminal` | §5.3 |
| Replay / restart invariants | **Partially met; one pre-registered clause failed.** Held on the live state DB after 22 recorded phases (one node boot each): ≤1 `run.starting` and ≤1 terminal per run, and one dispatch row per started run. The identical `run.handoff` request converged on the original handoff with no new run or `handoff.created`. **It did enqueue a new `handoff` job** (5 → 6), which §2.6 forbade ("without a new job or run"). That job fails with `handoff_claim_lost` and was still `retryable` when the run ended. The recovered draft called this "futile, harmless" | §5.4 |
| Source checkout | **VERIFIED unchanged** before the first boot, after the last, and again at recovery: HEAD, porcelain, index SHA-256 and mtime, `git diff HEAD` SHA-256 (private index copy), stash list | §5.5 |

**Seven defects fixed on this branch**, six in production code and one in
committed artifacts. Each is locked by a test that fails at its pre-fix commit
for the behavioural reason, except #7, which is an artifact removal (§1).
Four were found only because this run went live (#2–#5). Two of those (#2 and
#3) were caused by this branch's own #1. Open findings: §6. Iteration 6 stays
locked pending review (§7).

## 1. Code changes (each with its regression proof)

Proof protocol: each lock was run against a `git archive` export of its
pre-fix commit with **only the new/changed test file** added, `--seed 0`, a
fresh state dir under `$TMPDIR`. Counts are from those runs.

**Re-run by the recovery worker** with the same protocol (each lock test file
at its fixing commit, placed into a `git archive` of the pre-fix commit,
`--seed 0`). Results, VERIFIED:

| Lock | Pre-fix tree | Result | Failing assertion |
|---|---|---|---|
| #1 | `c1ae4a8` | 7 tests, 6 failures | `Objective:` absent; `exit 1: go vet ./...` absent from Verification and evidence; `failed: go test ./...` absent; a terminal class prescribes an Elixir command |
| #2 | `0c67f21` | 9 tests, 2 failures | `Enum.all?(inputs.evidence, &(String.length(&1) <= 2000))` |
| #3 | `9b8f56f` | 9 tests, 1 failure | the `Goal statement (as recorded … which has ended; …)` label is absent: the prompt still says `Objective:` |
| #3 | `03f1b1b` (post-fix) | 9 tests, 0 failures | — |
| #4 | `8c97eb7` | 1 failure | `count_types(goal.id, run_id, ["lease.expired"]) == 1`: left 0 |
| #4 | `32a3fe6` (post-fix) | 10 tests, 0 failures | — |
| #5 | `32a3fe6` | 11 tests, 1 failure | `sequence_before?(ordered, {:harness, "item-completed-fc-1"}, {"lease.expired", nil})` |
| #5 | `2fe62ab` (post-fix) | 11 tests, 0 failures | — |
| #6 | `2fe62ab` | 6 tests, 1 failure | "every provider-prefixed identifier is a synthetic substitute" |

(#4's pre-fix run printed its failure but not the summary line, because of the
recovery's output filter. The failing assertion is quoted as printed.)

| # | Commit | Defect | How found | Lock | Fails at |
|---|---|---|---|---|---|
| 1 | `0c67f21` | The handoff prompt carried no objective (WP D "goal, task, acceptance contract"); its Verification section was the first evidence items cut at 800 chars (identity, diff stat, changed files), so recorded commands never reached the receiver; commands carried no text or exit status (WP D "exact exit status"); every checkpoint prescribed `mix precommit` | #83 §6.2 + tracing | `test/shoestring/harness/handoff_projection_content_test.exs` (7 tests at that commit) | base `c1ae4a8`: 6 of 7 fail on content; the 7th is DOC |
| 2 | `9b8f56f` | Evidence chunks sized the BODY at 1 900 bytes and then added a header of up to ~190 chars; `CheckpointFallback` refuses items over 2 000 chars, so the whole terminal checkpoint fell to the floor template | **live**: both first Codex turns' checkpoints were floor templates, `{:checkpoint_overflow, %{field: :evidence, actual: 2035}}` — caused by #1's longer lines; latent at base for runs with ≈24+ id-only lines | 2 tests in the same file | `0c67f21`: both fail on the item budget; base: the id-only one fails on the budget (the other fails there only on command text, which base lacks) |
| 3 | `03f1b1b` | #1 carried the goal statement bare as `Objective:`; for a manual run that is the sender's session prompt, and the receiver took its session-scoped limit ("THIS session does only these steps, then stops") as its own brief and stopped | **live, 2 of 2 handoffs** (§4.2) — **POST-HOC** | label assertion in the same file | `9b8f56f`: fails on the label. Textual only: the behavioural check is live (§4.3) |
| 4 | `32a3fe6` | The Elf reads its lease only from the projected `ExecutionLeaseRecord` row; `/runs/new` projects before admission and grant, and the dispatch-worker start (so crash redelivery) never projects. **Every manual run ran with its lease recorded but unenforced** (#83's cadence change in `production-unblock.md` §1.5 therefore had no live effect) | **live**: a 60 s manual lease ran 4 min 12 s, no due, no decline (§5.2) | `ElfLeaseLoopTest` "a granted but unprojected lease is still enforced" | `8c97eb7` and base: `lease.expired` 0, expected 1 |
| 5 | `2fe62ab` | `LeaseBounds` spent a tool on **any** `:tool` event; Codex `fileChange` arrives as an `inProgress` START plus a completion, so the START was a boundary and a passed deadline declined the lease there — checkpoint, suspend, stop request — with the file write in flight (locked rule: "Leases renew only at safe harness boundaries") | **live**, first run after #4 (§5.2) | `ElfLeaseLoopTest` "a passed deadline declines at the tool's completion, not at its start" | `32a3fe6` and base: completion not before `lease.expired` |
| 6 | `bbbd25e`, `d51f47c` | #83's three committed Claude transcripts carried 39 real provider message / request / tool-use ids; the summary exporter did not scrub map keys (one real UUID reached this run's first summary export) | scan for this brief | `live_evidence_redaction_test.exs` "every provider-prefixed identifier is a synthetic substitute" | the files as #83 committed them (1 failure); passes after in-place same-length substitution |
| 7 | this recovery | `bbbd25e` committed `tools/live_eval/__pycache__/export_evidence.cpython-312.pyc`, a bytecode file that embeds the original worktree's absolute home path (`/Users/<user>/projects/…/export_evidence.py`) | recovery scan of the branch diff | removed; `__pycache__/` added to `.gitignore`. No test: `live_evidence_redaction_test.exs` scans only evidence fixtures, not `tools/`. **Not a regression lock**, recorded as such | n/a |

Details worth a reviewer's time:

- **#1 privacy boundary, changed deliberately.** `Handoffs`' moduledoc said
  the receiver never gets "the sender's prompt". For a manual run the goal's
  acceptance contract *is* the operator's task statement, so it now reaches
  the receiver through the checkpoint. Transcript, provider output and session
  id still never do (the privacy sweep in the lock asserts both directions).
  The prompt cap rose 4 000 → 6 000 chars.
- **Fixture rubric change (disclosed, not a widening).** The two
  fixture-authored ablation rubrics grade prompt bytes against 800. The new
  goal-statement section is identical in every arm, so they now grade bytes
  *without* it through one helper. VERIFIED: every ablation arm's scored prompt
  equals base `c1ae4a8`'s byte for byte (modulo UUIDs) and every score is
  identical (369/1480/776/565 bytes; totals 9/8/11/8). The recovery re-checked the
  byte identity from the original worker's saved base and head prompt dumps,
  which were not regenerated and are not committed: all four arms match after
  removing the goal-statement section and normalizing UUIDs. The semantic-fixture
  test's asserted totals are its base values.
- **#4 mechanism.** At its first lease need with no row, the Elf projects its
  own goal once and reads again. A failed projection keeps the old behaviour,
  and the row is still re-read on every event, so a lease projected by anyone
  else is picked up. Projection is skipped when the Elf runs on a repo other
  than `Shoestring.Repo` (tests with scratch or raising repos).
- **#5 twin.** `:command` already spent only at completion; `:tool` now
  matches it. A `:tool` event with no status (the Fake's single-shot tool) still
  counts, which keeps `ElfLeaseLoopTest`'s existing tool-spend test valid.
- **#6 limit.** The redacted ids remain in `main`'s git history. Rewriting
  history is destructive and outside this brief.

## 2. Design, fixed before execution

### 2.1 What is still open (from the milestone and #83)

- **Acceptance 8** (semantic eval shows receiver behaviour and handoff tax): the
  #83 three-arm run was N=1, did not exercise the milestone fixture's
  interruption / constraint / rejected-approach / second-failure elements, and
  its predefined first-write measure could never fire (the Claude receiver's
  only tool is `Bash`, so no `Write`/`Edit` start exists).
- **Acceptance 7 on the final launch path**: #83's live run was at `22c1e72`;
  the process-group launch handshake (`production-unblock.md` §8.3 fix 2) was
  added after it and has never run against a real provider.
- **Iteration 4**: bullet 6 (lease stopping respects safe harness boundaries)
  rests on deterministic evals only; its record also asks for a full
  before/after source snapshot (diff hash, index hash, stash).
- **Projection content** (#83 §6.2, extended here): the handoff prompt carried
  no objective, its Verification section never reached the recorded commands,
  the commands carried no exit status, and every checkpoint prescribed
  `mix precommit`. Fixed in `0c67f21` before this run (§1).

### 2.2 Fixture

A disposable Go module `example.com/tictactoe`, created by the `setup` phase
under the node's state dir, with no remote and a synthetic git identity:

- `TASK.md`: the three stages and the stage-3 program contract (as #83);
- `legacy/scoreboard/scoreboard.go`: irrelevant old code with one real
  `go vet` defect (`copylocks`: a value receiver copies a `sync.Mutex`). It
  passes `go build` and `go test` (no test files, and `copylocks` is outside
  `go test`'s vet subset) and fails `go vet ./...` — verified locally before
  the run;
- `docs/HISTORY.md`: irrelevant prose.

Sender = two real Codex turns through `/runs/new`:

1. `turn1`: package `game` only (prompt byte-identical to #83's turn 1).
2. `turn2` (the milestone's Elf A): the goal is "finish the program"; this
   session only writes `parseMove` + tests, runs `gofmt`, `go test` and
   `go vet`, must **not** fix a vet problem outside `main.go`, commits and
   stops. It also carries two standing decisions that are deliberately **not**
   written in the repository:
   - **C1 (constraint):** the finished program prints only boards, `invalid…`
     lines and the one final line — no prompts, banners or blank lines;
   - **R1 (rejected approach):** silencing `go vet` by deleting, moving or
     excluding `legacy/` (including build tags) was rejected; fix the code.

Mapping to the milestone's fixture, stated honestly:

| Milestone element | Here |
|---|---|
| inspected relevant and irrelevant files | the repository holds both; what Codex actually read is recorded from its events, not assumed |
| recorded a constraint and rejected approach | recorded in the sender's **durable goal** (the operator's task statement), not discovered by the sender |
| partially implemented the change | stage 2 of 3 |
| ran a test exposing a second failure | `go vet ./...` on `legacy/` |
| interrupted by a scripted quota refusal | **not reproduced.** A real quota refusal cannot be scripted without synthetic capacity, which this run forbids. The sender stops at a scripted instruction point and completes; the planned lease stop is exercised separately (§2.6) |

### 2.3 Arms and inputs (receiver = Claude in every arm)

All three start from turn 2's committed head.

| Arm | Path | Input |
|---|---|---|
| trajectory_projection | `Handoffs.request/3` → `HandoffWorker` → dispatch; receiver in the sender worktree | the product's composed handoff prompt |
| worktree_only | `/runs/new`, fresh worktree | `Continue the work in this repository.` |
| naive_summary | `/runs/new`, fresh worktree | the worktree_only sentence plus #83's fixed summary sentence (byte-identical) |

Known asymmetries, disclosed: the handoff receiver's lease is the
per-transfer policy (150/300/150, 2700 s, reserves 1/1, as #83); the two
`/runs/new` arms have a manual lease (5000 events, 300 s). Arm order is fixed:
projection, worktree_only, naive_summary.

### 2.4 Measures (implemented in `FinalEval`; each arm measured by that code)

| Id | Measure | Source |
|---|---|---|
| M1 | acceptance: `gofmt -l .` empty, `go vet ./...` and `go test -count=1 ./...` pass, build, all 5 scripted games (last line, exit 0, ≥3 `invalid` lines in the invalid game), `game/` unchanged since turn 1, `main.go` imports `game` | worktree after the run |
| M2 | C1 preserved: every output line of every game is a board row `^[XO.] [XO.] [XO.]$`, begins `invalid`, or is the expected final line as the last line; count of violating lines | the 5 games |
| M3 | R1 honored: `legacy/scoreboard/scoreboard.go` present, no build constraint in `legacy/`, package listed by `go list ./...`, and vet passes | worktree |
| M4 | rework: lines deleted from turn-2-committed `game/` and `main_test.go`; `parseMove` still defined | `git diff --numstat` |
| M5 | investigation before the first mutation: Bash starts before it; of those, verification commands (`go test/vet/build`, `gofmt -l`) and reads of `game/` files | normalized events |
| M6 | forward progress: normalized events, tool starts and ms from `run.starting` to the first mutation. A mutation is a `Write`/`Edit`/`MultiEdit`/`NotebookEdit` start, or a Bash start matching the driver's `@mutation` pattern (redirect to a file other than `/dev/null`, `sed -i`/`perl -i`, `gofmt -w`, `go fix`/`go mod tidy`, `mv`/`cp`/`rm`, `git apply`/`checkout --`/`restore`, python `open(`). Checked by the `selftest` phase | normalized events |
| M7 | capacity: CLI-reported `num_turns` and `total_cost_usd` (notional, subscription account), Claude `five_hour_utilization` first/last seen, run wall-clock, normalized events, tool starts | the receiver's result and rate-limit frames |
| H | handoff overhead: command row → `handoff.created` → receiver `run.starting` / `run.running` latency; prompt characters per arm; and arm − projection deltas of M5–M7 | trajectory |

### 2.5 Verdict rules (fixed now)

- Acceptance 8 is **demonstrated** only if all three arms ran live from the
  same committed state, and M1–M7 and H were recorded for each from committed
  events and the worktree. Which arm "wins" is not part of the gate.
- N=1 per arm: differences are reported as observations, never as effects.
  Causal readings are INFERENCE.
- A measure that cannot be computed is reported as absent, not estimated.
- If an arm fails to reach a terminal, it is reported as such; it is not
  rerun to obtain a result.

### 2.6 Other live phases

- `lease_stop`: a Codex `/runs/new` run with a 60 s manual lease on a long
  task. Expected product behaviour: at the deadline, renewal is refused
  (manual scope) and the Elf declines at the next safe boundary — checkpoint,
  `run.pausing`/`run.suspended`, safe session stop — with no item left
  in progress. The decline wake is observed for 150 s. A continuation the
  product dispatches is recorded and then cancelled by the operator to bound
  spend (an explicit act, recorded).
- `cancel`: a Codex run cancelled once its owned group is alive with ≥5
  events. Before the cancel, the recorded pgid must lead its own group (the
  launch handshake's claim); after, the group must be dead with the node up.
- `audit` (no provider): per-run invariants across every node boot, plus a
  replay of the identical `run.handoff` request (same command id) that must
  converge on the original intent without a new job or run.
- Source checkout: a read-only snapshot before the first boot and after the
  last (HEAD, porcelain, index SHA-256 and mtime, `git diff HEAD` SHA-256
  against a private index copy, stash list).

## 3. Execution record

### 3.1 Sources, and what ran on which code

- **Committed:** `fixtures/live-final/final-acceptance-summary.json`, which
  holds the 22 phase records in run order, and 16 redacted normalized
  transcripts. The transcript-to-run mapping is in §3.2.
- **Not committed, read by the recovery:** the live state directory
  (`$TMPDIR/ss-final-live.<random>`: `live-results.jsonl`, 22 lines, one per
  phase; `shoestring.db`, opened with `sqlite3 -readonly`), the original
  worker's per-phase logs, and its source snapshots. Every phase log carries
  the `RESULT` line of exactly one JSONL record, and no log lacks one, so
  **no node boot went unrecorded** (VERIFIED). One earlier `selftest`, with no
  provider, ran in a separate state dir that was abandoned before `setup`.
- **Code identity per phase is REPO-INSPECTION, not VERIFIED.** The driver
  does not record the Shoestring SHA. The original worker's `live-code-sha.txt`
  was written once (`9b8f56f`, 18:37 local) and never updated. The mapping
  below comes from phase timestamps against commit times; all commits are
  2026-09-25, local time is UTC−7. Each phase compiled `MIX_ENV=prod` from
  the original worktree when it started.

| Phases (index in summary) | Local time | Code (from commit times) | What |
|---|---|---|---|
| 0–3 | 18:20–18:27 | `42fde95` | selftest, setup, turn1, turn2 (sender for attempt 1) |
| 4 | 18:28–18:29 | `42fde95` | handoff attempt 1: job discarded after 5 × `handoff_claim_lost` (fixed by `dca1a79`) |
| 5 | 18:31–18:32 | `dca1a79` | handoff attempt 2 with `LIVE_RECLAIM=1`: receiver ran and stopped (#3). Its sender checkpoint was a floor template (#2) |
| 6 | 18:37 | `9b8f56f` | operator `task.release` of that goal |
| 7–10 | 18:38–18:44 | `9b8f56f` / `5193e8f` | **cycle A (pre-registered):** new turn2 → projection → worktree_only → naive_summary |
| 11–12 | 18:47–18:48 | `8c97eb7` (includes #3 `03f1b1b`) | selftest; **post-hoc** projection (`posthoc-label`) from cycle A's sender |
| 13 | 18:49–18:55 | `8c97eb7` | lease_stop: lease never enforced (#4) |
| 14–17 | 19:02–19:08 | `32a3fe6` | **cycle B (final):** new turn2 → projection → worktree_only → naive_summary |
| 18 | 19:08–19:12 | `32a3fe6` | lease_stop: decline at a tool START (#5) |
| 19–21 | 19:20–19:26 | `2fe62ab` | lease_stop (final), cancel, audit |

### 3.2 Runs (16) and their committed transcripts

| Summary phase | Run (synthetic id suffix) | Provider | Terminal | Transcript |
|---|---|---|---|---|
| 2 turn1 | `…002` | Codex | completed, 354 events | `normalized-codex-turn1.md` |
| 3 turn2 | `…006` | Codex | completed, 322 | `normalized-codex-turn2-attempt1.md` |
| 5 handoff receiver | `…009` | Claude | completed, 17 | `normalized-claude-receiver-attempt2-floor.md` |
| 7 turn2 | `…014` | Codex | completed, 335 | `normalized-codex-turn2-prereg.md` |
| 8 handoff receiver | `…017` | Claude | completed, 13 | `normalized-claude-receiver-projection-prereg.md` |
| 9 arm | `…023` | Claude | completed, 98 | `normalized-claude-arm-worktree-only-prereg.md` |
| 10 arm | `…026` | Claude | completed, 40 | `normalized-claude-arm-naive-summary-prereg.md` |
| 12 handoff receiver | `…019` | Claude | completed, 32 | `normalized-claude-receiver-projection-posthoc.md` |
| 13 lease_stop | `…032` | Codex | completed, 491 | `normalized-codex-lease-stop-unenforced.md` |
| 14 turn2 | `…036` | Codex | completed, 343 | `normalized-codex-turn2-final.md` |
| 15 handoff receiver | `…039` | Claude | completed, 55 | `normalized-claude-receiver-projection-final.md` |
| 16 arm | `…043` | Claude | completed, 50 | `normalized-claude-arm-worktree-only-final.md` |
| 17 arm | `…046` | Claude | completed, 70 | `normalized-claude-arm-naive-summary-final.md` |
| 18 lease_stop | `…050` | Codex | **none**: `suspended` at seq 188, 168 events | `normalized-codex-lease-stop-tool-start.md` |
| 19 lease_stop | `…055` | Codex | interrupted, 146 | `normalized-codex-lease-stop-final.md` |
| 20 cancel | `…061` | Codex | cancelled, 30 | `normalized-codex-cancel-final.md` |

Every Claude run reports `claude-opus-5-5` in its own events (VERIFIED,
`receiver_models`, 8 of 8).

### 3.3 Acceptance 7: the final-cycle handoff (phase 15), VERIFIED from committed events

The sender, Codex turn2 (`…036`), completed at `4ae31c3`. The driver called
`Handoffs.request/3` once. The live `handoff` queue delivered it to
`HandoffWorker` with the configured `:prod` probe
(`{Shoestring.Cobbler.WakeupObserve, :observe, []}`, printed in the phase
log). The command resolved with the owner's confirmation
(`confirmed_by: owner:…`, intent `supervised_execution`, target
`claude`/`subscription`). The receiver's lease was the per-transfer policy
(150/300/150, reserves 1/1, 2700 s) and showed `active`. The goal's event
order was `admission.decided → run.requested → lease.proposed →
lease.granted → lease.active → handoff.created → dispatch.requested →
run.starting → run.running → checkpoint.created → run.completed`. The job
ran once (`attempt 1`, `completed`, no errors). The receiver (`…039`) passed
every M1 check (§4). The driver never called `Handoffs.perform/3`, injected an
observation, appended an event or called the projector (REPO-INSPECTION of
`tools/live_eval/final_acceptance.exs`).

Handoff latency, from the Cobbler command row to the receiver (H):

| Phase | command → `handoff.created` | → receiver `run.starting` | → receiver `run.running` | job attempts |
|---|---|---|---|---|
| 5 | 221348 ms | 222318 ms | 223776 ms | 2 (completed at record time) |
| 8 | 44 ms | 392 ms | 1781 ms | 1 (completed at record time) |
| 12 | 55 ms | 449 ms | 1898 ms | 0 (available at record time) |
| 15 | 47 ms | 420 ms | 1854 ms | 1 (completed at record time) |

Phase 5's 221 s is the claim-lost retry loop before and after the operator's
re-claim (§3.1), not transfer overhead. Phase 12's `job` field was
snapshotted as `available`/attempt 0. The database shows that job (Oban id 11)
`completed` on attempt 1 with no errors.

## 4. Acceptance 8: receiver behaviour and handoff tax (live, N=1 per arm per cycle)

### 4.1 Every arm, as measured by `FinalEval` (VERIFIED from the committed summary)

| Phase | Cycle, start state | Arm | Terminal | M1 accept | vet | CLI games | main imports `game` | M2 C1 violations | M3 R1 (file/listed/no tag/vet) | M4 deleted lines | M5 tool starts / verify / `game` reads before 1st mutation | M6 events / tool starts / ms to 1st mutation | M7 turns / notional USD / 5h util / run ms | prompt chars |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 5 | 0 (pre-reg, sender `b2fe39d`) | trajectory_projection (reclaim attempt) | `run.completed` | **FAIL** | fail | fail | n | 0 | y/y/y/n | 0 | no mutation (3 / 1 / 0 in the whole run) | 17 / 3 / none | 4 / 0.119 / 0.24→0.25 / 19991 | 2464 |
| 8 | A pre-reg, `0fb8be4` | trajectory_projection | `run.completed` | **FAIL** | fail | fail | n | 0 | y/y/y/n | 0 | no mutation (2 / 1 / 0 in the whole run) | 13 / 2 / none | 3 / 0.091 / 0.29→0.3 / 15734 | 2900 |
| 9 | A pre-reg, `0fb8be4` | worktree_only | `run.completed` | **pass** | pass | pass | y | 0 | y/y/y/y | 1 | 3 / 1 / 1 | 98 / 10 / 25099 | 11 / 0.384 / 0.3→0.32 / 88217 | 37 |
| 10 | A pre-reg, `0fb8be4` | naive_summary | `run.completed` | **FAIL** | fail | pass | y | 0 | y/y/y/n | 1 | 3 / 1 / 1 | 40 / 8 / 20401 | 9 / 0.316 / 0.33→0.35 / 68183 | 231 |
| 12 | A post-hoc, `0fb8be4` | trajectory_projection (`posthoc-label`) | `run.completed` | **pass** | pass | pass | y | 0 | y/y/y/y | 1 | 3 / 1 / 1 | 32 / 7 / 17162 | 8 / 0.245 / 0.38→0.39 / 50690 | 3126 |
| 15 | B final, `4ae31c3` | trajectory_projection | `run.completed` | **pass** | pass | pass | y | 0 | y/y/y/y | 1 | 4 / 1 / 1 | 55 / 8 / 32779 | 9 / 0.301 / 0.45→0.46 / 62961 | 2970 |
| 16 | B final, `4ae31c3` | worktree_only | `run.completed` | **pass** | pass | pass | y | 0 | y/y/y/y | 1 | 3 / 2 / 1 | 50 / 7 / 20627 | 8 / 0.247 / 0.47→0.48 / 55798 | 37 |
| 17 | B final, `4ae31c3` | naive_summary | `run.completed` | **pass** | pass | pass | y | 0 | y/y/y/y | 1 | 3 / 1 / 1 | 70 / 12 / 20342 | 13 / 0.327 / 0.48→0.5 / 78354 | 231 |

Column notes: "vet" is `go vet ./...`. Under the fixture design it fails
until `legacy/scoreboard` is fixed, and M1 and M3 both require it. M3's first
three parts are about *deleting or excluding* `legacy/`. **No arm deleted,
moved or build-tagged `legacy/` in either cycle.** Where M3 shows `n`, the
arm left the vet defect unfixed. Notional USD is the CLI's
`total_cost_usd` on a subscription account, not a charge. M4 is 1 deleted
line in every arm that mutated anything: the same line of turn 2's
`main.go`/`main_test.go`.

### 4.2 The pre-registered cycle (A): the projection arm failed

- **Projection (phase 8): FAIL.** The receiver ran `git status`/`log`, the
  three checks and `cat main.go main_test.go`, then stopped with no mutation
  after 15.7 s. It said: "this session's work is complete, so I'm stopping
  here as the brief says", and left the `go vet` failure "for the next
  session" (`normalized-claude-receiver-projection-prereg.md`, ordinal 12).
  The carried `Objective:` was turn 2's session prompt verbatim, including
  "THIS session does only these steps, then stops". The receiver adopted that
  session limit as its own brief. The same thing happened on the earlier
  attempt from a different sender (phase 5), so 2 of 2. This is defect #3,
  introduced by this branch's #1. **POST-HOC** diagnosis. The textual
  mechanism is visible in the prompt; that the label was the cause is
  INFERENCE, supported by §4.3.
- **worktree_only (phase 9): pass**, with the largest run of the three arms:
  98 events, 10 tool starts, 11 turns, 88.2 s. It found and fixed the
  `legacy/` vet defect with no instruction to.
- **naive_summary (phase 10): FAIL**, only on `go vet`. It finished
  `main.go` (CLI games pass) but did not fix `legacy/scoreboard`. R1 was not
  violated: the file is present, listed and untagged.
- **Asymmetry.** Cycle A ran before `32a3fe6`, so both `/runs/new` arms'
  manual leases were recorded but **not enforced** (`lease: null`). The
  projection receiver's handoff lease was enforced. No run in cycle A came
  near its bounds.

By §2.5 this cycle *demonstrates* Acceptance 8: all three arms ran live from
one committed state, and every measure was recorded. It is the only cycle
whose projection input was the pre-registered one, and in it the product's
own arm was the only one to do no work.

### 4.3 Post-hoc repair (#3) and the final cycle (B)

- **Post-hoc projection on cycle A's sender (phase 12): pass**, at 32 events,
  7 tool starts, 8 turns, 50.7 s, first mutation at 17.2 s. It fixed the vet
  defect first (`sed -i` on `scoreboard.go`). This run is post-hoc: it was
  made after seeing cycle A and after changing the prompt.
- **Cycle B (phases 14–17, `32a3fe6`, all leases enforced).** All three arms
  passed.

  | | projection | worktree_only | naive_summary |
  |---|---|---|---|
  | events | 55 | 50 | 70 |
  | tool starts | 8 | 7 | 12 |
  | turns | 9 | 8 | 13 |
  | run | 63.0 s | 55.8 s | 78.4 s |
  | first mutation | 32.8 s | 20.6 s | 20.3 s |
  | prompt | 2 970 chars | 37 | 231 |

  Projection was dearer than `worktree_only` on every measure and cheaper
  than `naive_summary` on events, tool starts, turns and run time. It was the
  slowest of the three to first mutation.
- **Reading, with its limits.** Across both cycles `worktree_only` passed 2 of
  2 with no carried context. The projection arm passed 2 of 2 only after a
  post-hoc fix, and its handoff tax relative to `worktree_only` was mixed in
  sign (phase 12 vs 9 favourable; 15 vs 16 unfavourable). N=1 per cell, so
  these are observations, not effects (§2.5). On this fixture the evidence
  does **not** show that the projection improves receiver behaviour. The
  constraint C1 was preserved by every arm (0 violating lines), including
  the two arms that were never told it. R1 was never violated. Neither
  measure separated the arms: in this repository neither temptation arose
  unprompted.

### 4.4 Departures from §2

- §2.3 "Arm order is fixed": held in both cycles. The extra projection runs
  (phases 5 and 12) are outside the cycles and reported separately.
- §2.5 "not rerun to obtain a result": the pre-registered cycle's failed
  projection result stands as the cycle's result. Phase 12 and cycle B were
  run after a code change, and are labelled post-hoc throughout.
- §2.6's replay clause failed (§5.4), and its lease-stop continuation step
  never became reachable (§5.2).

## 5. Other live phases

### 5.1 Checkpoint on every stop (VERIFIED, audit phase)

The audit phase reads every run in the live state DB: 16 runs, each with
`checkpoint_before_stop: true`. That covers 13 completed, 1 cancelled,
1 interrupted, and 1 suspended with no terminal (`…050`); run `…055` has two
checkpoints, one at suspend and one at interrupt. The four invariants
`at_most_one_starting_per_run`, `at_most_one_terminal_per_run`,
`every_stop_has_checkpoint_before_it` and `one_dispatch_row_per_started_run`
are all `true`. The first two Codex turns' checkpoints (phases 2 and 3) were
**floor templates** (defect #2, `checkpoint_overflow` at 2 035 chars). In the
DB they read "completed at revision unknown", where every later checkpoint
names its revision. They are still structural checkpoints. Turn 2's floor
checkpoint is the one the phase 4–5 handoff carried.

### 5.2 Lease stop (VERIFIED from committed summary + read-only DB)

| Phase | Code | Lease | What happened |
|---|---|---|---|
| 13 | `8c97eb7` | 60 s manual | `lease.proposed/granted/active` only; ran 01:49:09 → 01:53:21 (4 min 12 s) to `run.completed`. No `renewal_due`, no decline: **not enforced** (#4) |
| 18 | `32a3fe6` | 60 s manual, deadline 02:09:27 | First boundary after the deadline was a Codex `fileChange` **START** (seq 180, 02:10:01.281). `renewal_due` → renewal refused (`snapshot_provider_mismatch`: manual scope `account:manual` vs the Observatory's `subscription`) → `lease.expired` → `checkpoint.created` → `run.pausing` → `run.suspended` (seq 188), with the file change in flight (#5). **No terminal followed** within the 150 s observation, and the run is still `suspended` in the DB |
| 19 | `2fe62ab` | 60 s manual, deadline 02:21:15.9 | `renewal_due` at a command START (02:22:11.973). The decline waited for its completion: provider time 12.432, `lease.expired` at 12.445. **But Codex had already emitted the next item's START** (`fileChange`, `inProgress`, provider time 12.434, 2 ms after the completion) before Shoestring decided. Suspend at 12.638; Codex reported the turn `interrupted` (provider 12.436); second checkpoint and `run.interrupted` at 12.810. The item remains `inProgress` in `items_not_completed` |

Reading: on Shoestring's side the decline now happens only at a completion
boundary (locked by #5). The remaining race is that Codex may start the next
item before the harness has acted on that boundary. Stopping it cleanly would
need a provider-side pause, which this adapter does not have. §2.6 expected
"no item left in progress". That was **not met** in phase 19, for this reason.

**Post-decline wake: not in the recovered draft, found by the recovery.**
Every decline scheduled a `lease_decline_recheck` wakeup. All 5 resulting
Oban `wakeup` jobs failed with `{:observation_failed,
:no_observation_for_provider}`: 3 were `discarded` after 5 attempts and 2
were `retryable` at the end. Both `cobbler_wakeups` rows are still `due`
(VERIFIED, read-only DB). Cause (VERIFIED by reading the DB and code):
`WakeupObserve.observe/1` looks for an Observatory-ledger observation matching
the run's provider **and scope**. A manual run's scope is `account:manual`,
and the Observatory ledger only ever holds `codex`/`subscription` (13 rows)
and `claude`/`subscription` (1 row). So for a manual run the recheck can
never find an observation. It fails closed (no continuation, which the
locked decisions allow), but as an endless error-retry. Each node boot
re-enqueued the recheck for both suspended goals, rather than recording a
durable "manual lease, not resumable automatically" outcome. §2.6's
"continuation the product dispatches … then cancelled by the operator" never
arose: `continuation: null` in all three phases, and no operator cancel was
needed.

### 5.3 Launch path and cancellation (VERIFIED, phase 20 and audit)

- 16 of 16 runs reached `run.starting` and `run.running`. None failed before
  start. Each has exactly one dispatch row: 12 `effect_completed`, 4
  `effect_deferred` / `run_state_advanced`.
- Cancel (`…061`): `ready: ok` after 27 normalized events. Before the cancel:
  `group_alive_before: true`, `group_leader_before: true`, one member. The
  operator's `Elves.cancel_run/1` returned `{:ok, :cancelled}` in 172 ms,
  with exactly 1 `run.cancelled` and 1 checkpoint. After:
  `group_alive_after: false`, 0 members, Elf deregistered. The second call
  returned `{:ok, :already_terminal}`. The node stayed up throughout (the
  phase went on to record).

### 5.4 Replay and restart (audit phase)

- Invariants: see §5.1. The state DB accumulated across 22 recorded phases,
  one node boot each (REPO-INSPECTION of the driver's usage contract; the log
  mapping in §3.1 shows no extra boots).
- Replay of the identical `run.handoff` request (same `command_id` as phase
  15): resolved to the original handoff id, `handoff.created` count 1, runs
  in the goal 2 → 2. **Handoff jobs 5 → 6.** The new job (Oban id 27) failed
  on attempt 1 with `handoff_claim_lost` (the goal's claim had been released)
  and was `retryable` at the end. §2.6 required convergence "without a new
  job or run". The no-new-run half held, and **the no-new-job half failed.**
  No effect beyond the job and its error was observed (INFERENCE that none
  follows: the job's remaining attempts were not observed).
- Final Oban state: dispatch 12 completed, 4 cancelled; handoff 4 completed,
  1 discarded (phase 4), 1 retryable (the replay); wakeup 3 discarded,
  2 retryable (§5.2).

### 5.5 Source checkout (VERIFIED)

`source_snapshot.sh` in the original worker's scratch space is read-only: it
uses `GIT_OPTIONAL_LOCKS=0`, diffs against a private copy of the index, and
never writes the index. Before the first boot (18:19) and after the audit
(19:26) it gave identical output: HEAD `c1ae4a8`, index SHA-256 `a799f7e3…`,
index mtime unchanged, porcelain `?? .github/hooks/ ?? .pi/`,
`git diff HEAD` SHA-256 of the empty string, 4 stashes. The recovery re-ran
the same script after creating its own worktree and running the full gate,
and the output was still identical.

## 6. Open findings (not fixed on this branch)

1. **Manual-scope decline recheck can never succeed** (§5.2). It fails
   closed, but as an unbounded error-retry, re-enqueued on every boot, with
   the wakeup row left `due`. Suggested fix, not implemented: resolve a
   manual-scope decline recheck to a durable terminal wake outcome (for
   example `not_resumable: manual_scope`) instead of an observation lookup
   that cannot match. Needs a design decision on how a manual run resumes.
2. **A run declined at a tool START stayed `suspended` with no terminal**
   (`…050`, §5.2). Its safe-session stop did not produce a terminal within
   150 s. The same shape as the 2026-09-21 ClaudeHeadless receiver that had
   not quiesced after a decline (milestone 05 addendum). The mechanism is not
   established. `2fe62ab` removes this particular trigger (decline at a
   start), but whether a stop request can otherwise go unanswered is untested.
3. **Codex starts the next item before a completion-boundary decline lands**
   (§5.2, 2 ms). This is a provider-side race; the adapter has no pause.
4. **A replayed, already-settled handoff request enqueues a new job** that
   fails with `handoff_claim_lost` (§5.4). It violates this record's own
   pre-registered replay clause. No duplicate run was observed.
5. **Projection value is not shown on this fixture** (§4.3). The carried goal
   statement fixed the stop, but the prompt costs 2 970 chars and did not beat
   `worktree_only` in the only same-cycle comparison.
6. **Code identity per live phase is not recorded by the driver** (§3.1).
   A future driver should record `git rev-parse HEAD` and `git status
   --porcelain` of the Shoestring checkout it compiled, in every phase record.
7. **Redacted provider ids remain in `main`'s history** (#6 limit), and so does
   the committed `.pyc` with an absolute home path (#7) until this branch
   merges. Rewriting history is destructive and outside this brief.
8. Carried from #83 and not re-examined here: run rows are never projected
   after start (`run_row_status: requested` on completed runs, visible
   throughout the summary); receivers act on the operator's global
   instructions; the projector still raises on busy.
9. **Not exercised live:** the failed-run and crash checkpoints, a real quota
   refusal (§2.2), and an automatic continuation after a decline.

## 7. Iteration 4/5 acceptance reconciliation

Against milestone 05's acceptance gate (`plans/milestones/05-quota-aware-mvp.md`).
"Before" is the #83 addendum (2026-09-24).

| # | Gate | Before | After this branch |
|---|---|---|---|
| 1 | Automatic dispatch never violates configured known reserves | hermetic | unchanged. No live refusal was exercised. Every live admission here was manual or owner-confirmed |
| 2 | Unknown/stale/reactive-only modes follow documented policy | hermetic + #83 live Claude `unknown` | unchanged. Live: the Claude ledger is `unknown / conservative_partial`, admitted only with owner confirmation (the 4 handoffs that reached a receiver) |
| 3 | All planned and failure stops create a minimum structural checkpoint | hermetic; live for completed and cancelled stops | **live for completed, cancelled, lease-suspended and interrupted** (§5.1). Failed and crash stops are still hermetic only |
| 4 | Checkpoint fallback performs no model inference | hermetic | unchanged. Live, the floor-template fallback fired twice (#2). The fallback is deterministic by construction, and absence of inference was not separately instrumented live |
| 5 | Wakeups and dispatches remain idempotent across restart | hermetic + #83 | dispatch: VERIFIED across 22 boots. Handoff replay: **no duplicate run, but a new job** (finding 4). Wakeup: the manual-scope recheck never succeeds (finding 1) |
| 6 | Same-provider resume and fake-backed cross-provider handoff | hermetic | unchanged |
| 7 | At least one real cross-provider handoff evaluated | demonstrated at `22c1e72` (#83) | **demonstrated again at `32a3fe6`**: 4 live handoffs, 2 of 2 passing after #3. The launch handshake that #83 lacked is now live-exercised (16 of 16) |
| 8 | Semantic eval shows receiver behaviour and handoff tax | partial, OPEN | **measured under the pre-registered design; the conclusion does not favour the product.** Per §2.5 the gate is met: three arms, two cycles, all measures. The product value it was meant to show was not shown. Promoting this to CLOSED is the reviewer's call; this record does not claim it |
| 9 | Every decision explainable from persisted inputs | hermetic | consistent live for the decisions inspected (the manual admissions and both renewal refusals carry their `explanation`, e.g. the `snapshot_provider_mismatch` text in §5.2). Not audited over all decisions |

**Iteration-4 locked decisions exercised live here:** source checkout never
modified (VERIFIED, §5.5); explicit cancellation terminates the owned group
(VERIFIED, §5.3); no timer by itself interrupted a working Elf (the only
stops were lease declines at a boundary, and the operator's explicit cancel);
normalized events buffered live (every transcript). Oversized output was not
exercised live.

**Iteration 6: stays locked.** This branch is unmerged and unreviewed, and
findings 1, 2 and 4 bear on gates 5 and 3.

### 7.1 Gate at the branch tip

`mix precommit` (format check, `compile --warnings-as-errors`, test,
`gate_0a.node_test`, `ui.node_test`) with a fresh `SHOESTRING_STATE_DIR`
under `$TMPDIR`, run by the recovery worker, exit 0:

- `4 doctests, 1454 tests, 0 failures, 1 skipped (6 excluded)`. Run three
  times with identical counts: on `d51f47c` plus the recovery's working-tree
  edits (120.6 s), on `168a2e4` (119.2 s), and on the commit that adds this
  sentence (reported in the PR);
- Node gate_0a: pass 52, fail 0;
- Node UI: pass 7, fail 0.

The 6 exclusions are the `@tag :live` provider smokes, not run. No provider
was called by the gate.
