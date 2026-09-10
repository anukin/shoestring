# Snapshot → Candidate Binding (W1 Safety Fix)

Iteration 05, quota-aware MVP. Binds capacity snapshots to the candidate
provider/scope at wake time (P1) and at admission evaluation (P2 defense in
depth), closing the fail-open path where a wake for one provider could be
decided on another provider's allowance.

## Problem (VERIFIED)

- `Shoestring.Cobbler.WakeupObserve.observe/0` returned the globally newest
  Observatory observation with no provider/scope filter
  (REPO-INSPECTION: pre-fix `wakeup_observe.ex` `Enum.max_by` over
  `Observatory.latest_observations/0`).
- `AdmissionEvaluation.do_evaluate/6` consumed the handed snapshot's usage
  numbers without checking snapshot identity against the candidate; the
  scope-mismatch hard check compared request-vs-candidate only
  (REPO-INSPECTION: pre-fix `admission_evaluation.ex`
  `check_hard_constraints/6`).
- Net effect: a wake admission for `provider`/`account:other` could admit on
  a `codex`/`account:codex` snapshot's allowance. The admission math was
  innocent; the contamination entered through the unkeyed single-snapshot
  plumbing.

## Implementation

- P1 (VERIFIED): `WakeupObserve.observe/1` takes `%{provider_id:, scope:}`
  (atom or string keys) and returns the newest observation FOR THAT
  provider/scope (ordered by provider `observed_at`), or fail-closed
  `{:error, :no_observation_for_provider}` when the ledger holds nothing for
  that identity — never another provider's snapshot. Empty ledger keeps
  `{:error, :no_observation}`; read crashes keep
  `{:error, :observation_unavailable}`. The unscoped `observe/0` is removed.
- P1 callers (VERIFIED): `Wakeups.perform_wakeup/2` resolves the admission
  context (explicit opts or latest `admission.decided`, same sources as
  before) BEFORE observing and passes `%{provider_id:, scope:}` to the
  `:observe` fun. The fun may be arity 1 (scoped; production
  `{WakeupObserve, :observe, []}` MFA resolves to `observe/1` because
  `WakeupWorker` appends the scoping map to the MFA args at perform time) or
  arity 0 (legacy hermetic injection; still binding-checked by P2). The
  production `config/runtime.exs` MFA line itself is unchanged.
- P2 (VERIFIED): `check_hard_constraints/6` gains clause 4b
  `snapshot_provider_mismatch?/2` → `{:hard_stop, :reject,
  "snapshot_provider_mismatch", ...}`, unbypassable like `scope_mismatch`
  (it sits in the hard-constraint `cond`, before eligibility/confirmation).
- P3 (VERIFIED): nil snapshots still flow to `unknown_capacity` /
  `require_confirmation`; existing suites green (see gate).
- P4 (VERIFIED): no new trajectory event types. `snapshot_provider_mismatch`
  is a decision payload string only; `:no_observation_for_provider` is a
  probe error atom surfaced as `{:error, {:observation_failed,
  :no_observation_for_provider}}` with the intent left due.

## Exact identity fields compared

- Snapshot side: `snapshot.source.provider_id` and `snapshot.scope`
  (struct and string/atom-keyed map forms; `source.adapter_id` and
  `source.invocation_mode` are probe provenance, deliberately NOT compared).
- Candidate side: normalized `candidate.provider_id` and `candidate.scope`.
- Exact string equality. A present-but-disagreeing provider OR scope
  hard-stops; absent identity fields on a non-nil snapshot stay unknown
  (confirmation path, never a binding reject); nil snapshots are untouched.

## Tests (hermetic: Fake + fixtures, no provider CLI, no network)

New: `test/shoestring/cobbler/snapshot_binding_test.exs` (11 tests).
Updated: `wakeup_production_test.exs` scoped-observe test (foreign-newest
ledger, per-provider newest, unknown-provider error).

Fail-on-base ledger, VERIFIED against `4735d9f` via stash of tracked source
edits (new test file untracked, kept in place; base-incompatible surface
noted):

- LOCK (base admits, fix rejects): foreign→codex unit, codex→foreign unit,
  scope-only unit, confirmation-override unit, confirmed map-form unit —
  each base `left: :admit` vs asserted `:reject`; e2e
  `perform_wakeup` base `left: :admitted` vs asserted `:rejected`.
- DOCUMENTATION (new surface, N/A on base): `observe/1` newest-wins,
  unknown-provider error, scoped e2e intent-due, empty-ledger error —
  fail on base with `UndefinedFunctionError` / `:missing_observe_fun`,
  stated honestly.
- CONTROLS (pass on base and fix): bound snapshot admits, nil snapshot
  requires confirmation, identity-less snapshot requires confirmation
  without a binding reject.

## Deviations from P1–P4

- `lib/shoestring/cobbler/wakeup_worker.ex` edited (MFA applied with
  appended scoping map; arity-preserving `:observe` env contract). The brief
  names the worker as a P1 caller to update ("Wakeups.perform_wakeup path,
  worker"); the ownership list did not include it. Taken as an explicit
  brief instruction overriding the file list (minimal diff, no behaviour
  change for zero-arity hermetic injections).
- `config/runtime.exs` intentionally NOT touched: the MFA line
  `{WakeupObserve, :observe, []}` stays valid (scoping is appended by the
  worker). Its comment still says `observe/0`; flagged for the config owner
  rather than edited (W2 owns config wiring).

## Gate

`mix precommit` (format --check-formatted, compile --warnings-as-errors,
test, gate_0a node tests): exit 0 — VERIFIED this run. `1142 tests,
0 failures, 1 skipped (6 excluded)` in 77.0s; node probe suite `52 pass,
0 fail`. One pre-existing runtime warning in untouched
`test/shoestring/cobbler/wake_reobserve_test.exs:89` (`dispatch_jobs_before`
unused) also present on base; it does not fail the gate.
