# Iteration-5 Integration Closeout

Aggregate integration of the three approved Iteration-5 slices onto a single
branch, with an evidence-backed audit of what the combined state actually
supports.

**This document records an integration measurement, not an approval.** The
branch it describes has not been independently reviewed at the time of
writing, and the milestone is not declared complete here. See
[Unmet items and limitations](#7-unmet-items-and-limitations).

Claim labels follow the convention in this directory's `README.md`
(`VERIFIED`, `REPO-INSPECTION`, `SCHEMA-ONLY`, `UNVERIFIED`).

---

## 1. Source PR inclusion mapping

Base: `01f2a545980281ff354d235ad6ab787fe6a3b03a`
(`Merge pull request #71 from anukin/polly/iter5-admission-recovery-final`).

| Source PR | Branch | Head | Commits taken | Integrated as |
| --- | --- | --- | --- | --- |
| #72 checkpoint/resume | `polly/iter5-checkpoint-resume-muse` | `63d1839` | `6fd0ecd..63d1839` (2) | `a322880`, `6d488f1` |
| #73 handoff | `polly/iter5-handoff-production` | `988ea20` | `01f2a54..988ea20` (3) | `d05f479`, `5c0d387`, `9fcee53` |
| #74 UI | `polly/iter5-goal-ui` | `36a3254` | `01f2a54..36a3254` (1) | `0f31edf` |

Applied in the required `#72 → #73 → #74` order. Six commits total.

**Commit-range determination (VERIFIED).** `git merge-base` against the base
gives `6fd0ecd` for #72 and `01f2a54` for #73 and #74. #72 therefore branched
from main *before* the #71 admission/recovery merge, so its range starts at
`6fd0ecd`, not at the base. Using `6fd0ecd..63d1839` takes exactly the two
checkpoint commits and pulls in **no** unrelated history: `489a4ea`
(the admission/recovery commit #72's branch lacks) touches a file set disjoint
from #72's, so nothing from it is re-applied or reverted.

**No GitHub merge or close was performed on #72, #73 or #74** (REPO-INSPECTION:
this branch only cherry-picks; no `gh pr merge`/`close` was invoked).

---

## 2. New work in this branch, separate from the included commits

**There is none in source or test code.** (VERIFIED)

The integration required no conflict resolution commit, no fix commit, and no
behavioral change. Evidence:

- Every one of the 39 files changed against the base is byte-identical to the
  source PR head that last touched it, **except**
  `plans/evidence/05-quota-aware-mvp/README.md`.
- `git diff --name-only 01f2a54 HEAD` yields 39 paths; the union of the three
  source PR file sets yields the same 39 paths; the set difference is empty.
- The only merge was in `README.md`, auto-merged by git so the index carries
  both the `handoff-production.md` line (#73) and the `goal-ui.md` line (#74).
  Each source PR sees exactly one added line relative to this branch.

The only files this branch adds beyond the three PRs are this document and its
one-line entry in `README.md`.

**Consequence for review:** no integration defect was found, so none was fixed,
so there is no new behavioral regression test in this branch. A regression test
with nothing to lock would be documentation, not a regression lock.

---

## 3. Gate

Run in the integration worktree at HEAD, with fresh platform temp state
(`SHOESTRING_TEST_STATE_DIR` set to a newly created empty directory under
`System.tmp_dir!()`, i.e. `/var/folders/.../T/shoestring-iter5-integration-gate`).

Exact command:

    mix precommit

Exact result (VERIFIED, exit code 0):

    Finished in 97.3 seconds (7.6s async, 89.7s sync)
    1288 tests, 0 failures, 1 skipped (6 excluded)

    ℹ tests 52
    ℹ pass 52
    ℹ fail 0

`mix precommit` is `format --check-formatted`, `compile --warnings-as-errors`,
`test`, `gate_0a.node_test`; all four stages passed.

- **1 skipped** is `capability-appropriate resume behavior` in
  `Shoestring.Harness.ClaudeHeadlessContractTest`, skipped by the shared
  contract suite because `ClaudeHeadless` does not declare the `:resume`
  capability (`test/support/harness_contract_suite.ex:354`). This is a
  designed capability-appropriate skip, not a coverage gap.
- **6 excluded** are the `@tag :live` provider smoke tests, excluded by
  `test/test_helper.exs` (`ExUnit.start(exclude: [:live])`). They were **not**
  run: this task authorized no provider calls and no live quota use.

**The integrated count is a fresh measurement, not a derived one.** The prior
separate gates (#72 1204, #73 1259, #74 1225) are not summed and were not used
to predict 1288.

### State-directory note (honest record of a false failure)

Two earlier runs of the same gate reported `1288 tests, 1 failure`. The failing
test was `Shoestring.RepoTest` "opens the configured isolated SQLite database"
(`test/shoestring/repo_test.exs:11`), asserting
`String.starts_with?(database, System.tmp_dir!())`. The cause was the operator
pointing `SHOESTRING_TEST_STATE_DIR` at a scratchpad path outside
`System.tmp_dir!()`, not any defect in the integrated code. Re-running with a
fresh directory under the platform temp root gives 0 failures. Recorded here so
the discrepancy is not rediscovered as a flake.

### Targeted suites

Each run separately at HEAD, each with a fresh state directory under the
platform temp root (VERIFIED):

| Scope | Command | Result |
| --- | --- | --- |
| Both adapter contract suites | `mix test test/shoestring/harness/claude_headless_contract_test.exs test/shoestring/harness/codex_app_server_contract_test.exs` | 14 tests, 0 failures, 1 skipped |
| Shared contract suite + contracts + adapter | `mix test test/shoestring/harness/contract_suite_test.exs test/shoestring/harness/contracts_test.exs test/shoestring/harness/adapter_test.exs` | 24 tests, 0 failures |
| Deterministic eval matrix (incl. semantic + ablation fixtures) | `mix test test/shoestring/harness/eval_matrix/` | 15 tests, 0 failures |
| Eval matrix, second seed | `mix test test/shoestring/harness/eval_matrix/ --seed 4242` | 15 tests, 0 failures |
| Restart / handoff / admission recovery | `mix test test/shoestring/cobbler/handoff_production_test.exs test/shoestring/cobbler/handoff_crash_window_test.exs test/shoestring/cobbler/handoff_worker_test.exs test/shoestring/cobbler/admission_recovery_test.exs` | 60 tests, 0 failures |
| Checkpoint / resume | `mix test test/shoestring/elves/elf_checkpoint_resume_test.exs test/shoestring/elves/elf_resume_start_test.exs test/shoestring/elves/elf_terminal_checkpoint_test.exs test/shoestring/elves/terminal_checkpoint_test.exs` | 31 tests, 0 failures |
| Web / UI | `mix test test/shoestring_web/` | 175 tests, 0 failures |

The eval matrix passing under two different seeds is consistent with the
determinism the matrix claims; it is **not** a proof of determinism across all
orderings.

---

## 4. Acceptance matrix against the milestone contract

Graded against `plans/milestones/05-quota-aware-mvp.md`, which is the
**original milestone document, copied verbatim** — not a reconstruction.

The file was never lost. `plans/milestones/*` is gitignored (`.gitignore`
lines 45–50, under the comment "Planning documents are intentionally local to
this workspace"), allowlisting only `00a` and `02`, so this milestone was
simply never tracked. The original was recovered read-only from the untracked
working copy in the user's source checkout (11539 bytes, mtime 2026-08-29);
**that checkout was not modified**. Everything from `## Mission` through
`## Likely blockers and response` is byte-identical to it (verified: 10947
characters, equal); the only additions to the tracked copy are a provenance
note and the filled-in `## Completion record`, and one `.gitignore` allowlist
line was added to make it trackable.

Grading below is therefore against the **actual original requirements**, not
against a paraphrase and not narrowed to whatever evidence happened to exist.

### 4.1 Acceptance criteria (the nine)

| # | Criterion | Verdict | Basis |
| --- | --- | --- | --- |
| 1 | Automatic dispatch never violates configured known reserves | **Met (hermetic)** | matrix row 1 — reserve refusal defers, gate refuses with zero jobs |
| 2 | Unknown / stale / reactive follow documented policy | **Met (hermetic)** | matrix row 2 — missing windows stay unknown (never bare 0), require confirmation; `admission_policy.ex` |
| 3 | **All** planned and failure stops produce a minimum structural checkpoint | **Met for every stop path exercised** | `terminal_checkpoint.ex`, `checkpoint_fallback.ex`; `terminal_checkpoint_test.exs`, `elf_terminal_checkpoint_test.exs`, matrix rows 3–4. *Universal quantification over all stop paths is not proven by enumeration* — see residual risk 7 |
| 4 | Checkpoint fallback performs no inference | **Met (hermetic, strong)** | matrix row 4 — fallback checkpoint written with **zero adapter calls** |
| 5 | Wakes and dispatches idempotent across restart | **Met (hermetic)** | matrix row 5 (one wake + fresh recheck after reboot), row 6 (one effect per `dispatch_id` under kill + reconcile + double-perform) |
| 6 | Same-provider resume **and fake** cross-provider handoff both work | **Met (hermetic / Fake — which is what this criterion asks)** | `elf_checkpoint_resume_test.exs`, `elf_resume_start_test.exs`, `handoff_production_test.exs`, `semantic_fixture_test.exs` |
| 7 | One **real** cross-provider handoff, **or** explicit live-unverified | **Met via the contract's escape clause only** | No live run was performed or authorized; recorded explicitly as live-unverified here and in §6. **The preferred branch — a real cross-provider handoff — is unmet.** |
| 8 | Semantic eval shows receiver behavior and handoff tax, not only final pass | **Structurally met; unmet as real semantic evidence** | `ablation_test.exs` runs four arms on one fixture and records turns-to-progress and capacity consumed per arm as handoff-tax metrics. But receiver behavior is **fixture-authored**, and the milestone states outright: do not call fixture-authored receiver behavior real semantic evaluation. This document does not. |
| 9 | Every decision explainable from persisted policy inputs | **Met (hermetic)** | `admission_decision.ex`; matrix row 10 — goal page displays the persisted reason, reserves and bounds |

### 4.2 Work packages A–G

| Pkg | Requirement | Verdict | Basis / caveat |
| --- | --- | --- | --- |
| A | Legal transitions, intent before effects, idempotent restart reconciliation, ≤1 active Elf, UI commands not direct writes | **Met, with two stated caveats** | `goal_lifecycle.ex`, `dispatcher.ex`, `dispatch_gate.ex`, `commands.ex`. **(i)** The one-active-Elf guard is check-then-act, not a lock; `handoffs.ex:86` states the residual window itself and names the backstop (`Dispatches.prepare_for_effect/2` claims the row; `Elves.start_elf/3` returns `{:ok, :already_running, pid}`). **(ii)** A deliberate, audited expert/test hatch (`run[expert_bypass]` + non-blank `confirmed_by`, bypass audit event first) is the one production `start_run` caller — logged, not silent. |
| B | Durable decisions with full policy inputs; required admission conditions; no fabricated task percentage cost | **Met** | `admission_decision.ex`, `admission_evaluation.ex`, `admission_policy.ex`; matrix rows 1, 2, 10 |
| C | Fixed grant before execution, bounds advance on events, renewal at boundary/deadline, refresh at safe boundary, durable reasons, reactive fallback, timer never interrupts mutation | **Met** | `leases.ex`, `lease_bounds.ex`, `lease_grant.ex`, `lease_renewal.ex`; matrix row 3 (renewal fires one reserve early; stop+boundary expires to `checkpoint_required`) |
| D | Full checkpoint content set; no invented semantic certainty | **Met** | `Checkpoint` struct carries version, ids, acceptance contract, repository state, evidence, decisions, unresolved issues, next action, provider session id, stop reason, artifact ids; `final-checkpoint-resume.md`, `terminal-checkpoint.md` |
| E | Wake intent + absolute reset before job, boot repair, fresh recheck, durable dedupe, no model loop while sleeping | **Met** | `wakeups.ex`, `wakeup_record.ex`, `wakeup_reconciler.ex`, `wakeup_worker.ex`, `wakeup_observe.ex`; matrix row 5 |
| F | Bounded projection, explicit sections, same-provider native resume with reconciliation, fresh cross-provider session with no raw transcript, `handoff.created` | **Met (Fake providers)** | `continuation.ex`, `projector.ex`, `handoffs.ex`; matrix rows 7 (no forbidden key) and 8 (same-session resume validates once; mismatch refuses before adapter call) |
| G | Show one goal's state, provider, worktree, capacity/reserves, lease, checkpoint, sleep, handoff and warnings | **Partially met — 2 acceptance blockers, 1 nit** | Audited item by item in **§4.7** (executed: 65 tests, 0 failures across all six goal-page suites). Five of seven bullets fully met. **G-BLOCK-1:** checkpoint artifacts are never rendered. **G-BLOCK-2:** no next boundary is rendered or computed. **G-NIT-3:** sleep/reset shown as absolute times, not a countdown. No card was visually inspected at any viewport (§7). |

### 4.3 Deterministic matrix

All ten rows exist and pass (`test/shoestring/harness/eval_matrix/matrix_test.exs`;
15 tests, 0 failures, reproduced at a second seed). Row numbering maps 1:1 to
the contract's list:

| Contract row | Test | Status |
| --- | --- | --- |
| 1 reserve refusal, no auto dispatch | row 1 | Pass |
| 2 missing/malformed window → unknown/manual/defer | row 2 | Pass |
| 3 reserve-crossed lease checkpoints at next safe boundary | row 3 | Pass |
| 4 sudden exhaustion → fallback, no inference | row 4 | Pass |
| 5 sleeping restart → one wake + fresh recheck | row 5 | Pass |
| 6 post-intent crash → no duplicate Elf | row 6 | Pass |
| 7 handoff request → no raw transcript | row 7 | Pass |
| 8 same-session reconciled continuation | row 8 | Pass |
| 9 incompatible CLI/schema mid-goal pauses/degrades visibly | row 9 | Pass |
| 10 UI explanation matches persisted inputs/reasons | row 10 | Pass |

### 4.4 Semantic evaluation and ablation

The contract's three input arms exist on one shared fixture, plus a retained
fallback-template arm: `ablation_test.exs` runs `worktree_only`,
`naive_summary`, `trajectory_projection` and `fallback_template`, differing
only in the checkpoint `next_action` the receiver gets.
`semantic_fixture_test.exs` runs the three-arm form through the real handoff
path. Turns-to-progress and capacity consumed are recorded per arm as
handoff-tax metrics.

**Honest limit, stated as the contract demands:** the receiver's semantic
behavior is fixture-authored and the scoring uses harness-synthesized
deterministic normalization. `ablation_test.exs` says so in its own moduledoc,
including that I7 ships no producer, so with the driver present these tests
*document* wired loop behavior rather than *lock* a behavior change. **This is
not real semantic evaluation and is not presented as one.**

### 4.5 Demo

The scripted quota-aware demo exists and passes
(`demo_test.exs`: submit → admission/lease → partial work → exhaustion →
checkpoint → restart while sleeping → reset wake / provider switch → continue
without transcript and pass acceptance), against Fakes.

**The "then one live path" half is not done.** No live budget was authorized
for this task, so the contract's conditional ("if safely available and
authorized") is not satisfied.

### 4.6 Preflight and out of scope

- **Preflight is not fully satisfied.** The contract's first preflight item is
  iteration-4 completion, and iteration 4 carries an open UNVERIFIED item
  (§5). Both adapter contract suites pass (14 tests, 0 failures, 1
  capability-appropriate skip). The remaining preflight items — iteration-3
  tiers/stale policy, the four Fake scenarios, policy-labelled reserves, the
  attributable manual override, and the scripted fixture repository — are
  present and exercised by the suites above.
- **Out of scope respected** (REPO-INSPECTION of the 39-file integrated diff):
  the integrated slices add no learned consumption or checkpoint-distance
  estimation, no planner DAG or parallel product workers, no automated
  semantic judge as sole authority, no cross-provider review or autonomous
  merge, and no terminal takeover.

### 4.7 Work package G — full item-by-item audit

Performed as a deliberate audit of **every** original G bullet, not inferred
from the gate. Each row was traced to the rendering site and to the command
path behind it. `file:line` references are REPO-INSPECTION; the test column is
**executed** — all six goal-page suites were run for this audit:

    mix test test/shoestring_web/live/cobbler_goal_live_test.exs \
             test/shoestring_web/live/cobbler_goal_execution_test.exs \
             test/shoestring_web/live/cobbler_goal_terminal_test.exs \
             test/shoestring_web/live/cobbler_goal_recheck_test.exs \
             test/shoestring_web/live/cobbler_goal_authorization_test.exs \
             test/shoestring_web/live/cobbler_presentation_test.exs
    → 65 tests, 0 failures

Template paths below are `lib/shoestring_web/live/cobbler_goal_live.html.heex`
(`.heex`), `lib/shoestring_web/live/cobbler_goal_live.ex` (`.ex`) and
`lib/shoestring_web/live/cobbler_presentation.ex` (`presentation.ex`).

| G bullet | Verdict | Rendering (REPO-INSPECTION) | Test evidence (executed) |
| --- | --- | --- | --- |
| Cobbler state, active/queued provider, worktree | **Met** | State badge `#cobbler-goal-status` `.heex:29`. Executing provider `#cobbler-active-provider` `.heex:278` ("Owns the live turn on run", `.heex:285`), held strictly separate from the admission candidate block "evaluated, not executed" `.heex:357` with `#cobbler-candidate-provider/-adapter/-tier/-compatibility` `.heex:363–386`. Worktree card `#cobbler-worktree` `.heex:407` with path/branch/base-commit/repo id `.heex:448–470` and an explicit `#cobbler-worktree-unknown` state `.heex:480`. | `cobbler_goal_execution_test.exs`, `cobbler_goal_live_test.exs`, `cobbler_goal_terminal_test.exs` |
| Capacity evidence and reserves used for the last decision | **Met** | `#cobbler-decision-reserves` `.heex:110` and `#cobbler-decision-observation` `.heex:114`, beside result `.heex:90`, reason `.heex:104` and `defer_until` `.heex:119`. | `cobbler_goal_terminal_test.exs`, `cobbler_goal_live_test.exs`, and matrix row 10 (`matrix_test.exs`) |
| Lease bounds, **next boundary**, renewal status | **Partially met — gap G-BLOCK-2** | Bounds rendered `.heex:165–183`: response budget, tool budget, response reserve, tool reserve, checkpoint cadence, deadline. Renewal status `#cobbler-lease-renewal` `.heex:155` over `renewal_presentation/1` `presentation.ex:508–546`. **No next boundary is rendered or computed** — see below. | `cobbler_goal_live_test.exs` (`#cobbler-lease`, `#cobbler-lease-renewal`) |
| Checkpoint contents **and artifacts** | **Partially met — gap G-BLOCK-1** | Contents `#cobbler-checkpoint-contents` `.heex:215`, plus next action and stop reason `.heex:209–211`. **Artifacts are not rendered** — see below. | `cobbler_goal_live_test.exs` (`#cobbler-checkpoint-contents`) |
| Sleep/reset **countdown** and manual recheck | **Partially met — nit G-NIT-3** | Sleep card `#cobbler-sleep-card` `.heex:551`; deferral target `.heex:557–566`; next wake intent `#cobbler-pending-wake` `.heex:577` with reason and status. Manual recheck form `#cobbler-recheck-form` `.heex:589` requires an operator identity `.heex:595` before `phx-submit="request_recheck"` — attributable, matching the milestone's "explicit, attributable, never automatic safety". **Times are absolute ISO-8601 only; no countdown.** | `cobbler_goal_recheck_test.exs` (`#cobbler-sleep-card`, `#cobbler-pending-wake`, `#cobbler-recheck-form`) |
| Handoff source/receiver and explanation | **Met** | `#cobbler-handoff` `.heex:492`; source `.heex:503`, receiver `.heex:513`, reason `.heex:521`, next action `.heex:523`, new/prior run and checkpoint id `.heex:525–529`; `#cobbler-handoff-empty` `.heex:538`. | `cobbler_goal_terminal_test.exs:104–110` asserts the card, source (`codex`), receiver (`claude`), reason (`provider quota refused`) and the new run id |
| Explicit degraded/manual mode warnings | **Met** | Banner `#cobbler-warnings` `.heex:54`, headed "Degraded state" `.heex:59`, fed by `build_warnings/3` `.ex:772–830`: stale observation, degraded capacity, projection failed, rebuild diverged. Separate `#cobbler-rebuild-warning` `.heex:71`. Manual mode surfaces as `decision_presentation(:require_confirmation)` `presentation.ex:285–293` — "Needs confirmation." / "Requires an attributable single-decision operator confirmation." / `status: "confirmation-required"`. | `cobbler_goal_live_test.exs` (`#cobbler-warnings`), `cobbler_presentation_test.exs` |

#### G-BLOCK-1 — checkpoint artifacts are never rendered (acceptance blocker)

**Finding (REPO-INSPECTION, traced to the terminal consequence).**
`checkpoint_display/1` at `.ex:733–751` builds the rendered payload from
exactly five keys — `acceptance_contract`, `repository_state`, `evidence`,
`decisions`, `unresolved_issues`. The `Checkpoint` struct carries
`artifact_ids` (`lib/shoestring/harness/checkpoint.ex`), and the record is
read whole at `.ex:720–729`, but `artifact_ids` is dropped before rendering.
A case-insensitive search for `artifact` across the goal template and its
LiveView returns **zero** matches. The G bullet requires "checkpoint contents
**and artifacts**"; artifacts are unreachable from this page.

**Bounded proposed fix (not applied — this turn is docs-only).** Add
`"artifact_ids" => checkpoint.artifact_ids` to the `contents` map at
`.ex:734–740`, or, preferably, render a dedicated
`<dd id="cobbler-checkpoint-artifacts">` in the checkpoint card beside next
action and stop reason, falling back to the card's existing "not recorded"
idiom when the list is empty. Add one assertion to
`cobbler_goal_live_test.exs` alongside the existing
`#cobbler-checkpoint-contents` case. Estimated ~10 lines of source plus one
test. No domain or schema change: the data is already persisted and already
loaded.

#### G-BLOCK-2 — no next boundary is rendered (acceptance blocker)

**Finding (REPO-INSPECTION).** The G bullet requires "lease bounds, **next
boundary**, and renewal status". Bounds and renewal status are rendered;
the next boundary is not, and no such concept exists to render: a search for
`next_boundary`, `next safe boundary` and `boundary_at` across
`lib/shoestring_web`, `lib/shoestring/cobbler/leases.ex` and
`lib/shoestring/cobbler/lease_bounds.ex` returns **zero** matches.

The inputs do exist. `LeaseBounds` (`lease_bounds.ex:51–67`) carries
`checkpoint_cadence` together with the live counters `responses`, `tools`,
`epoch` and the `due` flag. The template renders `checkpoint_cadence`
(`.heex:176`) but **none of the consumed counters**, so an operator can see
the cadence and the budget but cannot see progress toward the next boundary,
which is precisely what the bullet asks for.

**Bounded proposed fix (not applied).** Thread `responses`, `tools` and
`epoch` from `LeaseBounds` into the lease assign and render a derived
"Next boundary" row — e.g. `responses` of `checkpoint_cadence` consumed —
in the existing `<dl>` at `.heex:165–183`, with the renewal badge continuing
to carry the `due` state. Add one assertion to `cobbler_goal_live_test.exs`.
Estimated ~15 lines of source plus one test. No new domain concept and no
schema change are required; this is a projection of state the lease already
holds.

#### G-NIT-3 — sleep/reset shown as absolute times, not a countdown

**Finding (REPO-INSPECTION).** `.heex:557–585` renders `defer_until` and
`pending_wakeup.wake_at` as absolute ISO-8601 `<time>` values. The bullet says
"sleep/reset **countdown**". No relative remaining-time is displayed.

**Classified NIT, not a blocker.** The absolute reset time — the decision-
relevant fact — is shown, and the surrounding copy is deliberately explicit
that no wake time is invented and that only a durable wake intent wakes the
goal, which serves the milestone's locked decision on sleep honesty. A
countdown derived from a persisted `wake_at` would not violate that.
**Bounded fix if wanted:** render a relative delta beside the absolute time.
Left alone here because the task forbade broadening scope for cosmetic work.

#### Two suspected defects traced and cleared (recorded so they are not re-raised)

- **Duplicate DOM id `cobbler-active-provider`** at `.heex:278` and
  `.heex:295`. **Not a defect** — the two sites are the `if`/`else` branches of
  `@execution.executing_run` (`.heex:276`, `.heex:293`), so exactly one ever
  renders.
- **`checkpoint_display/1` discards `_omitted, _truncated?`** at `.ex:743–744`,
  suggesting silent truncation. **Not a defect** — `RunPresentation.cap_text/2`
  (`run_presentation.ex:248–258`) embeds the marker
  `… [truncated, N bytes omitted]` into the returned string, so truncation is
  visible on the page even though the boolean is dropped.

#### Scope note

The original G bullet list is scoped to "Show one goal's: …", so this audit
covers the goal page and the presentation module behind it. The instruction to
audit *all* items rather than only the cards PR #74 changed was followed: every
one of the seven bullets above was traced independently, including the four
whose rendering predates #74.

---

## 5. Iteration-4 dependency truth

Iteration 5 rests on iteration-4 harness verification, which is **partially
live-verified and must not be promoted** (REPO-INSPECTION of
`plans/evidence/04-single-elf/harness-live-verification.md`):

- A single live turn per provider (Claude and Codex) was genuinely run and
  recorded VERIFIED there: adapter start, terminal class `completed`, durable
  terminal and normalized event counts, exact marker bytes, user source
  checkout unchanged, provider process group dead after terminal, adapter
  session deregistered.
- A normalization defect was found and fixed, and the fix has hermetic
  verification. **A second Codex live turn after that fix is recorded
  UNVERIFIED** because the authorized two-turn provider budget was exhausted.

That gap is unchanged by this integration. Nothing in this document upgrades
it, and no iteration-4 claim was re-labeled.

---

## 6. Residual risks

1. **Cross-provider handoff has never run against real providers**
   (acceptance 7). The durable intent, worker, reconciler and crash-window
   recovery are proven against `Fake`. Real provider session-resume semantics,
   real refusal shapes and real timing are unproven.
2. **Semantic continuation quality is fixture-authored** (acceptance 8). The
   eval matrix and ablation prove the plumbing, the arm separation and the
   handoff-tax metrics — not that a real provider continues a task coherently
   across a handoff.
3. **The one un-rerun iteration-4 Codex live turn** (§5) remains the known gap
   in the layer beneath this milestone, and keeps the contract's hard
   dependency unsatisfied.
4. **UI is code-audited and test-verified but never looked at** (package G).
   All seven G bullets were traced to their rendering sites and the six
   goal-page suites executed (65 tests, 0 failures), surfacing two acceptance
   blockers (§4.7). But no human or machine has seen the rendered result at
   any viewport, so pixel-level regressions, layout breakage and
   mobile-viewport behavior remain unverified.
5. **#72 was developed against a pre-#71 base.** Its file set is disjoint from
   #71's, and the full integrated gate is green, so no interaction defect is
   known — but #72's own gate never ran with #71's admission/recovery code
   present. The 1288-test integrated gate at this HEAD is the first run that
   covers that combination.
6. **`Oban.Repo` emits a typing warning** from the dependency during
   compilation. It does not fail `--warnings-as-errors` (dependency code) and
   is pre-existing, not introduced here.
7. **"All stops produce a checkpoint" is proven per exercised path, not
   universally** (acceptance 3). The terminal path, the fallback path and the
   matrix stop rows are covered; nothing in the suite enumerates every
   reachable stop path, so the universal form of the claim rests on code
   structure rather than exhaustive test coverage.
8. **The one-active-Elf guard is check-then-act, not a lock** (package A).
   `handoffs.ex:86` documents the residual window and names its backstop: the
   dispatch row claim in `Dispatches.prepare_for_effect/2` and the run-id
   registration in `Elves.start_elf/3`, which returns
   `{:ok, :already_running, pid}` instead of starting a second Elf. The
   backstop is what prevents two Elves, not this module.

---

## 7. Unmet items and limitations

Stated as the contract requires: **hermetic completeness is not milestone
acceptance completeness.** The hermetic suite is green; the milestone is not
complete.

### Unmet

1. **No real cross-provider handoff** (acceptance 7, preferred branch; demo's
   live half). Satisfied only through the contract's explicit
   live-unverified escape clause. No provider process was started and no
   quota was consumed — none was authorized.
2. **No real semantic evidence** (acceptance 8). The ablation shows receiver
   behavior and handoff tax across arms, but fixture-authored, which the
   contract forbids calling real semantic evaluation.
3. **Package G has two acceptance blockers.** The audit is now complete (§4.7,
   every one of the seven original bullets traced, 65 tests executed, 0
   failures). Five bullets are fully met. Two are not, and both are genuine
   contract gaps rather than test gaps:
   **G-BLOCK-1** — checkpoint **artifacts** are never rendered
   (`cobbler_goal_live.ex:733–751` drops `artifact_ids`; "artifact" appears
   nowhere in the goal page).
   **G-BLOCK-2** — no **next boundary** is rendered or computed
   (`next_boundary` has zero occurrences across the web layer and the lease
   modules; the consumed counters `responses`/`tools` that would derive it are
   not surfaced).
   Bounded fixes for both are specified in §4.7, roughly 10 and 15 lines of
   source plus one test each, with no schema or domain change. **They were not
   applied: this turn was docs-only by instruction.**
   **G-NIT-3** (sleep/reset shown as absolute times rather than a countdown) is
   recorded as a nit, not a blocker.
4. **UI visual validation was not performed at any viewport.** Neither browser
   path was reachable — no Chrome extension instance is connected
   (`list_connected_browsers` → `[]`) and the Omnigent embedded pane timed out
   (desktop app not running); no `sys_terminal` tool exists in this session. A
   dev server was deliberately **not** started: `config/config.exs` enables
   `:capacity_monitors` for both providers outside test, and both `codex` and
   `claude` are on `PATH` here, so a dev boot would risk exactly the live
   provider probes this task forbids. Recorded as a limitation rather than
   worked around.
5. **Preflight is not fully satisfied**, because iteration 4 is not complete
   (§5).

### Iteration 6 is not unlocked

The contract states iteration 6 must not be unlocked unconditionally while
iteration 4 is incomplete or the eval gates are unmet. **Both conditions are
currently live:** iteration 4 carries an open UNVERIFIED live turn, and the
eval gate's real-semantic and real-cross-provider halves are unmet. Iteration 6
should not be started on the strength of this integration.

### Status

- **Hermetic implementation: complete and green** for work packages A–F, all
  ten deterministic matrix rows, both adapter contract suites, and the scripted
  demo — at the measured gate in §3.
- **Milestone acceptance: incomplete**, on items 1–5 above.

### Other limitations

- The milestone record this document grades against is the **original**,
  recovered verbatim from the untracked working copy in the user's source
  checkout and now tracked here (see its provenance note). It is absent from
  git history only because `plans/milestones/*` is deliberately gitignored;
  tracking it required one `.gitignore` allowlist line, which is a deviation
  from the "docs only" scope of the task that restored it.
- Pre-existing nits in the included slices were left alone; no cosmetic
  cleanup was attempted.
