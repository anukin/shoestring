# Loop-closure I1: execution entrypoints through admission + claim

**Slice:** I1 (entry closure) · **Base:** `85437ed` · **Status:** implemented, gated

Pinned decisions P1–P4 from the task brief are implemented as specified, with
two explicit readings recorded under Deviations. Factual claims below use the
repository convention (`VERIFIED` = proven by committed code or a command
output from this run; `REPO-INSPECTION` = direct file inspection;
`UNVERIFIED` = not verified here).

Fixture identifiers in this note are format-valid synthetic UUIDv7 values
(`01950000-0000-7000-8000-…`), never real rows. No credentials, machine paths,
or model reasoning are recorded.

---

## 1. What changed and why (P1–P3)

**P1 — dispatcher starts work only through the durable dispatch pipeline
(`VERIFIED` by `test/shoestring/cobbler/entry_closure_test.exs` + committed
`lib/shoestring/cobbler/dispatcher.ex`).**
`Dispatcher.claim_and_gate/3` with `grant_lease:` previously stopped at
`{:error, {:execution_disabled, _}}` with zero rows/jobs. It now persists the
run row and the lease grant first (unchanged `Leases.issue_for_claim/6`),
then enqueues durable delivery through the new
`Dispatches.enqueue_for_run/2` (dispatch record + Oban job +
`dispatch.requested`), never a direct `Elves.start_run`. Replays
(`lease_outcome: :replayed`, `run: nil`) create zero new rows and carry
`dispatch: nil, job: nil`. Without `grant_lease:` the execution-disabled
boundary is byte-for-byte preserved.

**P2 — `RunNewLive` is a Cobbler command submitter (`VERIFIED` by
`test/shoestring_web/live/run_new_entry_test.exs`).** The normal submit path now flows
`submit_command` (`task.claim` with an operator-confirmed
`admission.decided` reference) → exclusive claim → gated
`Dispatches.enqueue` (`require_cobbler_command: true`) → `Elves.start_elf`
for the already-persisted intent. `Elves.start_run` is no longer called on
the normal path. Without a live owned claim the UI renders the
`#claim-held-panel` (reason + Cobbler dashboard link) and starts zero
runs/jobs instead of bypassing. Direct start survives ONLY behind the
explicitly-marked expert/test hatch (`run[expert_bypass]` +
`run[confirmed_by]`), which appends a `require_confirmation`
`admission.decided` audit event (`operator_confirmed_expert_bypass`) and
marks the run intent (`shoestring.manual:expert_bypass`,
`shoestring.manual:confirmed_by`) before the direct start — never silent.
Hatch without attribution is refused fail-closed before any side effect.

**P3 — one-Elf invariant (`REPO-INSPECTION` + documentation tests).** The
second concurrent dispatch for the same or another goal/scope is refused by
the SQLite-enforced exclusive claim and surfaced as
`awaiting_operator` / `#claim-held-panel` / `no_claimed_command`. No second
enforcement mechanism was added, per the decision.

**P4 — no new trajectory event types (`VERIFIED`).** Only reused types are
emitted: `admission.decided`, `cobbler.*`, `lease.*`, `dispatch.requested`,
`run.*`. Confirmed by `rg` over `lib/` for `Trajectory.append` call sites
touched in this slice.

---

## 2. Production entrypoint inventory (`VERIFIED` by `rg` over `lib/`, `tools/`, `priv/`)

### `Elves.start_run/3` production callers

| Caller | Line | Classification |
| --- | --- | --- |
| `lib/shoestring_web/live/run_new_live.ex` (hatch branch) | ~381 | **Hatch (allowed).** Reachable only with `expert_bypass` + non-blank `confirmed_by`; bypass audit event appended first; run intent marked. |
| `lib/shoestring/elves.ex` (definition) | 64 | Definition; internal `Dispatches.enqueue` ungated by default, gated iff the caller passes `require_cobbler_command: true`. |

No other production caller exists. Test-only callers (`test/shoestring/elves/*`,
`test/shoestring_web/live/*`) are out of scope and hermetic (Fake + sandbox).

### `Dispatches.enqueue/3` production callers

| Caller | Line | Classification |
| --- | --- | --- |
| `lib/shoestring/elves.ex` (`start_run`) | 75 | **Guarded-iff-flagged.** The only production `start_run` caller is the P2 hatch (logged); all other callers are tests. |
| `lib/shoestring_web/live/run_new_live.ex` (gated path) | ~310 | **Guarded.** Always passes `require_cobbler_command: true`; refusal renders a visible error and starts nothing. |

### Adjacent (twin) paths — inspected, not changed

| Path | Observation |
| --- | --- |
| `Elves.start_elf/3` from `Elves.DispatchEffect` (`lib/shoestring/elves/dispatch_effect.ex:66`) | Oban effect path; runs only after `prepare_for_effect/2` claims the dispatch. Guarded by the pipeline (`REPO-INSPECTION`). |
| `Elves.start_elf/3` from `RunNewLive` gated path | Runs only for already-claimed + dispatched intent. Guarded (`VERIFIED`). |
| `Runs.request/3` from `Leases.issue_for_claim/6` | Post-claim grant path; delivery now via `enqueue_for_run/2`. Guarded (`VERIFIED`). |
| `Elves.resume_run/4` handoff branch (`lib/shoestring/elves.ex:492`) | I5-owned resume/handoff; opt-in gate already plumbed, never defaulted. Out of scope; twin noted, not changed. |
| Library defaults (`start_run`, `enqueue` ungated unless flagged) | **Reported, not closed.** No production caller uses them ungated after this slice, but programmatic callers still can. Flipping defaults would break ~30 hermetic Elf tests owned by other slices and touches `elves.ex` (read-only for I1). Left as an explicit residual risk. |

No BLOCKER bypasses remain: every production execution entry is admitted +
claimed (or is the logged P2 hatch).

---

## 3. Lock-vs-documentation ledger (fail-on-base `VERIFIED` by stash + rerun)

Base commit for all fail-on-base checks: `85437ed` (implementation stashed,
new test files kept; implementation restored after).

| Test | Type | Base behavior observed |
| --- | --- | --- |
| `entry_closure_test`: admitted flow creates claim→grant→dispatch+job in order, sequence + idempotency keys | **Lock** | Fails: `Repo.aggregate(Job) == 1` sees `0`; base stops at `execution_disabled` with zero jobs. |
| `entry_closure_test`: replay creates zero new rows/events/jobs | **Lock** | Fails: same job-count assertion sees `0` on first pass; replay shape never reached. |
| `entry_closure_test`: unadmitted gated `start_run` refused, exact reason, zero rows/jobs | Documentation | Passes on base (refusal plumbing predates slice); pins reason `:no_active_claim` + zero side effects. |
| `entry_closure_test`: claim-held second dispatch refused visibly | Documentation | Passes on base (exclusive claim + `awaiting_operator` predate slice); P3 adds no new mechanism by design. |
| `run_new_entry_test`: guarded submit records admission+claim+dispatch, navigates | **Lock** | Fails: no `admission.decided` row (direct `start_run` bypass). |
| `run_new_entry_test`: held claim shows panel, zero runs | **Lock** | Fails: no `#claim-held-panel` (base redirects and starts the run). |
| `run_new_entry_test`: hatch + attribution starts + logs bypass | **Lock** | Fails: no `operator_confirmed_expert_bypass` event (base ignores hatch params). |
| `run_new_entry_test`: hatch w/o attribution refused, zero side effects | **Lock** | Fails: no attribution flash (base starts the run). |

Pre-existing suites updated for the intended behavior change: `lease_grant_test`
(first test now expects exactly one Oban job + dispatch record instead of zero
jobs), `run_live_test` (`/runs/new` banner asserts `Cobbler Claim-Gated`).

---

## 4. Deviations from P1–P4 and ownership

1. **Manual runs do not take Cobbler lease grants (explicit reading of P2).**
   P2's text requires submit → admission → claim → gated dispatch, with no
   mention of leases; manual runs carry explicit operator-confirmed local
   bounds (`timeout/max-events/lease_seconds` in `shoestring.manual:*`
   extensions) instead of quota leases, and there is no capacity snapshot to
   grant against for manual (especially Fake) runs — fabricating one would be
   dishonest evidence. WP C's "persist grant before allowing execution" is met
   by the P1 dispatcher path (`claim_and_gate` + `grant_lease:`). Extending
   grants to manual provider runs is future work.
2. **Two-step grant→dispatch (no `leases.ex` edit).** `leases.ex` is read-only
   for I1, so the dispatcher enqueues delivery via the new owned glue
   (`Dispatches.enqueue_for_run/2`) after `issue_for_claim/6` returns, rather
   than switching `issue_run` to `enqueue/3` internally. Crash between the
   steps leaves a run-only row, which the existing `Dispatches.reconcile/1`
   already repairs (`UNVERIFIED` for the crash window itself; no new
   mechanism added).
3. **No files touched outside I1 ownership.** In particular `elves.ex`,
   `leases.ex`, `dispatch_effect.ex`, `run_show_live.html.heex` (whose
   "Not Cobbler Routing" banner is now stale for claim-gated manual runs —
   left for its owner), and wakeup/worker/config are untouched.
   `update of test/support` was not needed.
4. P1–P4 otherwise followed exactly: no direct `Elves.start_run` on any
   admitted path, no second claim mechanism, no new event types.

## 5. Remaining risks / honest unknowns

- Library-level `Elves.start_run/3` / `Dispatches.enqueue/3` remain usable
  ungated by programmatic callers (see inventory); closure is at the
  entrypoints, not the library boundary.
- The grant→dispatch two-step has a crash window repaired only by the
  existing reconciler; an injected crash test for that window was not added
  (`UNVERIFIED`).
- Same-provider resume / cross-provider handoff gating (`require_cobbler_command`
  opt-in on `resume_run`) belongs to I5; not verified here (`UNVERIFIED`).
- No live provider runs were performed (not authorized, none needed):
  hermetic Fake + sandbox only.
