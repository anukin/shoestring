# Installed capacity compatibility — 2026-10-22

Status: Codex verified within the scope below; Claude remains unverified.
Full iteration 10 acceptance remains open.

## Authorization and evidence boundary

VERIFIED: the user authorized one Codex 0.163.0 App Server session, at most two
capacity reads, zero model turns and a 60-second deadline; and one Claude
2.1.308 interactive session, one tool-free synthetic prompt, a 180-second
deadline and no retries. Folder trust was authorized only for the prepared
synthetic worktree. No paid API call was authorized or made. Both session
allowances were consumed. The user subsequently approved promotion of the
sanitized Codex fixture in this conversation, satisfying the separate human
review requirement in `docs/capacity-fixtures.md`.

VERIFIED: work continues directly on main under the user's earlier explicit
authorization, overriding the standing worktree/PR workflow. Baseline for this
change is `c4cb8ac946b661d39e49da874a440a62417f9bbe`. User-owned directories,
other worktrees, stashes and prior evaluation leftovers were not changed.

## Codex 0.163.0

VERIFIED: the bounded metadata-only session returned two matching rate-limit
result objects, without creating a thread or issuing an inference turn. The
RPC surface was initialize, initialized, account/read with refreshToken=false,
and account/rateLimits/read twice. The probe retained only authentication type
and an allowlisted capacity projection; account identities, environment paths,
raw output, prompts and provider session identifiers were not persisted. The
owned process group was stopped explicitly.

VERIFIED: the first projection is committed as
[test fixture](../../../test/fixtures/capacity/codex/normal-read-0.163.0-live.json)
and an identical
[evidence mirror](../00a-capacity-feasibility/fixtures/codex/normal-read-0.163.0-live.json).
It retains 54% / 67% usage, 300 / 10080 minute windows, numeric reset timestamps,
a null rateLimitReachedType and false spendControlReached. Projection happened
before persistence; retained values were not edited or replaced. The numeric
RPC id is client-assigned. No private identifier substitution was needed.
The capture is one normal explicit-read case, not a live refusal or push case.

SCHEMA-ONLY: the installed CLI's offline `app-server generate-json-schema`
output describes spendControlReached as boolean or null, with the description:
"Backend-reported spend-control state. `None` is unavailable, not a sparse-update recovery."
The property is optional. This is generated protocol evidence, not an induced
live block. The [schema excerpt](capacity-spend-control-schema.json) preserves
that property unchanged. The general read-only account surface is documented
in the [official App Server documentation](https://learn.chatgpt.com/docs/app-server).

REPO-INSPECTION: the tested capacity registry now includes 0.163.0. Explicit
spendControlReached=true is a hard refusal, including on older supported
versions. For 0.163 and later, absent, null or malformed spend-control state
cannot automatically admit work. Sparse omission retains prior state; explicit
null cannot inherit a prior clear value. A known block requires explicit false
to recover. The unavailable-state snapshot retains quota windows; the existing
hard-refusal snapshot represents its windows as unknown. The monitor retains
the merged provider windows for subsequent explicit recovery.
Older protocols retain their previous absent-field contract. Unknown 0.164.0
remains degraded. This is capacity-protocol compatibility, not certification of
worker execution or every command supported by that CLI version.

## Regression and gate evidence

VERIFIED: final new test assertions were run with baseline c4cb8ac versions of
capacity.ex, capacity/registry.ex and capacity/codex_monitor.ex loaded only into
an isolated test VM. No working-tree product file or compiled BEAM was replaced.
Command: `timeout 120 env MIX_ENV=test mix run --no-start <baseline-driver> < /dev/null`.
Result: 7 tests, 6 failures, exit 2. Failures were behavioral: compatible was
degraded, a hard block admitted instead of deferring, null inherited false,
block/recovery normalization was wrong, monitor state was degraded, and the
unknown spend-state reason was absent. The seventh test already passed on the
baseline and is a boundary check, not a newly established regression lock.

VERIFIED: final focused command:
`timeout 180 mix test test/shoestring/harness/capacity/installed_version_compatibility_test.exs test/shoestring/harness/capacity_test.exs test/shoestring/harness/capacity/ < /dev/null`.
Result: 202 tests, 0 failures, 4 excluded; seed 164129; 3.6 seconds.
Production monitor tests use supervised FakeTransport and a fixed clock, with
no model turn. They cover normal, unavailable, refused and explicitly recovered
states, retained windows and the allowed metadata RPC surface. Fixture lifecycle
checks cover both privacy exclusion and retention of useful capacity fields.
The corpus and evidence mirror contain exactly 22 fixtures.

VERIFIED: intermediate focused runs found an exact registry-list expectation,
a wrong result enum and an unapplied source edit (200 tests / 2 failures, then
201 / 1). The tests/source were corrected before the final focused run. Earlier
prototype errors were not used as regression proof. No failure was hidden by
skipping, sleeping, widening an existing assertion or retrying until green.

VERIFIED: full gate on the final working tree (baseline c4cb8ac plus this
change), 2026-10-23: `timeout 590 mix precommit < /dev/null`, exit 0. Format
and warnings-as-errors compile passed; Rust 4 unit + 5 integration passed;
ExUnit 4 doctests, 2418 tests, 0 failures, 1 skipped, 6 excluded, seed 317875,
514.4 seconds; Node 52/52 and 14/14 passed. The seven added tests account for
the change from the previous 2411.

## Claude 2.1.308 and remaining limits

VERIFIED: Claude had updated to 2.1.308 before the authorized session. The
sandboxed synthetic attempt produced no usable status-line callback before its
180-second deadline. The probe terminated its owned process group and recorded
failed_or_unverified / deadline, automatic_retry=false. No raw PTY output or
hidden model reasoning was persisted. The configured prompt forbade tools.

UNVERIFIED: whether inference completed, whether trust was accepted, and the
cause of the missing callback. Safe mode may have disabled the customization,
but this was not established by a controlled comparison. No second session was
started. I did not verify Claude 2.1.308 capacity. It is not promoted in the
registry. A revised live attempt needs a new named authorization budget.
REPO-INSPECTION: Claude remains conservative_partial and requires attributable
confirmation even for a tested version; there is no promotion to unattended
automatic quota admission. The [official status-line documentation](https://code.claude.com/docs/en/statusline)
explains the callback surface and its dependence on response/trust state.

UNVERIFIED: live Codex push/refusal transitions; those inputs were constructed
in memory for hermetic tests, never mislabelled as captured evidence. The
previous local packaged archive still identifies its earlier product revision;
it was not rebuilt for this source change. This work does not close paid-API
inference, real calibration, forecast-assisted routing, fresh-machine install,
release signing/publication or deferred Linux sandboxing acceptance items.
Forecast-assisted routing remains disabled.
