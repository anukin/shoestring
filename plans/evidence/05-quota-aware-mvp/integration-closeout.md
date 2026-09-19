# Iteration-5 Integration Closeout

Aggregate integration of the three approved Iteration-5 slices onto a single
branch, with an evidence-backed audit of what the combined state actually
supports.

**This document records an integration measurement, not an approval.** The
branch it describes has not been independently reviewed at the time of
writing, and the milestone is not declared complete here. See
[Unmet and Limitations](#unmet-and-limitations).

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

## 4. Acceptance matrix

The milestone plan this matrix should be graded against does not exist in the
repository (see [Unmet and Limitations](#unmet-and-limitations)). The rows
below are therefore grounded in the capability areas the three integrated
slices and the base actually claim, each tied to committed evidence and to a
suite that ran at this HEAD. Support level is stated per row.

| # | Capability | Support at this HEAD | Evidence | Exercised by |
| --- | --- | --- | --- | --- |
| A1 | Reliable terminal checkpoints on the Elf terminal path | Supported, hermetic | `final-checkpoint-resume.md`, `terminal-checkpoint.md` | `terminal_checkpoint_test.exs`, `elf_terminal_checkpoint_test.exs` |
| A2 | Same-provider continuation / resume-first start | Supported, **Fake-backed** | `final-checkpoint-resume.md`, `round-3-fixes.md` | `elf_checkpoint_resume_test.exs`, `elf_resume_start_test.exs` |
| A3 | Durable `run.handoff` Cobbler command, authorize/identity first, one-active-Elf guard | Supported, hermetic | `handoff-production.md` | `handoff_production_test.exs` |
| A4 | Handoff queue worker + boot reconciler consume the intent end to end | Supported, hermetic | `handoff-production.md` | `handoff_worker_test.exs` |
| A5 | Decision-to-pointer crash-window recovery; durable `handoff.failed` settling | Supported, hermetic | `handoff-production.md` | `handoff_crash_window_test.exs` |
| A6 | Removal of the unsupervised `Elves.resume_run/2` cross-provider bypass | Supported | `handoff-production.md` | `handoff_production_test.exs`, `safe_stop_session_lookup_test.exs` |
| A7 | Admission decisions, operational reserve, wake/dispatch crash-window recovery | Supported (from base #71) | `final-admission-recovery.md`, `admission-policy.md` | `admission_recovery_test.exs` |
| A8 | Goal-page worktree identity from the durable record | Supported | `goal-ui.md` | `cobbler_goal_execution_test.exs` |
| A9 | Executing provider kept distinct from admission candidate and from provider-reported evidence; explicit per-state unknowns | Supported | `goal-ui.md` | `cobbler_presentation_test.exs`, `cobbler_goal_execution_test.exs` |
| A10 | Adapter contract conformance (Codex app-server, Claude headless) | Supported, hermetic; `:resume` not declared by ClaudeHeadless | `handoff-production.md`, iteration-4 adapter evidence | both contract suites |
| A11 | Deterministic eval matrix with genuine arms | Supported, **fixture-authored semantics** | `eval-matrix-results.md`, `ablation.md`, `round-4-fixes.md` | `matrix_test.exs`, `demo_test.exs`, `ablation_test.exs`, `semantic_fixture_test.exs` |
| A12 | Cross-provider handoff against real providers | **LIVE-UNVERIFIED** | — | not exercised; `:live` tests excluded |
| A13 | UI visual appearance, desktop and mobile | **UNVERIFIED** | — | no browser tooling reachable |

### Supported vs fake-backed vs live-unverified

- **Supported and hermetically exercised at this HEAD:** A1, A3, A4, A5, A6,
  A7, A8, A9, A10.
- **Fake-backed** — real control flow and real durable state, but the provider
  is `Shoestring.Harness.Fake` and the semantic content is fixture-authored:
  A2, A11. `semantic_fixture_test.exs` says so in its own moduledoc: the
  semantic strings remain fixture-authored and cross-provider live behavior is
  unverified. **Fake semantic continuation is not evidence of real provider
  semantic continuation** and is not treated as such here.
- **Live-unverified:** A12, and the live half of A2/A11. No provider process
  was started and no quota was consumed by this task.

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

1. **Cross-provider handoff has never run against real providers** (A12). The
   durable intent, worker, reconciler and crash-window recovery are proven
   against `Fake`. Real provider session-resume semantics, real refusal shapes,
   and real timing are unproven.
2. **Semantic continuation quality is fixture-authored** (A2, A11). The eval
   matrix proves the plumbing and the arm separation, not that a real provider
   continues a task coherently across a handoff.
3. **The one un-rerun iteration-4 Codex live turn** (section 5) remains the
   only known gap in the layer beneath this milestone.
4. **UI is test-verified but never looked at** (A13). 175 web tests pass,
   including the changed cards' assertions, but no human or machine has seen
   the rendered result at any viewport in this integration.
5. **#72 was developed against a pre-#71 base.** Its file set is disjoint from
   #71's, and the full integrated gate is green, so no interaction defect is
   known — but #72's own gate never ran with #71's admission/recovery code
   present. The 1288-test integrated gate at this HEAD is the first run that
   covers that combination.
6. **`Oban.Repo` emits a typing warning** from the dependency during
   compilation. It does not fail `--warnings-as-errors` (dependency code) and
   is pre-existing, not introduced here.

---

## 7. Unmet and Limitations

- **The milestone plan does not exist.** `plans/milestones/05-quota-aware-mvp.md`
  is absent from the working tree **and from every ref in the repository**
  (VERIFIED: `git log --all -- plans/milestones/05-quota-aware-mvp.md` is
  empty; `plans/milestones/` contains only `00a-capacity-feasibility.md` and
  `02-harness-contracts-fake.md`). The requested audit of the full milestone
  against integrated evidence therefore **could not be performed as specified**.
  Section 4 substitutes an audit against the capability claims that committed
  evidence actually makes. Grading against the real milestone document remains
  **unmet** until that document exists.
- **UI browser visual validation was not performed.** Neither browser path was
  reachable: no Chrome extension instance is connected
  (`list_connected_browsers` → `[]`), and the Omnigent embedded pane timed out
  (desktop app not running). No `sys_terminal` tool exists in this session.
  A dev server was deliberately **not** started: `config/config.exs` enables
  `:capacity_monitors` for both providers outside test, and both `codex` and
  `claude` are on `PATH` here, so a dev boot would risk exactly the live
  provider probes this task forbids. Desktop and mobile inspection of the
  changed cards is **unmet**, and is recorded as a limitation rather than
  worked around.
- **No live provider verification of any kind** was performed (A12, and the
  live half of A2/A11).
- Pre-existing nits in the included slices were left alone; no cosmetic
  cleanup was attempted.
