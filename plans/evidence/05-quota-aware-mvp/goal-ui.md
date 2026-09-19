# Milestone 05: Goal-Page Worktree and Provider Explanation

- **Status**: Goal-page UI slice (Milestone 05), stacked on `01f2a54`.
- **Scope**: The per-goal Cobbler explanation page
  (`/cobbler/goals/:goal_id`) gains two read-only cards — **Execution
  Provider** and **Isolated Worktree** — that show real worktree identity
  where a durable record exists and keep an actively executing provider
  strictly separate from an admission candidate. No backend, runtime,
  migration, or shared-config change; no new write path and no new handoff
  control.
- **Evidence Labels**: `VERIFIED` (command output from this worktree),
  `REPO-INSPECTION` (committed code read in this worktree), `UNVERIFIED`
  (explicitly marked).

---

## 1. Changed Surface (`REPO-INSPECTION`)

| Path | Change |
| :--- | :--- |
| `lib/shoestring_web/live/cobbler_presentation.ex` | Adds `run_provider_presentation/1` (harness run execution state, carrying an `:executing?` predicate) and `worktree_presentation/1` (durable worktree record state). Both follow the module's existing `:unknown` fallback discipline. |
| `lib/shoestring_web/live/cobbler_goal_live.ex` | Adds the `:execution` and `:worktree` assigns: latest run, executing run, admission candidate, and the durable worktree record keyed by run id. All reads; no new event, no new write. |
| `lib/shoestring_web/live/cobbler_goal_live.html.heex` | Adds `#cobbler-provider` and `#cobbler-worktree` cards between the existing claim and handoff cards, in the incumbent card idiom. |
| `test/shoestring_web/live/cobbler_goal_execution_test.exs` | New: 15 DOM-ID LiveView tests. |
| `test/shoestring_web/live/cobbler_presentation_test.exs` | Adds 3 unit tests for the two new mappers. |

## 2. The Distinction the Cards Enforce (`REPO-INSPECTION`)

Two facts that are easy to conflate are answered separately and never merged:

- **Which provider is executing now.** The newest `harness_runs` row for the
  goal whose `status` is in `["starting", "running", "pausing", "cancelling"]`.
  These are the states in which a provider owns a live turn. `requested` is a
  dispatched intent that is *not* executing; every suspended and terminal
  state has stopped. When no such row exists the card says so in words and
  **never promotes the latest run's provider into the active slot**.
- **Which provider admission merely weighed.** The `candidate` block of the
  latest persisted `admission.decided` payload (provider, adapter, support
  tier, compatibility). A candidate records what admission evaluated; it is
  never evidence that anything ran. The card labels it
  "Admission candidate — evaluated, not executed".

Provider-sourced data is separated from durable domain data in the same card:
`provider_session_id` is rendered under "Provider-reported session" and the
card footnote states it is diagnostic evidence and never canonical state,
consistent with the iteration-4 locked decision. It is redacted through
`RunPresentation.redact_text/1` like any other provider-sourced text.

## 3. Worktree Identity (`REPO-INSPECTION`)

Worktree identity is read from the durable worktree record through
`Shoestring.Worktrees.get/1`, the same public call the run page
(`ShoestringWeb.RunShowLive`) already uses, keyed by run id. The executing
run names the live worktree; absent one, the latest run names the most recent.
Path and source repository are redacted before render.

Every failure mode keeps its own honest state rather than collapsing into one
empty message (`data-state` on `#cobbler-worktree-unknown`):

| State | Meaning |
| :--- | :--- |
| `no_run` | No harness run is recorded, so no worktree has been provisioned. |
| `not_registered` | A run exists but no durable worktree record is registered. The run row's workspace reference is still shown; no path, branch, or base commit is claimed. |
| `diverged` | The record and its Git-directory copy disagree; no identity is shown and nothing is guessed from either copy. |
| `unavailable` | The record could not be read; no path or branch is inferred. |

## 4. No Invented Values (`VERIFIED`)

Absent data renders as an explicit, visually distinct "Not recorded" /
"Not reported" in italic zinc-500, never as a blank cell that could read as a
real value. Blank strings are treated as absent, not as empty data
(`recorded_value/1`). Tests assert the unknown twins directly:
`#cobbler-worktree-unknown[data-state='not_registered']` with
`refute has_element?(view, "#cobbler-worktree-path")`,
`#cobbler-latest-run-empty`, `#cobbler-candidate-empty`, and
`#cobbler-provider-session` reading "Not reported".

## 5. Contract Preservation (`REPO-INSPECTION`)

- **No UI writes.** The two cards add no `phx-click`, no form, and no event
  handler. The page's only write path remains the pre-existing
  confirm/respond form and the manual recheck control.
- **No provider calls, no network.** Every value comes from a persisted row
  or the durable worktree record on disk.
- **No inference.** No timer, elapsed-time heuristic, or derived liveness
  enters the cards; run status is read from the row.
- **Authorization unchanged.** The cards render inside the existing
  `@goal_error` guard, behind the unchanged `authorized_goal?/2` check. No
  scope logic was touched.
- **Persisted policy evidence remains authority.** The admission candidate is
  read from the persisted `admission.decided` payload, not recomputed.

## 6. Transitions and Live Refresh (`VERIFIED`)

The cards recompute inside `load_detail/2`, so every existing refresh path
already covers them: the `refresh` button, `{:trajectory_event_committed, _}`
for this goal, and `{:trajectory_projection_updated, goal_id, _}`. Tests
cover queued (`requested`), working (`running`), sleeping (`suspended`), and
terminal (`completed`) states, a `requested → running` transition observed
through the refresh button, and a `running → completed` transition plus a
newly registered worktree observed through a committed trajectory event. An
event for a different goal is asserted to change nothing.

## 7. Test Commands and Counts (`VERIFIED`)

All commands run from the assigned worktree root (`$WORKTREE`) with a
fresh platform-native temporary state directory
(`SHOESTRING_TEST_STATE_DIR=$(mktemp -d -t ...)`). The gate is `mix precommit`; the
+18 ExUnit delta over the 1207-test baseline is exactly the 15 new LiveView
tests plus the 3 new presentation unit tests.

| Command | Result |
| :--- | :--- |
| `mix test` at base `01f2a54` | 1207 tests, 0 failures, 1 skipped (6 excluded) |
| `mix precommit` at base `01f2a54` | exit 0 (node gate: 52 pass, 0 fail) |
| `mix test test/shoestring_web/live/cobbler_goal_execution_test.exs test/shoestring_web/live/cobbler_presentation_test.exs` | 30 tests, 0 failures |
| `mix precommit` with this slice applied | **exit 0** — ExUnit 1225 tests, 0 failures, 1 skipped (6 excluded); node gate 52 pass, 0 fail |

### Fail-on-base ledger (`VERIFIED`)

With the three `lib/` files restored to base `01f2a54` and the new test file
left in place, `mix test test/shoestring_web/live/cobbler_goal_execution_test.exs`
reported **15 tests, 14 failures**. Every failure was
`Expected truthy, got false` from `has_element?` against a DOM id the base
page does not render — the correct behavioural reason, not a compile error,
`NameError`, or changed signature. The three `lib/` files were verified
byte-identical after restore.

The one test that passes at base is
`"the execution cards are not reachable for a goal outside the scope"`, which
asserts the pre-existing `authorized_goal?/2` behaviour. It is an
authorization guard, not a regression lock for this slice, and is reported as
such rather than claimed as coverage.

The three added unit tests in `cobbler_presentation_test.exs` call functions
that do not exist at base and would fail there with `UndefinedFunctionError`.
They are unit coverage for the new mappers, not behavioural regression locks,
and are not claimed as such.

## 8. Design Process (`VERIFIED`)

`scripts/impeccable context --target lib/shoestring_web/live/cobbler_goal_live.html.heex`
was run once from this worktree. It resolved the repository root, found no
`PRODUCT.md` or `DESIGN.md`, and directed scoped work on existing code to
proceed on the incumbent implementation without the new-surface flow. The
narrow-refinement path was followed and `reference/craft-floor.md` was read
before any UI edit. The incumbent Operate design is preserved: same card
shell, heading, icon, badge, and `dl` grid idiom; no redesign and no
unrelated artifact generation. The mechanical detector
(`impeccable detect --json` over the changed template) returned `[]`.

## 9. Limitations (`UNVERIFIED` unless noted)

- **No rendered browser pass.** Desktop and mobile were not verified in a
  real browser. Doing so needs a long-running dev server, which the standing
  agent contract's foreground-only rule forbids backgrounding, plus seeded
  dev-environment runs and worktree records outside this slice's file scope.
  Responsive behaviour was instead checked against **rendered HTML captured
  through the LiveView test harness** (`VERIFIED` for markup, not pixels):
  every `dl` is `grid-cols-1 … sm:grid-cols-2` so it collapses to one column
  below 640px, and all 14 long identifier values (run ids, paths, branches,
  commits, provider ids) carry `break-all`, so nothing overflows at 375px.
  Unlike the run page's worktree card, the path is **not** `truncate`d — the
  full path is the point of this card.
- **`Worktrees.get/1` path fallback noise.** When no record is registered,
  the public API falls back to `Record.load_by_path/3`, which probes a
  cwd-relative path and makes the OS print `spawn: Could not cd to …` to
  stderr. This is pre-existing library behaviour shared with the run page,
  not introduced here, but this slice makes it occur more often in test
  output. No behaviour depends on it.
- **`git` on `PATH`.** `Worktrees.get/1` verifies a record against its
  Git-directory copy with one local `git rev-parse --git-dir`. No provider
  CLI and no network are involved. If `git` were absent the card would
  degrade to the `unavailable` state rather than raise; that degradation path
  is `UNVERIFIED`.
- **Multiple concurrent executing runs.** The card names a single executing
  run (the newest). The MVP task claim is globally exclusive, so more than
  one is not expected, but the card would not enumerate them if it happened.
