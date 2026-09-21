# Final checkpoint-resume slice (iteration 5)

Reliable checkpoints and same-provider continuation, on top of base
`6fd0ecd2e6929fcc7f393ac6e3f7166fc7a6b57d` (branch
`polly/iter5-checkpoint-resume-muse`). Incorporates the user's WIP
(`ensure_composed_prompt` for every adapter-start path plus the
`NoResumeFake` regression) and finishes the contract: evidence-backed
reactive checkpoints, bounded persistence-failure handling, and no
timer-triggered interruption of incomplete work.

Source scope: `lib/shoestring/elves/elf.ex`,
`lib/shoestring/elves/terminal_checkpoint.ex`. No checkpoint-builder
helper changes were required (`CheckpointFallback` / `Checkpoints`
untouched). Tests: `test/shoestring/elves/elf_resume_start_test.exs`
(WIP, preserved), new
`test/shoestring/elves/elf_checkpoint_resume_test.exs`, and new
DOCUMENTATION unit coverage in
`test/shoestring/elves/terminal_checkpoint_test.exs`.

Claim labels follow the standing contract: VERIFIED only for committed
code plus command output from this run; REPO-INSPECTION for tree reads;
UNVERIFIED for limits not exercised.

## 1 — Every continuation start carries the bounded projection (VERIFIED)

`start_adapter/1` builds one composed request and uses it on all three
paths: native `resume/3`, fresh fallback after a failed resume, and
fresh start on adapters without `resume/3` (e.g. Claude). The composer
reads only the continuation triple plus the checkpoint record's content
fields through `Continuation.compose_handoff_prompt/2` (bounded,
transcript-free); requests without a continuation keep the original
prompt verbatim, so initial non-continuation starts are unchanged.

The composed constraints are mode-specific and truthful (VERIFIED by the
prompt assertions below): a native `:resume` continues the prior
provider session, which may retain its own context — the text says so,
and the checkpoint sections stay authoritative (reconcile against them,
prefer them on conflict). A `:fresh` start truthfully keeps the default
"fresh session; no prior transcript available" summary.

Locks (native resume and `NoResumeFake` fail on base with the original
prompt verbatim — VERIFIED against the isolated base checkout, see Gate
section):

- `NoResumeFake` (no `resume/3`, request with continuation) starts with
  the composed prompt: marker + `Continue from checkpoint` + fresh
  constraints, never the bare original.
- Native resume receives marker + `Continue from checkpoint` +
  `authoritative`, and never the `no prior transcript` text.
- Failed-resume fallback receives marker + pointer + fresh constraints.
- No-extension fresh start keeps the original prompt verbatim (passes on
  base too — documentation).

## 2 — Reactive checkpoints reuse the evidence collector (VERIFIED)

`write_reactive_checkpoint/2` delegates to the new
`TerminalCheckpoint.record_reactive/3`, which shares the deterministic
collectors with the terminal path: worktree identity (base commit,
branch), current revision, dirty flag, bounded diff stat + changed-file
list (overflow hard-fails to the floor, never truncated), verification
trajectory, last safe boundary, lease snapshot, provider session, and
the goal/task acceptance contract loaded from the durable rows
(unavailable facts stated explicitly as `unavailable`/`unknown`, never
inferred). The reactive checkpoint id is deterministic per run
(`reactive_checkpoint_id/1`, distinct namespace from the terminal id),
so retries replay instead of duplicating. The extension kind is
`"reactive"` with the lease decline reason; the next action is the
deterministic decline-resume instruction naming the checkpoint id,
revision, and the `mix precommit` re-verification. Collection or write
failure falls back to the reactive floor template with one retry,
mirroring the terminal path.

Acceptance criteria are one bounded entry per row (goal, then task), so
a long goal can never drop the task contract; each entry is redacted
BEFORE truncation (a replacement can expand past the budget) and capped
at the writer's 2,000-character budget (DOCUMENTATION unit tests for
the bound, the redaction, and the id determinism).

Locks (fail on base, which emits no `reactive` kind — VERIFIED, see
Gate section): boundary decline and quota twin assert kind `reactive`,
stop `lease_exhausted`, criteria naming the goal/task titles and
descriptions, and next action with `mix precommit`; the fixture
worktree test asserts the full collector path (revision == base commit,
dirty, diff stat, changed files, command verification lines, boundary);
the terminal twins assert the goal/task contract with descriptions
(the terminal checkpoint exists on base too — the lock there is the
contract content, not its presence).

## 3 — Persistence failure is bounded and recoverable (VERIFIED)

`write_reactive_checkpoint/2` returns `{:ok, state} | {:error, state,
reason}` (stable deterministic id retained for retry, new
`lease_checkpoint_error` field). On failure the decline suspends
nothing, schedules no wake, and settles nothing — the run stays active
so the next safe boundary retries the idempotent checkpoint instead of
sleeping without recovery context — but a safe stop IS still requested
(the in-flight item already completed, so nothing is interrupted
mid-item), capping further provider spend while retries continue. The
already-appended `lease.checkpoint_required` transition is the durable
marker that contents are still owed, and the ordinary terminal path
records its own distinct-id terminal checkpoint when the verdict
arrives, so recovery context survives even when no further boundary
ever fires. The already-terminal `lease_not_renewable` twin only
settles on a successful checkpoint and likewise still requests the stop
on failure. The owned process group is never touched here.

Failure injection is hermetic and version-independent (VERIFIED):
`PoisonCheckpointRepo` returns a corrupt row for the first checkpoint
idempotency lookups, failing the `Checkpoints.record` replay rebuild —
the identical persistence call on every tree — with later lookups
delegating so a retry can recover. No writer seam, no timing hooks.

Locks (fail on base, which swallows the write error and suspends +
wakes with no checkpoint — VERIFIED, see Gate section):

- Quota-path decline with the poisoned write: zero suspend, zero wake,
  zero reactive checkpoint, safe stop asked, retry logged, terminal
  checkpoint still lands with the acceptance contract.
- `lease_not_renewable` boundary twin: stays bounded (terminal arrives,
  no suspend, no wake, stop asked) and recovers exactly one reactive
  checkpoint on retry (base settles quietly and never retries, so the
  count stays zero).

Honest limit (UNVERIFIED by construction): under a total DB outage no
durable record of any kind can land — the error log is the only trace
and the run ends with the stream. The in-memory `lease_checkpoint_error`
likewise does not survive a crash; the durable markers are
`lease.checkpoint_required` plus whatever checkpoint the terminal path
manages to persist.

## 4 — No timer-triggered interruption; process-group ownership preserved (REPO-INSPECTION)

No timers, lease-expiry interrupts, heartbeats, or backfills were added
(verified by diff review: no new processes, no `Process.send_after`, no
timer fields). The decline asks a live session to stop at its next safe
boundary only after the in-flight item completed; the quiet-exit and
explicit-cancel group termination paths are unchanged. Bounded output
handling is unchanged (oversize fails, never truncated).

## Wake-layer correction (REPO-INSPECTION)

The previous revision of this document claimed the wake layer refuses
to dispatch without a checkpoint. That is false:
`ensure_continuation/6` in `lib/shoestring/cobbler/wakeups.ex`
synthesizes a generic fallback checkpoint (default criterion,
`"unknown"` revision) and dispatches when the run has none. The
corrected claim: the Elf-side decline checkpoint ensures the wake finds
the run's evidence-backed checkpoint via the run-scoped projection
first; only when NO checkpoint exists at all does the wake invent a
generic one. The invariant this slice enforces is narrower and exact:
the Elf never suspends or schedules a wake without a persisted
structural checkpoint of its own.

## Gate and suite results (VERIFIED)

- `mix precommit` → exit 0; `1204 tests, 0 failures, 1 skipped (6
  excluded)`; eval matrix `52 pass, 0 fail`.
- Adapter contract suites
  (`test/shoestring/harness/codex_app_server_contract_test.exs`,
  `test/shoestring/harness/claude_headless_contract_test.exs`) → `14
  tests, 0 failures, 1 skipped`.
- New suites on this tree:
  `test/shoestring/elves/elf_checkpoint_resume_test.exs` (5 tests) +
  `test/shoestring/elves/elf_resume_start_test.exs` (4 tests) → `9
  tests, 0 failures`.
- Baseline (isolated checkout at base `6fd0ecd2e6929fcc7f393ac6e3f7166fc7a6b57d`,
  new tests copied in): `9 tests, 7 failures`, every failure behavioral —
  failed-resume fallback and no-extension fresh start pass on base
  (documented preserved behavior: R4.4 and the untouched
  non-continuation path). The 7 failures, quoted:
  - native resume prompt and `NoResumeFake` prompt: `left:
    "Do the deterministic thing."` (original passed verbatim);
  - boundary decline, quota twin, fixture reactive: no `reactive`
    checkpoint persisted (`MatchError` on `[]` / count `0`);
  - quota-path poison: `run.pausing` count `1` (suspended with the write
    failed — the defect);
  - `lease_not_renewable` poison: reactive count `0` (settled quietly,
    never retried);
  - terminal twins: `left: "complete the supervised task per the goal
    acceptance contract"` (the checkpoint exists on base; the lock is
    the contract content).
  No `NameError`/missing-module failures. The DOCUMENTATION unit tests
  in `terminal_checkpoint_test.exs` are excluded from the base claim:
  they cover new functions and cannot fail there behaviourally.

## Risks and non-claims

- No live provider runs were made (no authorization, no budget); all
  runs use `Shoestring.Harness.Fake` and local commands.
- Cross-provider handoff prompt composition is unchanged and was not
  re-verified here beyond the existing suites.
- The wake fallback synthesis (`write_wake_checkpoint` generic
  criterion/revision) lives in admission-owned `cobbler/wakeups.ex` and
  was deliberately left untouched (out of scope); reported, not fixed.
- Full milestone completion is NOT claimed; this slice covers only the
  contract items above.
