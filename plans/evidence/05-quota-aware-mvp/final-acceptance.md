# Final iteration-4/5 acceptance: live Go Tic-Tac-Toe on the production path

Branch `polly/iter5-final-acceptance`, base `c1ae4a8` (#83 merged). Claim
labels follow this directory's `README.md`; an explanation that was not
isolated is marked **INFERENCE**.

> **Status of this document at this commit: PRE-REGISTRATION ONLY.** §2 fixes
> the fixture, the arm inputs, every measure and the verdict rules before the
> first live call. No live result exists yet. The driver that implements §2 is
> `tools/live_eval/final_acceptance.exs` at this same commit.

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
