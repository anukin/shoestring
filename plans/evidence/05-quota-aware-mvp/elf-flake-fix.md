# Elf flake fix: Codex Session self-reap vs Elf adopt race

## Phase 1 — symptom (VERIFIED)

- `test/shoestring/elves/elf_test.exs:531` ("Codex adapter completes through the Elf
  with a hermetic app-server process") intermittently fails in full-suite runs:
  `assert_receive {:elf_terminal, ^run_id, %{class: :completed}}` gets no match
  after 10_000ms (run lasts ~11.0s).
- Isolated single-test loop: 10/10 pass (~1.1s each).
- Full `mix test` (1051 tests): 3/3 green on this box. Single-test loop overlapping
  a concurrent full suite: 2 failures in ~47 loaded iterations.
- Both captured failures show the SAME mailbox content — the Elf DID report, but
  as failed (so the `completed` pattern never matches):

  ```elixir
  {:elf_terminal, _run_id,
   %{class: :failed, error_code: "group_leader_unverifiable", error_category: "transport"}}
  ```

## Phase 1 — causal chain (VERIFIED by deterministic probe + code)

1. The Elf runs the Codex adapter with `process_owner: :adapter`
   (`elf_test.exs:581-601`), so no `PortRunner` is spawned; the Elf adopts the
   adapter transport's pgid after the handshake (`lib/shoestring/elves/elf.ex:642-657`).
2. `Elf.launch_fresh/1` starts the adapter and blocks in
   `Session.await_run_identity/2` (`lib/shoestring/elves/elf.ex:490-508`,
   `lib/shoestring/harness/codex_app_server.ex:218`).
3. The handshake completes when the `turn/start` RESPONSE arrives; the Session
   replies to the identity waiters immediately
   (`lib/shoestring/harness/codex_app_server/session.ex:584-597`).
4. The hermetic fixture script emits `turn/completed` right after the turn
   response (`elf_test.exs:577-578`). On `turn/completed` the Session calls
   `reap_descendants/1` FIRST — SIGTERM/SIGKILL to the transport pid AND its
   process group (`session.ex:665-684`, `session.ex:767-822`). The transport dies.
5. The Elf, once scheduled, runs `PortRunner.verify_group_leader(pgid)`
   (`elf.ex:646`, `port_runner.ex:343-357`): `ps` on the now-dead pid exits
   nonzero → `{:error, :group_leader_unverifiable}`.
6. `attach_owned_process/2` fails → `launch_fresh/1` else-branch →
   `abort_launch` with `launch_failed("group_leader_unverifiable")`
   (`elf.ex:501-507`, `elf.ex:523-526`, `elf.ex:518`) → terminal `failed`.

Scheduling decides the winner: the Elf's verify (one `ps` fork, µs after the
await reply, but needs a scheduler slot) vs the Session's reap (an already-hot
process handling queued port messages + 3-5 `kill` forks). No load: the Elf
wins. Full-suite load (`max_cases: 40`, 20 schedulers, 40 contending tests):
the Session often wins → ~1-in-3 gate failure.

Deterministic proof (temporary probe test, since removed): drive a live
`Session` with the same fixture shape to `:completed`, then
`PortRunner.verify_group_leader(dead_pid)` returns exactly
`{:error, :group_leader_unverifiable}`, while the control
(`verify_group_leader` on a live `PortRunner.spawn(["sleep", "30"])` group)
returns `:ok`. So the failure is death-before-verify, not a flaky `ps`.

## Twin check (REPO-INSPECTION)

`Shoestring.Harness.ClaudeHeadless.Session.maybe_terminal/2`
(`lib/shoestring/harness/claude_headless/session.ex:517-525`) only flips status
and replies waiters on a terminal result — it never kills the transport group.
Post-verdict teardown is the Elf's job there
(`terminate_owned_group/1`, `elf.ex:1102-1114`). The Codex Session's
`turn/completed` self-reap is the anomaly, and it contradicts the locked
decision "the Elf owns the process group and reaps it."

## Phase 2 — fix

- `Session` gains an `:elf_owned_process_group` opt (default `false`):
  when true, the automatic `turn/completed` reap is skipped. Buffered events
  (including the result verdict) are unaffected — evidence precedes teardown as
  before. Explicit paths (cancel, oversized-frame, transport-closed/DOWN,
  shutdown) are unchanged: cancel is coordinated with the Elf (which
  `killpg`-reaps the same group right after), and failure paths already funnel
  through the Elf's abort-then-terminate sequence.
- `Elf.start_adapter/1` sets the flag (caller override respected via
  `Map.put_new/3`) whenever its own `process_owner == :adapter`. All adapters
  (`Fake`, `ClaudeHeadless`, `CodexAppServer`, `LiveBufferedAdapter`) read opts
  with `Map.get` / forward them opaquely, so the extra key is inert elsewhere.
- Net effect on the timed path: removes the kill, nothing added — completion
  is FASTER (fewer forks) and DETERMINISTIC (no adopt-vs-reap race). No
  timeout, sleep, poll-loop, retry, or skipped test changed
  (`elf_test.exs:603` still `assert_receive ... 10_000`).

## Regression lock

- New test in `test/shoestring/harness/codex_app_server/session_test.exs`:
  "elf-owned process group is not reaped on turn/completed": scripted
  transport reporting a REAL `sleep` pid as its `os_pid`, handshake driven
  synchronously, `turn/completed` pushed, `Session.status/1` call as the
  (sleep-free) barrier, then asserts status `:completed`, a buffered `:result`
  verdict (required thing present), and the group STILL ALIVE (sensitive
  operation absent). Fail-on-base: without the fix the flag is ignored and the
  reap kills the stand-in → alive assertion fails for the right behavioural
  reason. Verified against base `5c04ceb` (see gate figures below).

## Gate figures

All commands run as `mix precommit` (exit code quoted) in the worktree.

- `mix precommit` run 1 (fixed): exit 0 — `1052 tests, 0 failures, 1 skipped
  (6 excluded)` in 63.2s; node gate `pass 52 / fail 0`.
- `mix precommit` run 2 (fixed): exit 2 — `1052 tests, 1 failure, 1 skipped
  (6 excluded)`; node gate `pass 52 / fail 0`. The single failure is
  `Shoestring.Trajectory.ArtifactStoreTest` "put writes content-addressed
  bytes" with `Exqlite.Error: Database busy` on `INSERT INTO "goals"` —
  a SQLite single-writer contention victim in a path this diff does not touch
  (REPO-INSPECTION: diff is Elf start-opts + Codex Session turn/completed reap
  + session test; no Repo/pool/ArtifactStore code). Reported as intermittent,
  1 of 3 gate runs. The Codex Elf test passed in this run.
- `mix precommit` run 3 (fixed): exit 0 — `1052 tests, 0 failures, 1 skipped
  (6 excluded)` in 63.2s; node gate `pass 52 / fail 0`.

Supporting runs (all VERIFIED this run):

- `test/shoestring/elves/elf_test.exs` in isolation, 3x: `24 tests,
  0 failures` each (~14s).
- Loaded recipe (single Codex test looped while a concurrent full suite runs
  — the recipe that reproduced the flake pre-fix): pre-fix 2 failures in ~47
  loaded iterations (`group_leader_unverifiable` both times); post-fix 40/40
  pass, concurrent suite `1052 tests, 0 failures`.
- New regression test fail-on-base: with `session.ex` + `elf.ex` stashed to
  base `5c04ceb`, the new test fails at
  `assert PortRunner.alive_id?(runner.pgid)` (reap kills the stand-in group —
  the right behavioural reason, not a signature error); with the fix it passes.
- Pre-fix baselines on this box: single test 10/10 isolated (~1.1s);
  full `mix test` 3/3 green (1051 tests) before the loaded recipe reproduced it.
