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
