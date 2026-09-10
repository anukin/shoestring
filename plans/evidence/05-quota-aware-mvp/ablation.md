# Milestone 05: Semantic Ablation (WP Eval, T6)

- **Status**: Eval work package (Milestone 05, stacked on `c3779f0`).
- **Scope**: Deterministic ablation test (`ablation_test.exs`) + this
  procedure/rubric for a later human run with real trajectories. Tests +
  docs only; no production code changed.
- **Evidence Labels**: `VERIFIED` (deterministic test runs in this
  worktree), `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly
  marked).

---

## 1. Deterministic Ablation (`VERIFIED`)

Two arms on the scripted `sudden_quota_refusal → handoff_target`
trajectory, differing ONLY in checkpoint `next_action` provenance:

- **Intact arm**: authored `next_action`
  (`"continue from step 3: implement the widget and run the suite"`).
- **Fallback arm**: `Shoestring.Harness.CheckpointFallback` template
  `next_action` (deterministic resume template, `stop_reason:
  "quota_refused"`, forced `checkpoint-fallback-v1` provenance).

Each arm: Fake partial work + quota refusal → checkpoint → projection →
`Continuation.for_goal/1` (what Elf B receives — never the transcript) →
`Elves.resume_run/3` handoff to `handoff_target` → `run.completed` →
terminal projection.

**Result: PASS** (`VERIFIED`, hermetic, Fake-to-Fake only): the fallback arm
still reaches `run.completed` with the privacy sweep green
(`scan_term == []`, `safe_term? == true`) and a normalized terminal
projection state byte-comparable to the intact arm
(`:erlang.term_to_binary/1` equality over run status, decision-ref count,
reason, provider, next-action presence, and stop reason — raw identifiers
excluded by construction). Per the brief, EITHER outcome would have been
recorded as informative; the deterministic tests are authoritative.

---

## 2. Manual-Trajectory Procedure (for a later human run, `UNVERIFIED`)

1. **Setup**: check out the milestone-05 worktree at the recorded commit;
   confirm `mix precommit` is green before starting.
2. **Elf A (full context)**: open the fixture task worktree with relevant
   AND irrelevant files visible. Record one constraint (e.g. quota reserve)
   and one rejected approach in the trajectory before implementing.
3. **Partial implementation**: implement until the first fixture test
   exposes a second failure; commit the partial state (do not fix).
4. **Scripted interruption**: inject the quota refusal (provider reports
   refusal before refresh). Record the deterministic fallback checkpoint
   (`stop_reason: quota_refused`) with no further model calls.
5. **Elf B (ablated context)**: fresh worktree + checkpoint projection
   ONLY (checkpoint id, `next_action`, up to 32 decision refs — never the
   sender transcript). Continue to the fixture's terminal state.
6. **Record**: trajectory events, checkpoint payloads, handoff payloads
   (both sweep directions), turn counts, and capacity consumed per arm in a
   dated appendix to this file. Do not paste credentials, real paths, or
   reasoning scratchpads; use synthetic `01950000-…` identifiers.

---

## 3. Scoring Rubric (0–2 per dimension, human-judged)

| Dimension | 0 | 1 | 2 |
| :--- | :--- | :--- | :--- |
| Acceptance tests / artifact | Terminal state not reached | Reached with degraded scope | Reached at full fixture scope |
| Constraint preservation | Reserve/privacy constraint violated | Preserved after correction | Preserved throughout |
| Work recognition | Redoes completed work unknowingly | Reuses some prior evidence | Builds exactly on prior evidence/decisions |
| Repeated work (tax) | >50% of Elf A effort repeated | Some repetition, bounded | No substantive repetition |
| Turns-to-progress | Stalls or loops | Progress with backtracking | Steady progress per turn |
| Capacity consumed | Exceeds the task budget | Within budget after waste | Within budget, no waste |

Record per-arm scores plus the delta (ablation tax). A single human run is
anecdotal, not statistical: report it as `UNVERIFIED` evidence with the
trajectory attached, never as a pass/fail gate.

---

## 4. Loop-Closure Addendum — 2026-09-09 (`VERIFIED`, hermetic)

Prior §§1–3 above are quoted unchanged from the T6 work package. This section
records the I7 genuine loop-closure ablation (branch `polly/iter5-i7-evals`,
stacked on `cc116f4`): the milestone's three arms plus the retained fallback
arm, every leg-B terminal driven through a real supervised Elf. Tests + test
support + these docs only; no production code changed.

### 4.1 Arms (one scripted fixture task, arms differ ONLY in `next_action`)

Leg A (identical all arms): `fixture_leg_scenario/0` — lifecycle, three
outputs (relevant `lib/widget.ex` + irrelevant `lib/unrelated.ex`
inspection; constraint `five-hour reserve` + rejected approach B in-memory
cache; partial implement steps 1–2 with `WidgetTest` second case FAILING),
then scripted `quota_refused/rate_limit_exceeded`. Checkpoint through the
genuine `Checkpoints` writer (arm `next_action`; shared evidence/decisions),
projection, `Elves.resume_run/3` handoff to `fake-harness-b`, then leg B
(`handoff_target` RESULT) consumed by a real Elf bound via
`Dispatches.enqueue_for_run/1` + `Elves.start_elf/3`.

| Arm | `next_action` input (bytes) | Composed prompt (bytes) |
| :--- | ---: | ---: |
| worktree-only | 43 (generic: no constraint, no step) | 244 |
| naive-summary | 747 (constraint buried in transcript noise) | 948 |
| trajectory-projection | 130 (crisp: step + constraint + rejection) | 331 |
| fallback-template | 244 (deterministic resume template) | 445 |

### 4.2 Rubric scores (deterministic normalization, `VERIFIED`)

Normalization (also in `EvalMatrixHelpers` moduledoc): acceptance from the
Elf-reported terminal class; constraint from constraint-presence × prompt
concision (≤800 B crisp); recognition from concrete-step × decision-refs ×
concision; repeated-work from prompt bytes (≤500/1200 B); turns from the
genuine leg-B `harness.event_recorded` count (3 every arm — scenario-fixed);
capacity from the genuine handoff delivery (1 start, 0 resumes every arm).
No model judgment; semantic redo beyond these proxies stays human-judged.

| Arm | Accept | Constraint | Recognition | Repeated | Turns | Capacity | **Total** |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| worktree-only | 2 | 0 | 1 | 2 | 2 | 2 | **9** |
| naive-summary | 2 | 1 | 1 | 1 | 2 | 2 | **9** |
| trajectory-projection | 2 | 2 | 2 | 2 | 2 | 2 | **12** |
| fallback-template | 2 | 0 | 1 | 2 | 2 | 2 | **9** |

### 4.3 Handoff tax per arm (genuine, `VERIFIED`)

Every arm: terminal class `completed` via Elf; `RunRecord` status
`completed`; privacy sweep green (`scan_term == []`, `safe_term? == true`);
3 scripted leg-B turns; exactly 1 fresh adapter `start`, 0 `resume`s; the
`eval-matrix` actor appears nowhere on the driven runs. Tax delta is the
input: 244–948 prompt bytes for the same completed outcome.

### 4.4 Prior result reproduced (P3, `VERIFIED`)

Trajectory-projection vs fallback-template normalized terminal state
(run status, decision-ref count, reason, provider, next-action presence,
stop — raw identifiers excluded by construction) is byte-equal via
`:erlang.term_to_binary/1`, exactly as in §1. The template preserves safe
completion but carries no task constraint (constraint score 0) — recorded
honestly, not softened.

**UNWIRED rows: none.** Every arm is wired end-to-end (adapter leg →
checkpoint writer → projection → handoff → dispatch pipeline → supervised
Elf terminal); no producer seam was missing and none was added.

## 5. W7 addendum: genuine fixture-task arms (mechanical acceptance)

The §1–§4 arms run scripted-success receivers; this section records the
genuine follow-up (`semantic_fixture_test.exs`, deterministic receiver
`test/fixtures/fixture_applier.py`, python3 stdlib only): a real git
fixture project, a real leg-A Elf whose failing check yields a real
failed terminal, a checkpoint with real repo evidence (revision, dirty
diff, terminal event) plus fixture-authored semantic strings (constraint,
rejected approach, next-action instruction — exactly what a model authors
in production), and per-arm real leg-B Elves whose terminal class comes
from the applier's real exit code fused with real progress events.
Acceptance is re-verified independently (fresh `check.sh` run + byte
comparisons), never trusted from the applier.

Arm inputs (same leg A, same applier, only the prompt differs):
worktree-only (bare listing), naive-summary (fix instruction, no
constraint, noisy file list), trajectory-projection (real composed
handoff prompt: fix + constraint + minimal refs).

Locking status: all producers are merged, so these tests pass on the
pre-fix tree too — documentation of genuine loop behavior (mechanical
terminals, file bytes, exit codes), not behavior-change locks. Internal
invariants (trajectory acceptance/constraint, worktree failure,
read-count ordering) fail on regressed mechanics.
