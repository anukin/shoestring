# Iteration-5 final closeout after #85: terminal-only lease stop, live

Branch `polly/iter5-final-closeout-post85`, base `a01da97` (#85 merged; same
tree as the approved `baec113`). Claim labels follow this directory's
`README.md`; an explanation that was not isolated is marked **INFERENCE**.

> **§1–§2 are the pre-registration.** They were committed before the first
> provider call of this sequence, and every live phase record carries the
> commit it ran at (`code.sha`, `code.tree`, `dirty`). They are left word for
> word as committed. Everything after §2 was written after the run.

## 1. Authorization, budget and scope

- **Authorized:** at most **three Codex provider runs** — `turn1`, `turn2`,
  `lease_stop` — one attempt each, through the existing subscription. No
  Claude receiver, no handoff, no ablation arm, no `cancel` phase, no retries,
  no separately billed API.
- **Non-provider phases:** `setup` (fixture + baseline), `release` (a durable
  `task.release` for turn 2's goal, because no handoff follows it here and
  `/runs/new` holds one global claim), `audit` (invariants; its handoff replay
  has no handoff record to replay and records `null`). `selftest` runs only
  against a throwaway state directory, never the live one.
- **Fresh state:** a new state directory under the per-user temp root, never
  the user's application-support directory, migrated with
  `mix run --no-start -e 'Shoestring.Release.migrate()'` (`final-acceptance.md`
  §8.1), never `mix ecto.migrate`. Normal monitors and Oban queues; no direct
  DB writes, no forced state changes, no injected observation.
- **Evidence from `f873372`** (the 2026-09-27 closeout at pre-#85 `1566acd`)
  is integrated by cherry-pick (`78a17f7`), unchanged except the README
  conflict (both entries kept). Its negative findings are history and stay.

## 2. Design, fixed before execution

### 2.1 What #85 changed (REPO-INSPECTION of `a01da97`)

- A lease safe stop (and a safe-boundary cancel) **only pends** at the
  session; the provider's own turn outcome resolves it with no send
  (`codex_app_server/session.ex` `pend_safe_stop/1`, `turn/completed`
  clause). Explicit immediate cancellation is unchanged.
- Mid-turn spends past the deadline run the admit-only `renew_only/3`: a
  refusal appends nothing. The full `maybe_renew/3` runs once at the turn
  outcome when there is undecided business (`elf.ex` `renew_path/3`).
- At the outcome a refusal settles by outcome kind: a **completed** turn keeps
  its terminal with the ordinary terminal checkpoint — no suspend, no wake, no
  continuation. Only an **interrupted** turn declines (`run_renewal/2`).
- `/runs/new`'s `timeout_seconds` is informational (`manual_timeout_seconds`
  in the admission's proposed bounds; the grant reads only contract keys). No
  product code stops a manual run on elapsed time. The lease watcher and the
  deadline path only request the (pending) safe stop.

So the 2026-09-27 shape — an interrupt 2.5 s after a command START with no
completion — is fixed hermetically by #85 (`lease-safe-boundary.md`). Whether
it holds live is what `lease_stop` measures.

### 2.2 Lease-stop acceptance (post-#85), pre-registered

Same prompt and bounds as before (60 s manual lease, 4000 events). Computed by
`FinalEval.lease_stop_facts/3` and `FinalEval.lease_stop_verdict/1` from
committed trajectory events and rows, after the 150 s wake observation. Each
is reported separately; the phase passes only if all hold.

| Id | Criterion | How it is read |
|---|---|---|
| L1 | The deadline marks renewal due while tools run | a `lease.renewal_due` precedes the turn outcome, and at least one tool item event (start or completion) is recorded after it and before the outcome |
| L2 | No Elf-induced interrupt and no driver cancel | the outcome's `result.status` is not `interrupted`, no `run.interrupted`, and the driver issued no cancel on this run |
| L3 | Every started tool item completed | ≥1 tool item started, and every started item's last status is `completed`, `failed` or `declined` |
| L4 | Exactly one renewal evaluation, at the outcome | exactly one `admission.decided` keyed `lease-renewal-decision:*` in the goal, sequenced after the outcome event |
| L5 | `run.completed` with a terminal checkpoint | exactly one terminal, `run.completed`, with a `checkpoint.created` for the run before it |
| L6 | No suspension or wake for finished work | 0 `run.pausing`, 0 `run.suspended`, 0 wakeup rows, 0 `wakeup` jobs, 0 wake decisions |
| L7 | No duplicate dispatch | 1 run in the goal, 1 dispatch row, 1 `run.starting`, 1 terminal |
| L8 | Lease row no longer live | status not in `proposed`, `granted`, `active`, `renewal_due`; the actual status and the `lease.*` event sequence are recorded, not assumed |

If the turn ends before the 60 s deadline, L1 is **not exercised**, and the
run is not repeated.

### 2.3 Superseded requirement (why no decline wake is required)

`final-acceptance.md` §8.4 asked for a manual-scope decline wake settled live.
After #85, a completed turn never declines, so that wake is unreachable
through a deadline stop. Only an interrupted outcome or a quota halt reaches
it. Neither is manufactured here: no forced interrupt, no synthetic quota. The
hermetic proofs stay the evidence for that path:
`test/shoestring/cobbler/wakeup_manual_scope_test.exs` (manual-scope recheck
settles once, `manual_scope_not_resumable`) and
`test/shoestring/harness/live_missing_session_stream_test.exs` (a declined
run's missing session is not a completion). Both files ran at this tree before
the live phases: 7 tests, 0 failures (`--seed 0`). The superseding criterion
is appended to `final-acceptance.md` as §10; its §2 and §8 are not edited.

### 2.4 Other pre-registered checks

- **P1 code identity:** every live phase record carries the same `code.sha`
  and `code.tree` as the commit that adds this file, with `dirty: false`.
- **P2 source checkout:** a read-only snapshot before the first boot and after
  the last are identical (HEAD, porcelain, index SHA-256 and mtime,
  `git diff HEAD` SHA-256 against a private index copy, stash count).
- **P3 process lifecycle:** after each Codex phase the Elf is deregistered and
  its recorded owned group is dead (`process_after`); after `audit`, no
  `beam.smp`, `codex app-server --stdio` or `claude --print` started by this
  sequence is running.
- **P4 capacity before spend:** each Codex phase submits only if the ledger
  holds a Codex reading whose `five_hour` and `weekly` windows are observed
  and below 80 % and 90 % used (the product's default reserves). Otherwise the
  phase records `:capacity_block` and submits nothing.
- **A1 audit invariants:** at most one `run.starting` and one terminal per
  run, a checkpoint before every stop, one dispatch row per started run.
- **Budget:** at most 3 Codex runs in the state DB at the end.

### 2.5 Execution safety and stop rules

- The node runs in the foreground of a `tmux` pane, one phase per boot, with
  no `timeout` wrapper and no `&`. The operator's observer commands (polling
  the phase log and a read-only DB) are each bounded; their bounds cannot
  reach the node.
- Every wait on a run is a **45-minute observation window** (was 900 s). On
  expiry with the Elf alive, the driver records `<phase>:observation_expired`
  and keeps the node up until the Elf exits by itself (`wait_decision/4`).
  Before a phase ends, it also holds for any other live Elf
  (`hold_for_live_elves/1`). Nothing is cancelled because a window ended.
- Stop rules: a capacity block, a turn that does not end `run.completed` with
  a clean committed head, or any observation expiry stops the sequence; no
  further provider run is started, and the block is reported. A phase that
  fails **before** `submit_turn` returns a run id has spent nothing and may
  be re-run once after its cause is fixed and recorded. A phase that has
  submitted is never re-run.
- A continuation the product dispatches after `lease_stop` is handled by the
  pre-existing §2.6 rule of `final-acceptance.md` (recorded, then cancelled
  once running). It fails L6/L7 and counts against the budget.

### 2.6 Driver changes, and how they were checked

`tools/live_eval/final_acceptance.exs`: tree SHA in the code identity; the
observation-window wait above; `hold_for_live_elves/1`; `ledger/0` and
`capacity_clear?/2`; `process_after/2`; `lease_stop_facts/3` and
`lease_stop_verdict/1`. The `selftest` phase (no provider, throwaway state
DB) checks each pure function: 34 of 34 checks pass (13 existing, 21 new),
including the 1566acd interrupted shape failing L2, L3, L4, L5 and L8. These
functions are new, so a pre-fix run would fail on a missing function, not
behaviourally: the selftest is DOCUMENTATION, not a regression lock. That the
old wait returned `{:timeout, run}` with a live Elf, ending the node, is
REPO-INSPECTION of `a01da97` (`do_wait/2`).
