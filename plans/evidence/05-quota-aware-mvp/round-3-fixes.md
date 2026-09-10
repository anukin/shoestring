# Round-3 loop fixes (third-review BLOCKERs, all VERIFIED)

A third review blocked iteration 5 with seven findings against `612bf14`.
Each was re-verified against the tree and fixed below. No timeout was
widened, no sleep added, no retry wrapped, no assertion softened to make
anything pass; every behavior change below fails on the pre-fix tree for
the stated reason (lock ledger per section).

## R3.1 — Declining renewal stops further execution (`elf.ex`)

`decline_lease/2` checkpointed, suspended, and scheduled a wake without
stopping the session, so a run labeled sleeping kept working. Now: the
decline requests a safe stop from a live session (`resolve_session` +
`request_safe_stop`, virtual when none is resolvable) and marks
`lease_declined?`; once the buffer drains with no live session, the Elf
reaps its runner group and exits normally with NO terminal (the run
sleeps; it is not over). Verdict/terminal paths are untouched — durable
evidence still lands, and post-suspend terminals project via the
`suspended → complete/failed` edges. Locks: session-double stop request;
quiet exit (DOWN + no terminal + suspended + wakeup scheduled) on a
verdict-free stream.

## R3.2 — Decline-produced sleep recovers (`wakeups.ex`)

`renew_lease` rejected `expired`/`checkpoint_required` old leases, so
restored capacity could never recover a decline sleep. Terminal old
leases now supersede (`{:ok, :superseded}` — the new continuation run
gets its own grant; the old allowance rests untouched). Lock: admitted
wake on a checkpoint-required old lease succeeds with a fresh active
grant.

## R3.3 — Worker effect uses live transport (`elf_effect.ex`)

`provider_defaults` omitted `adapter_opts`, so Codex/Claude ran
simulated and Codex identities were rejected as `os_pid_unavailable`.
Both providers now default to `%{live: true}`, mirroring the manual-run
UI branches. Locks: an adapter-level transport contract test (live:true
with a missing binary fails `transport_spawn_failed`; the flag's absence
returns the simulated os-pid identity) — deterministic and safe, since no
real CLI can be involved. Deliberately NOT tested at Elf level: dispatch
`env:` reaches the runner port only, never the adapter session spawn, so
no hermetic test can sandbox a live provider launch through that path;
production smoke covers it (documented limitation, not a gap).

## R3.4 — Renewal across durable boundaries (`lease_state_machine`,
`lease_renewal`, `elf.ex`)

Two halves: (a) new machine edge `renewed → renewal_due` (+ load gate +
`ensure_due` clause) so every exhaustion re-fires the full sequence with
a fresh snapshot — renewal is no longer single-shot; no new event types,
markers replay idempotently per grant. (b) wake-created leases now carry
`cobbler.lease:admission_event_id` because wake re-evaluations are
persisted as `admission.decided` (idempotent per wakeup; retries replay
the first decision, and downstream consumers use the durable decision,
never the transient evaluation). Renewal errors are logged with
run/dispatch context instead of swallowed; the quota path unlatches
without resetting the spend epoch (zero-spend refusals forgive nothing).

## R3.5 — Wake continuations resume the prior session (`elf.ex`, `wakeups.ex`)

The dispatched wake request carries `wakeup:resume_prior_session_id`
(colon-namespaced per the extensions contract); `start_adapter` prefers
`adapter.resume` when the extension is present and the adapter exports
it (load-guarded like handoff dispatch), falling back to fresh start on
resume error — a dead session never fails an admitted wake. Locks:
Elf-level resume-preferred / fallback / fresh-start tests via Fake
`RequestLog`.

## R3.6 — Handoff prompts carry checkpoint content (`elves.ex`)

`handoff_request` threads the checkpoint record into prompt composition
(same-provider resume keeps its pointer shape); the composed prompt now
carries completed-work/failure/constraints/verification sections. Lock:
production-path prompt contains checkpoint decision text +
stop-reason text absent pre-fix.

## R3.7 — Evals measure genuine behavior (eval tests + evidence)

I7 ablation arms now vary checkpoint BODIES per the milestone's input
variants (shared rich bodies were indistinguishable once prompts forward
content faithfully); the demo re-projects after the wake instead of
reusing a stale triple (the old triple is now asserted refused — a lock
for decision freshness); the semantic fixture routes legs through the
real handoff path with per-arm isolation. Scoring thresholds untouched
(no tuning to fit); totals re-measured green.
