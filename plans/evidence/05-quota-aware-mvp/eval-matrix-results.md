# Milestone 05: Deterministic Eval Matrix Results (WP Eval, T6)

- **Status**: Eval work package (Milestone 05, stacked on `c3779f0`: T1
  lifecycle+dispatcher, T2 leases, T3 checkpoints/wakeups, T4
  continuation/handoff, T5 UI all merged).
- **Scope**: Tests + test support + evidence docs ONLY. No production code
  was changed (`REPO-INSPECTION`: `git status` shows new files under
  `test/` and `plans/evidence/` only; `lib/`, `priv/`, `shoestring_web/`
  templates, and Oban queues untouched).
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. Files

| File | Role |
| :--- | :--- |
| `test/support/eval_matrix_helpers.ex` | Hermetic drivers: snapshot builders, grant payloads, wake/suspend/append helpers over the real T1–T5 interfaces. |
| `test/shoestring/harness/eval_matrix/matrix_test.exs` | 10-row normative matrix (10 tests). |
| `test/shoestring/harness/eval_matrix/ablation_test.exs` | Deterministic semantic ablation (1 test). |
| `test/shoestring/harness/eval_matrix/demo_test.exs` | Hermetic scripted demo, 8 steps (1 test). |

All tests use `Shoestring.Harness.Fake` scenarios, `FixedClock`, synthetic
identifiers (`Ecto.UUID.generate/0` for rows, `01950000-…` shape where
fixed) — no provider CLI, no network.

---

## 2. Per-Row Results (`VERIFIED`)

| # | Injection → Required result | Driver | Outcome |
| :- | :--- | :--- | :--- |
| 1 | Reserve refusal → no automatic dispatch | 85% 5h usage evaluates `defer_until/reserve_breach_five_hour`; deferred claim refuses lease with zero jobs/rows; admitted claim without `grant_lease:` stops at `execution_disabled` with zero jobs | PASS |
| 2 | False-zero defense → unknown/manual | Missing five_hour window → `require_confirmation/missing_window_five_hour`, `used_percent` nil never 0; nil snapshot → `require_confirmation` | PASS |
| 3 | Lease decline → checkpoint at boundary | `approaching_reserve` drains to renewal-due one reserve early; `maybe_renew` without stop appends nothing; stop+boundary with breached snapshot appends `lease.expired` then `lease.checkpoint_required` in order | PASS |
| 4 | Sudden exhaustion → fallback, no model call | `sudden_quota_refusal` yields `quota_refused`; `CheckpointFallback` + `Checkpoints.record` persist `stop_reason: quota_refused` with forced `checkpoint-fallback-v1` provenance and an empty `RequestLog` delta | PASS |
| 5 | Reset restart → one wakeup, fresh recheck | Suspended run + scheduled wake; two `Wakeups.reconcile/1` passes converge on exactly one `wakeup`-queue job; `perform_wakeup` with a fresh snapshot renews (chained to the fresh id) and resumes | PASS |
| 6 | Dispatch crash → no duplicate Elf | Orphan run intent repaired exactly once by `Runs.reconcile/1` then zero; `Fake.DispatchWorker` double-perform yields exactly one `run.running` event per `dispatch_id` | PASS |
| 7 | Handoff privacy → no raw transcript | `handoff_payload/1` carries exactly the registry-required keys with bounded binary `next_action`; every forbidden key refused; `scan_term` clean and `safe_term?` true; registry accepts | PASS |
| 8 | Same resume → one reconciled continuation | Matching continuation resumes once with exact pointer keys; stale / superseded / session-mismatch refusals precede the adapter call (`RequestLog` empty) | PASS |
| 9 | Incompatible update → pause/degrade visibly | `malformed_event` normalizes to `:schema_incompatible`; incompatible CLI evaluates `reject/incompatible_cli`; unknown trajectory types are rejected at append (never silently continued) | PASS |
| 10 | UI explanation → inputs match policy | One `admission.decided` per result/reason (`automatic_admission_eligible`, `reserve_breach_five_hour`, `unknown_capacity`, `unsupported_capability`); goal page cards assert matching reason + reserves + bounds; unknown codes fall back honestly via `CobblerPresentation` | PASS |

---

## 3. Lock vs Documentation (standing contract)

Fail-on-base verification (`VERIFIED`): with `test/support/eval_matrix_helpers.ex`
stashed (T6 driver removed, `lib/` byte-identical), `MIX_ENV=test mix test
test/shoestring/harness/eval_matrix/matrix_test.exs` yields **10 tests,
7 failures** — each failing with `UndefinedFunctionError` on the missing
driver module (the right reason: missing T6 driver, not a behavioural
difference). The remaining 3 rows (6, 7, 10) pass on base because they drive
only pre-existing helpers and producer behaviour directly.

- Rows 1–5, 8, 9: **documentation** (missing-driver failure on base).
- Rows 6, 7, 10: **documentation** (already-passing assertions on base —
  they pin wired behaviour but lock no T6 behaviour change, since T6 ships
  no producer).
- No row is a regression lock: T6 introduces no producer, so there is no
  pre-fix behaviour to fail against. Stated honestly here rather than
  claimed as coverage. No `UNWIRED` rows: every row is wired to a real
  producer seam, and no producer change was needed.

---

## 4. Acceptance Gate (`VERIFIED`, hermetic)

- Reserves never auto-violated (row 1: `defer_until` at ≥80% 5h, `execution_disabled` + zero jobs).
- Unknown/stale/reactive modes per policy (row 2: `require_confirmation`, nil never 0).
- Every planned/failure stop yields a structural checkpoint (rows 3–5: boundary expiry, fallback provenance, wake resleep path).
- Fallback performs no inference (row 4: pure template, empty log delta).
- Wakeups + dispatches idempotent across restart (rows 5–6: one job, one effect, repair-once-then-zero).
- Same-resume + fake cross-handoff work (row 8, ablation, demo: pointer-only continuations, `handoff.created`).
- Semantic eval shows behavior + tax (ablation: fallback arm completes with comparable normalized state; manual rubric in `ablation.md`).
- Every decision explainable from persisted inputs (row 10: reason + reserves + bounds rendered from stored events).

---

## 5. Explicitly Live-`UNVERIFIED`

Cross-provider LIVE handoff was not attempted: no live provider runs were
made and no run budget was authorized in the brief. A live handoff run would
require explicit authorization naming the run budget (provider, scenario,
and spend cap) before execution. Hermetic coverage is Fake-to-Fake only.
Real-model semantic effects (as opposed to the deterministic
fallback-template ablation recorded here) remain `UNVERIFIED`.

---

## 6. Loop-Closure Addendum — 2026-09-09 (`VERIFIED`, hermetic)

Prior §§1–5 above are quoted unchanged from the T6 work package. This section
records the I7 genuine loop-closure evals (branch `polly/iter5-i7-evals`,
stacked on `cc116f4`): the demo and ablation legs were rewritten to execute
through the real pipeline, and the milestone's three ablation arms were
implemented. Tests + test support + these docs only; `lib/`, `priv/`,
`shoestring_web/` templates, and Oban queues untouched (`REPO-INSPECTION`).

### 6.1 What changed (P1–P5 ledger)

- **P1 — real resumed execution.** `demo_test.exs` step 8 and every
  `ablation_test.exs` leg-B terminal now drive a real supervised Elf bound to
  the handoff run via `Dispatches.enqueue_for_run/1` (dispatch record + Oban
  job + stable `dispatch.requested` intent) and `Elves.start_elf/3` with the
  scripted Fake leg + a trivial local command
  (`test/support/eval_matrix_helpers.ex: drive_leg_to_terminal!/2`). The
  `run.starting` / `run.running` / `run.completed` events arrive via the
  Elf's production commit path together with the I3 terminal checkpoint.
  Every `Eval.append_event!` terminal insert on the driven path was removed;
  the tests additionally assert the `eval-matrix` actor appears nowhere on
  the driven runs and the terminal bears the Elf's durable
  `elf-terminal:<dispatch_id>` key. Setup history seeding (admission,
  capacity, lease events; leg-A suspend path) is retained and labeled as
  such.
- **P2 — three milestone arms.** `ablation_test.exs` drives worktree-only,
  naive-summary, and trajectory-projection inputs on one scripted fixture
  task (`fixture_leg_scenario/0`: relevant+irrelevant file inspection,
  constraint + rejected-approach record, partial implement, failing test,
  scripted refusal), with arm-differing checkpoint `next_action` only. Scores
  use the deterministic harness-synthesized normalization (terminal class,
  composed-prompt bytes, content class, decision-ref count, genuine event
  counts — no model judgment; see `ablation.md` §4).
- **P3 — fallback arm retained.** The prior authored-vs-fallback comparison
  is the fourth arm and reproduces: trajectory-projection vs fallback
  normalized terminal state is byte-equal (`:erlang.term_to_binary/1`).
- **P4 — acceptance re-assertion.** Every acceptance bullet below is
  re-asserted against the genuine loop; **UNWIRED rows: none** — every row is
  wired to a real producer seam and no producer change was needed.
- **P5 — no production changes.** Tests + `test/support` + evidence only.

### 6.2 Acceptance gate re-asserted against the genuine loop (`VERIFIED`)

- Reserves never auto-violated (matrix row 1, unchanged + genuine).
- Unknown/stale modes per policy (row 2, unchanged + genuine).
- Every planned/failure stop yields a structural checkpoint: leg-A fallback
  checkpoint via the `Checkpoints` writer (demo step 5, ablation arms) AND
  the automatic I3 terminal checkpoint before every Elf-driven `run.completed`
  (demo step 8, all four ablation arms).
- Fallback performs no inference (row 4: pure template, empty log delta).
- Wakeups + dispatches idempotent across restart (rows 5–6; demo steps 6–7
  admitted wake with fresh-snapshot renewal).
- Same-resume + fake-backed cross-handoff work (row 8; demo steps 7–8 and all
  ablation arms: exactly 1 fresh `start`, 0 `resume`s per handoff log,
  pointer-only continuations, `handoff.created`).
- Semantic eval shows receiver behavior + handoff tax (ablation §4:
  trajectory-projection totals 12 vs 9/9/9; per-arm prompt bytes 331 vs
  244/948/445; 3 scripted leg-B turns and 1-start/0-resume delivery on every
  arm).
- Every decision explainable from persisted inputs (row 10; demo step 8
  additionally asserts the leg-B prompt is byte-equal to the genuinely
  composed handoff prompt and carries no transcript text).

### 6.3 Lock vs documentation (standing contract)

Fail-on-base verification (`VERIFIED`): with the I7 driver additions
(`drive_leg_to_terminal!/2`, `fixture_leg_scenario/0`, `arm_next_action/1`,
`score_arm/1`, `leg_tax/2` in `test/support/eval_matrix_helpers.ex`)
removed, the demo and ablation files error on the missing driver module —
the right reason (missing driver, not a behavioural difference). I7 ships no
producer, so with the driver present these tests **document** wired loop
behavior honestly rather than locking a behavior change. No row is a
regression lock; stated honestly here rather than claimed as coverage.

Gate: `mix precommit` (exact command and counts in the work report).
