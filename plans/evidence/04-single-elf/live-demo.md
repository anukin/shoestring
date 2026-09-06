# Iteration-4 live demo: single Elf end to end (Codex, live)

Date: 2026-09-05/06 UTC. Worktree `polly/iter4-live-demo` @ `fd24c32`.
Authorizing brief: at most **2 tiny runs**, Codex provider only. **Both runs
are spent**; no further provider inference was consumed after run 2.

Bottom line up front: this demo is a **documented partial failure**, which the
brief names as a legitimate milestone outcome. The milestone's first
acceptance criterion — **the source checkout is unchanged** — is VERIFIED
byte-for-byte. The Elf lifecycle itself exhibits two genuine live defects
below; neither is written up as a success.

Claim labels: `VERIFIED` = committed artifact or command output from this run;
`REPO-INSPECTION` = code read without live execution;
`UNVERIFIED` = stated as unknown.

## 1. GO/NO-GO check — VERIFIED GO

- `codex --version` → `codex-cli 0.153.4` (VERIFIED, shell output).
- `codex login status` → `Logged in using ChatGPT` (VERIFIED).
- `codex doctor` → auth configured (chatgpt tokens in file store), websocket
  `connected (HTTP 101)` to the model provider, zero model cost (VERIFIED).
- Trivial no-cost auth probe: raw stdio handshake `initialize → initialized →
  account/read → account/rateLimits/read` over `codex app-server --stdio`,
  **no thread, no turn, zero quota** (script kept out of the repo at
  `/tmp/elf-demo-probe.py`; raw output kept out of the repo).
  First attempt applied a stricter rule than the repo and reported
  `unauthenticated` because `requiresOpenaiAuth: true`; corrected to the
  repo's own rule (`docs/codex-capacity-monitor.md` Phase 3.5:
  only a *missing account or unauthenticated marker* counts), the handshake
  succeeds (VERIFIED, `fixtures/demo/capacity-before.json`).
  Capacity before: primary 5h window **54%**, secondary weekly window **91%**,
  `spendControlReached: false` (VERIFIED).

## 2. Method (all runs through the module API)

- Disposable fixture repo via `mktemp -d` + `git init` + one commit
  (base `7012722f…`; redacted placeholder `/tmp/iter4-live-demo-repo`).
- Isolated state dir via `mktemp -d`, `SHOESTRING_STATE_DIR` /
  `SHOESTRING_TEST_STATE_DIR`; nothing under test touches the developer's
  real state dir (VERIFIED).
- Elf worktree per run via `Shoestring.Worktrees.create(fixture, run_id)`
  (branch `shoestring/run-<run_id>`, base = fixture HEAD) — i.e. the
  post-PR-#37 path where Elf children run in their worktree, not the host
  checkout (VERIFIED, `capture-run*.jsonl` `worktree_created` steps).
- `Elves.start_run(request, CodexAppServer.identity(), adapter:
  CodexAppServer, adapter_opts: %{live: true}, command: …, notify: self())`
  with `run_id == dispatch_id` (single UUID) so adapter session lookup and
  Elf streaming agree (VERIFIED in code; REPO-INSPECTION for the equality
  requirement — `session.ex:457` uses `workspace_ref` as thread cwd,
  `codex_app_server.ex:220` stores the session under `request.dispatch_id`).
- The adapter sends `workspace_ref` verbatim as the thread `cwd`
  (REPO-INSPECTION, `session.ex:457`); the driver ran with the BEAM cwd at
  the worktrees root so the relative ref resolves to the Elf worktree.
  The run-2 rollout's `session_meta.cwd` equals the Elf worktree path
  (VERIFIED structurally — rollout files themselves are NOT committed).
  Whether a relative thread cwd is robust in production is UNVERIFIED and
  flagged as a question, not a claim.
- Prompt (credential-free by construction) instructed: create `hello.txt`
  with bytes `ok`, run `printf ok` in the worktree, reply one line.

## 3. Run 1 — FALSE `run.completed` in ~60–260 ms (VERIFIED failure)

- Elf reported `%{class: :completed}` with **zero** `harness.event_recorded`
  events (VERIFIED, `capture-run1.jsonl`; trajectory was additionally lost,
  see §5).
- A real provider thread **did** start: rollout
  `…21-37-55…jsonl` shows `task_started`, two assistant message items, one
  `item_completed` (UserMessage), then `turn_aborted` (VERIFIED structurally,
  `fixtures/demo/rollout-run1-summary.json`).
- No `hello.txt` was created; `printf ok` never ran (VERIFIED — worktree
  contained only `README.md` + `.git` afterwards).
- Mechanism (REPO-INSPECTION + VERIFIED log/timing): the owned command was
  the production placeholder `["codex", "app-server", "--stdio"]`, which
  exits 0 almost instantly on EOF stdin; `handle_os_exit` →
  `finish_after_stream` with an empty verdict set → `Classifier.classify(
  :no_verdict, {:exit_status, 0}, false)` → `%{class: :completed}`
  (`classifier.ex:87-89`, documented there as a "conservative placeholder").
  The terminal therefore attests to the **placeholder's** exit, not the
  turn's outcome, while the real turn was still handshaking.
- The turn abort at +70 ms was **my harness's fault**, not the provider's:
  the driver's trajectory dump raised (`Jason` on an unloaded Ecto
  association), the script process died, `mix run` tore the VM down, and the
  transport died with it (VERIFIED timing correlation). Recorded here so the
  abort is not misread as a provider refusal.

## 4. Run 2 — Session crash on a bare-string delta; explicit cancel lands `run.cancelled` (VERIFIED)

Deviations from run 1 (deliberate, documented): owned command
`["sleep", "240"]` (supervision anchor that outlives the turn; precedent:
the `Fake`-adapter default in `elves.ex`), dev env against the migrated
SQLite file (see §5), wait on the **session** turn, then cancel.

- Thread started in the Elf worktree; 5 events buffered live (userMessage
  started/completed, agentMessage started, …) (VERIFIED, crash-state dump
  in `crash-session-run2.log`).
- At ~5 s the provider sent
  `item/agentMessage/delta` with `"delta": "I"` — a **bare string**.
  `EventNormalizer.do_normalize` assumes a map (`delta["text"]`,
  `event_normalizer.ex:344-345`) → `Access.get("I", "text", nil)` →
  `FunctionClauseError` → Session GenServer death → linked Transport death
  → linked Elf death (nothing traps) (VERIFIED, `crash-session-run2.log`).
  `normalize/4` documents `{:ok}|{:skip}|{:error}` returns but nothing
  rescues `do_normalize`, so one unshaped frame violates the contract and
  takes the supervision chain with it (REPO-INSPECTION).
- Consequence: the 5 live-buffered events died in Session memory — the
  durable trajectory holds **zero** `harness.event_recorded` for this run
  (VERIFIED, `trajectory-run2.json`, 7 events, none adapter-originated).
  No backfill exists by design, so they are unrecoverable.
- The agent never acted: no `hello.txt`, empty worktree diff, no command
  executions in the 13-line rollout (`rollout-run2-summary.json`;
  `turn_aborted` when our transport died) (VERIFIED).
- After a 240 s watch, `Elves.cancel_run/2` returned `{:ok, :cancelled}` and
  the trajectory closed `run.cancelling → run.cancelled`
  (VERIFIED, `trajectory-run2.json` seq 6–7). No `sleep`/`codex` processes
  remained: the whole owned process group was reaped
  (VERIFIED, empty `ps` after). Cancellation-at-a-boundary therefore works
  as specified; it is recorded as the run's terminal state, **not** as a
  completion.
- Process/session identity (VERIFIED, `run.running` payload in
  `trajectory-run2.json`): owned pgid `pgid:<synthetic>` (real value in the
  substitution map below), provider thread id `<synthetic v7>` — cross-checked
  against the rollout filename, which embeds the same thread id (VERIFIED).
- `dispatch.effect_failed` (seq 5) is dev-path noise from the Oban
  `UnconfiguredEffect` (REPO-INSPECTION, `dispatch_worker.ex` +
  `unconfigured_effect.ex`); it touches only the dispatch row and does not
  affect the Elf lifecycle.

## 5. Harness/method lessons (all VERIFIED by command output)

- **Test-env SQLite is not durable for demos**: under `MIX_ENV=test` every
  write sits in the `Ecto.Adapters.SQL.Sandbox` transaction and rolls back
  on VM exit — run 1's trajectory tables were empty afterwards. Run 2 used
  `MIX_ENV=dev` against the same DB file (migrated once under test env) and
  its trajectory survived. Driver scripts must also never raise mid-run
  (run 1 lesson) and must flush all capture before VM halt.
- **Dev-env fresh `mix ecto.migrate` fails deterministically** on
  `20260903000650` (`DROP TABLE harness_capacity_windows` logged, then
  `ALTER TABLE …_v2 RENAME TO …` raises "already another table or index
  with this name"). The identical chain migrates cleanly under `MIX_ENV=test`
  (all migrations through `20260905162804`, exit 0). No lib/test file was
  touched for this; it is reported as an environmental finding for the
  owning team, mechanism UNVERIFIED (pool-size/DDL-transaction interaction
  suspected, not asserted).

## 6. Smoke-matrix scorecard

| # | Expectation | Outcome |
|---|---|---|
| 1 | Elf creates a file in the fixture repo | **FAILED** — no `hello.txt` either run (VERIFIED) |
| 2 | Elf runs one deterministic command (`printf ok`) | **FAILED** — never executed; run-2 rollout has zero `commandExecution` items (VERIFIED) |
| 3 | Structured result returned | **FAILED** as run terminal; run 1's `completed` was false (§3); run 2's terminal is `cancelled` after explicit cancel (VERIFIED). Provider-side result events existed only in lost Session memory |
| 4 | Resulting worktree diff inspected | **VERIFIED** — empty diff both runs (`git status --porcelain` clean, only base-commit `README.md`) |
| 5 | Capacity before and after | **VERIFIED** — 54%/91% before, unchanged after run 1 and after run 2 (`capacity-*.json`) |
| ★ | **Source checkout unchanged** | **VERIFIED** — HEAD `fd24c32`, `git status --porcelain` identical (only pre-existing untracked `.pi/`), empty `git diff HEAD` hash `e3b0c44…`, identical index hash, identical stash list (`source-baseline.txt`, `source-after.txt`) |
| + | Normalized event timeline | **PARTIAL** — durable run-lifecycle timeline VERIFIED (`trajectory-run2.json`); adapter event timeline lost with the Session (§4); run-1 timeline additionally lost to Sandbox rollback (§5) |
| + | Terminal classification | **VERIFIED** — run 1 false `completed` (defect), run 2 `cancelled` via explicit cancel |
| + | pgid + provider thread id; worktree path/branch/base | **VERIFIED** — `trajectory-run2.json` + capture files |

## 7. Redaction map (`fixtures/demo/`; README convention)

1:1 substitution, nothing else altered. Real thread ids → synthetic UUIDv7
(`…000001` run 2, `…000002` run 1); real turn ids → `…000003`;
real item uuid → `…000004`; real `msg_…` (64-hex) → `msg_0…01`
(length/charset preserved); pgid `84919` → `64000`, transport pid `84675` →
`64001`, monitor ref → `0.0.0.1`; `/tmp/elf-demo-state-*` →
`/tmp/iter4-live-demo-state`, `/tmp/elf-demo-fixture-*` →
`/tmp/iter4-live-demo-repo` (incl. `/private` variants). Raw probe output
(email, `codexHome`, user agent) is never committed — capacity files are
safe projections only. Rollout summaries carry counts, never model text or
reasoning. Local run/goal/task UUIDs are kept (join keys, not sensitive).
BEAM `#PID<…>`/`#Port<…>` values are kept: they are dead-VM-local and
required to follow the link-crash narrative. Stash-list lines were dropped
from `source-baseline.txt` (public PR branch names add no equality signal).

## 8. Gate and delivery

- `lib/` and `test/` untouched (evidence-only): `git status` in this
  worktree shows only `plans/evidence/04-single-elf/live-demo.md` and
  `plans/evidence/04-single-elf/fixtures/demo/` as new.
- `mix precommit`: exit 0 — **738 tests, 0 failures, 1 skipped
  (6 excluded)** (plus node gate 52/0). Matches the merged-main baseline
  exactly; evidence-only, `lib/` and `test/` untouched.
- Budget: 2/2 authorized Codex runs spent (run 1: turn started then aborted
  by harness teardown; run 2: turn started, Session crashed, turn aborted
  with transport). No further provider inference will be spent from this
  task.
