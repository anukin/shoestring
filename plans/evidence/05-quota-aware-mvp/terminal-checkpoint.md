# I3 — Terminal-Path Recovery Checkpoints with Real Repository Evidence

Milestone 05, work package D loop-closure slice I3. All factual claims below
are labeled per the evidence conventions (`VERIFIED` = proven by committed
code or exact command output in this run; `REPO-INSPECTION` = direct file
inspection; `UNVERIFIED` = not verified here).

## Problem (VERIFIED)

On the base commit (`e26a45d`), the Elf terminal path
(`commit_terminal/2` + `append_terminal_event/2` in
`lib/shoestring/elves/elf.ex`) persists a log artifact + terminal event and
stops without ever invoking the `Checkpoints` writer; the no-model fallback's
only production use is wake-deferral with revision `"unknown"` and generic
criteria (`lib/shoestring/cobbler/wakeups.ex`, `defer_checkpoint/8`).
Verified behaviourally: the six new `ElfTerminalCheckpointTest` tests fail on
the base commit (no `checkpoint.created` is ever appended on the terminal
path), and pass with this slice.

## What changed (VERIFIED)

- New collector module `lib/shoestring/elves/terminal_checkpoint.ex`
  (collection, deterministic floor template, writer reuse — no new
  trajectory event types, no timers).
- `lib/shoestring/elves/elf.ex`, terminal-commit region only: one
  pre-commit hook call in `commit_terminal/2` plus a best-effort attempt in
  `crash_land/2`. The ingest/lease region (`after_ingest/3`,
  `lease_account/2` and helpers) is untouched.
- New tests `test/shoestring/elves/elf_terminal_checkpoint_test.exs`
  (behavioural locks) and `test/shoestring/elves/terminal_checkpoint_test.exs`
  (collector units, documentation-labeled).
- `test/shoestring/elves/elf_lease_loop_test.exs`: count assertions
  partitioned into reactive vs terminal checkpoints (I2 lock intent
  preserved; see below).

### Hook inventory

| Hook | Reads | Writes |
| --- | --- | --- |
| `commit_terminal/2` true-branch (one added line) | — | `maybe_terminal_checkpoint/2` before `append_terminal_event/2` |
| `maybe_terminal_checkpoint/2` | `TerminalCheckpoint.record/2` result | terminal commit unchanged; structured `Logger.error` with run/dispatch identity on checkpoint failure |
| `crash_land/2` (best-effort, inside the existing guard) | same collector | same writer; never raises |
| `TerminalCheckpoint.record/3` | worktree record + local `git`, run trajectory events, Elf lease/session/os-exit fields | `checkpoint.created` via the T3 `Checkpoints` writer (used as-is, actor `"elf"`); one floor retry on failure |
| `TerminalCheckpoint.collect/3` | see collection inventory in the module doc | `CheckpointFallback.build/1` inputs, or `{:error, reason}` → floor |

Untouched by design: `after_ingest/3`, `lease_account/2` and all `lease_*`
helpers (I2 owns the ingest-hook region), `LeaseBoundary`,
`LeaseWatcher`, session/handoff/resume semantics, `terminate/2`'s
supervisor-crash marker (see residual gap), and every other file
(read-only elsewhere).

## Pinned decisions P1–P5 (VERIFIED in code + tests)

- **P1** — On every terminal, a checkpoint is attempted BEFORE the terminal
  commit: worktree identity + base/current commit + branch, dirty diff STAT
  + changed-file list (bounded: 50 files, 32 KiB diff bytes; overflow
  hard-fails to the floor inputs, never truncated silently), exact
  verification evidence from the run's `harness.event_recorded` trajectory
  events plus the OS exit status (absent input is stated explicitly as `"no
  verification recorded"`), last completed safe boundary (latest durable
  `run.*` / `checkpoint.created` / `lease.*` event — the same boundary rule
  as `Staleness` — plus the in-memory reactive lease checkpoint id),
  outcome class + stop reason, lease snapshot, provider session id when
  resumable, and a deterministic per-class next action with a precise
  terminal-event pointer and rerun command.
- **P2** — Checkpoint failure (including fallback build failure) never
  suppresses the terminal commit: the terminal still appends, and both
  outcomes are recorded — the checkpoint id on success, a structured error
  log plus a `"shoestring.elf:checkpoint_error"` extension on the floor
  retry on failure.
- **P3** — The floor template applies when collection finds nothing (e.g.
  failed-before-start): revision `"unknown"`, dirty `false`, a precise
  last-failure pointer (`run.failed` error code + `elf-terminal:<dispatch>`
  key + last durable event anchor), and a rerun command. No certainty is
  invented.
- **P4** — No new trajectory event types (`checkpoint.created` + `run.*`
  only); no timers; no changes to I2's ingest accounting or the stop-only
  `LeaseBoundary`.
- **P5** — Idempotency: the checkpoint id is deterministically derived from
  `run_id` (SHA-256, UUIDv4-shaped), so terminal-path replays converge
  through the writer's `"checkpoint-created:<id>"` key; `commit_terminal/2`
  still guards duplicates.

### Deviations from P1–P5 (stated explicitly)

1. P2's letter ("terminal event references checkpoint_id") is implemented
   as checkpoint→terminal, not terminal→checkpoint: `run.*` payloads reject
   unknown keys (REPO-INSPECTION: `event_registry.ex`, `run.completed` /
   `run.failed` schemas with `optional: []`, plus `validate_unknown_keys/4`
   adds an error), and P4 forbids new event types. The linkage is the
   deterministic `checkpoint_id(run_id)` plus the `elf-terminal:<dispatch>`
   key and outcome carried in the checkpoint extensions.
   (REPO-INSPECTION of the schema; VERIFIED by the passing terminal tests
   asserting both sides of the link.)
2. `terminate/2`'s supervisor-crash marker still appends without a
   checkpoint attempt (shutdown context; recovery re-derives the terminal).
   Residual gap for the reconcile owner — not silently closed.
3. Test seam: `TerminalCheckpoint.record/3` accepts `:writer` in opts, else
   honors the `:terminal_checkpoint_writer` application env (arity-3 fun)
   when present, else the real writer. The seam lives only in the new
   module; `elf.ex` passes no opts. Used by the writer-failure lock test.
   (VERIFIED: writer-failure test asserts terminal commit + error log.)

## Tests (VERIFIED)

Gate: `mix precommit`, exit 0 — Elixir `1131 tests, 0 failures, 1 skipped
(6 excluded)`; JS `52 pass, 0 fail`. (One `warning: variable
"dispatch_jobs_before" is unused` in `test/shoestring/cobbler/wake_reobserve_test.exs:89`
is pre-existing and untouched by this slice.)

New locks (`elf_terminal_checkpoint_test.exs`, 6 tests — each fails on
`e26a45d` for the behavioural reason stated, verified by reverting
`lib/shoestring/elves/elf.ex` + removing the collector and re-running:
6 failures, all "no `checkpoint.created` appended" / empty error log):

- completed run: real diff/stat/changed files, exact command + `exit_status
  0` evidence, `run.running` boundary, `checkpoint.sequence <
  terminal.sequence`.
- failed run: `run.failed:process_exited` stop reason, failure +
  `cmd-work-1` evidence, unresolved issue + rerun pointer, resumable
  provider session id.
- failed-before-start: floor template, revision `"unknown"`, no invented
  certainty.
- writer failure: terminal still commits, zero checkpoints, error logged.
- duplicate terminal path (`cancel_run` replay): single checkpoint, single
  `run.cancelled`.
- interrupted twin: `run.interrupted` + boundary checkpoint.

Documentation (`terminal_checkpoint_test.exs`, 6 tests — new module, so
`NameError` on base by definition): deterministic id shape/uniqueness,
real-evidence collection, file-count and diff-bytes overflow errors, floor
fallback content, replay id convergence across the full→floor writer retry.

Existing suites: `test/shoestring/elves/` + `checkpoints_test.exs` +
`checkpoint_fallback_test.exs` — `135 tests, 0 failures`. The I2 lease-loop
file needed count partitioning (each run now appends exactly one terminal
checkpoint): reactive counts keep their original values, terminal count is
asserted as exactly 1. No I2 lock was widened — the reactive assertions
filter on the absence of the terminal-kind extension.

## Collection inventory (source per field)

See the module doc of `Shoestring.Elves.TerminalCheckpoint`
(REPO-INSPECTION): worktree record (`Worktrees.get/1`) → base/branch/identity;
local read-only `git` (`rev-parse`, `status --porcelain`, `diff HEAD
--stat`, `branch --show-current`) → revision/dirty/stat/files; run
trajectory `harness.event_recorded` → verification; latest
`run.*`/`checkpoint.created`/`lease.*` → boundary; terminal map → outcome;
Elf lease fields → snapshot; `provider_session_id` → session identity.
