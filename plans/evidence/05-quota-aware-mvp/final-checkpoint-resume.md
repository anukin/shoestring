# Final checkpoint-resume slice (iteration 5, all VERIFIED)

Reliable checkpoints and same-provider continuation, on top of base
`6fd0ecdb` (branch `polly/iter5-checkpoint-resume-muse`). Incorporates the
user's WIP (`ensure_composed_prompt` for every adapter-start path plus the
`NoResumeFake` regression) and finishes the contract: evidence-backed
reactive checkpoints, durable persistence-failure handling, and no
timer-triggered interruption of incomplete work.

Source scope: `lib/shoestring/elves/elf.ex`,
`lib/shoestring/elves/terminal_checkpoint.ex`. No checkpoint-builder
helper changes were required (`CheckpointFallback` / `Checkpoints`
untouched). Tests: `test/shoestring/elves/elf_resume_start_test.exs`
(WIP, preserved) plus new
`test/shoestring/elves/elf_checkpoint_resume_test.exs`.

## 1 — Every continuation start carries the bounded projection (`elf.ex`)

`start_adapter/1` builds one composed request via `ensure_composed_prompt/1`
and uses it on all three paths: native `resume/3`, fresh fallback after a
failed resume, and fresh start on adapters without `resume/3` (e.g.
Claude). The composer reads only the continuation triple plus the
checkpoint record's content fields through
`Continuation.compose_handoff_prompt/2` (bounded, transcript-free);
requests without a continuation keep the original prompt verbatim, so
initial non-continuation starts are unchanged. Lock: the `NoResumeFake`
test (adapter without `resume/3`, request with continuation) starts with
the composed prompt containing the continuation marker, never the bare
original — on base it starts with `Do the deterministic thing.` verbatim
(VERIFIED against isolated base checkout: 4 tests, 1 failure, assertion
`started.prompt =~ "FRESH-NEXT-42"` with left `"Do the deterministic
thing."`).

## 2 — Reactive checkpoints reuse the evidence collector (`terminal_checkpoint.ex`, `elf.ex`)

`write_reactive_checkpoint/2` no longer hardcodes a generic criterion and
`"unknown"` revision. It delegates to the new
`TerminalCheckpoint.record_reactive/3`, which shares the deterministic
collectors with the terminal path: worktree identity (base commit,
branch), current revision, dirty flag, bounded diff stat + changed-file
list (overflow hard-fails to the floor, never truncated), verification
trajectory, last safe boundary, lease snapshot, provider session, and
goal/task acceptance contract loaded from the durable rows (unavailable
facts stated explicitly as `unavailable`/`unknown`, never inferred). The
reactive extension kind is `"reactive"` with the lease decline reason;
the next action is the deterministic decline-resume instruction naming
the checkpoint id, revision, and the `mix precommit` re-verification.
Collection or write failure falls back to the reactive floor template
(revision `"unknown"`, precise decline-key pointer, same acceptance
contract) with one retry, mirroring the terminal path. Locks: boundary
decline and quota-twin tests assert kind `reactive`, stop
`lease_exhausted`, criteria naming the goal/task, and next action with
`mix precommit` — on base both fail with zero `reactive` checkpoints
(the base writer emits no kind), and the terminal twin fails on the
generic criterion (VERIFIED: 4 tests, 4 failures on base).

## 3 — Persistence failure is durable and recoverable (`elf.ex`)

`write_reactive_checkpoint/2` now returns `{:ok, state} | {:error, state,
reason}` (stable `lease_checkpoint_id` retained for retry, new
`lease_checkpoint_error` field). `decline_lease/2` suspends, schedules the
sleep wake, settles, and stops ONLY on `{:ok, _}`; on `{:error, _, _}` it
logs with run/dispatch identity and leaves the run active so the next
safe boundary retries — the already-appended `lease.checkpoint_required`
transition is the durable marker that contents are still owed. No wake
continuation can therefore run without a persisted structural checkpoint
(the wake layer additionally refuses to dispatch without one). The
already-terminal `lease_not_renewable` boundary twin only settles on a
successful checkpoint. Safe boundaries and the owned process group are
untouched: nothing is interrupted mid-item, no kill is issued here.
Lock: the persistence-failure test (failing writer seam for both
attempts) terminates normally with zero `checkpoint.created`, zero
`run.pausing`/`run.suspended`, and no wakeup row — on base the same test
writes a checkpoint and suspends (VERIFIED: fails on base).

## 4 — No timer-triggered interruption; process-group ownership preserved

No timers, lease-expiry interrupts, heartbeats, or backfills were added.
The decline still asks a live session to stop at its next safe boundary
only after the checkpoint persists; the quiet-exit and explicit-cancel
group termination paths are unchanged. Bounded output handling is
unchanged (oversize fails, never truncated).

## Gate and suite results (VERIFIED)

- `mix precommit` → exit 0; `1198 tests, 0 failures, 1 skipped (6
  excluded)`; eval matrix `52 pass, 0 fail`.
- Adapter contract suites
  (`test/shoestring/harness/codex_app_server_contract_test.exs`,
  `test/shoestring/harness/claude_headless_contract_test.exs`) → `14
  tests, 0 failures, 1 skipped`.
- New suites on this tree:
  `test/shoestring/elves/elf_checkpoint_resume_test.exs` +
  `test/shoestring/elves/elf_resume_start_test.exs` → `8 tests, 0
  failures`.
- Baseline (isolated checkout at base `6fd0ecdb`, new tests copied in):
  resume-start suite `4 tests, 1 failure` (behavioral, quoted above);
  checkpoint-resume suite `4 tests, 4 failures` (all behavioral, quoted
  above). No `NameError`/missing-module failures.

## Risks and non-claims (UNVERIFIED where stated)

- Fixture worktree coverage: the reactive tests run with
  `workspace/elf` (no fixture worktree), so they exercise the reactive
  floor template (real acceptance contract + boundary + lease context,
  revision `"unknown"` stated honestly) rather than the full git-evidence
  path; the full git path is covered by the terminal collector tests
  (REPO-INSPECTION of test setup).
- Cross-provider handoff prompt composition is unchanged and was not
  re-verified here beyond the existing suites.
- No live provider runs were made (no authorization, no budget); all
  runs use `Shoestring.Harness.Fake` and local commands.
- Full milestone completion is NOT claimed; this slice covers only the
  four contract items above.
