# Iteration 10 evidence

Status: in progress. This is not an iteration 10 completion declaration.

## Scope and preflight

VERIFIED: the user requested iteration 10 after iteration 9 acceptance and
previously authorized work directly on `main` in the source checkout. That
explicit authorization overrides the standing worktree isolation rule. Baseline
is `a0a1c74`; its earlier gate counts are not claimed for this work.

REPO-INSPECTION: the local milestone requires slices 10A–10F, verified separately.
It covers measurements, shadow forecasting, forecast-assisted policy, adapters,
packaging and diagnostics. Linux remains deferred; macOS arm64 is the first
actually tested release target. No signing/notarization process is established
by this work; no signing claim is made.

VERIFIED: a read-only aggregate inventory found three development trajectory
events, all capacity observations, zero runs and zero reservations. The default
production database was absent. No prompts, credentials or account identifiers
were printed. `mix shoestring.measurements report` subsequently confirmed three
snapshots, zero run rows, zero assignable consumption rows and false forecast
readiness. Scratch/live-eval databases are not imported or silently reclassified
as representative user work.

UNVERIFIED: useful real-world forecast calibration and improvement over static
admission. There are no attributable local run samples. No inference calls are
authorized by this iteration's implementation request; none have been made.

## Slice 10A: measurement foundation

REPO-INSPECTION: dataset/extractor v1 derives a consistent bounded snapshot from
canonical events, with row source references, dataset watermarks and input
digest. Rebuild/report/export use repository-only startup. The disposable cache
is separate from canonical history. Export refuses overwrite; confirmed delete
affects only the derived cache. There is no cleanup/reaper behavior.

REPO-INSPECTION: features are explicitly allowlisted. Prompts/source, paths,
provider session IDs, arbitrary metadata and terminal output are excluded;
unknown historical model/effort/adapter/repository/reservation/tax features stay
missing. Percentage changes remain observed changes, never billed usage or
attributable consumption. All historical rows have unknown external-session
usage, no assignable label and false training eligibility. Known concurrent
Shoestring runs, missing/stale/late boundaries and version/reset changes are
reported. A chronological split waits for the latest source-evidence timestamp.

REPO-INSPECTION: initial shadow-data prerequisites are 100 attributable training
and 100 later evaluation rows per fully versioned class, with independently
established isolation. These are necessary sample minima, not evidence of
calibration, statistical guarantees, or authorization to enable learned routing.
Further collection/provenance work is needed before historical rows can qualify.

Fixture convention: generated UUIDs identify synthetic local goals/tasks/runs
and events. Fixture timestamps and numeric versions are constructed test data.
Only synthetic privacy markers/paths are used in tests. No captured provider
output or identifiers are committed. Local inventory/report logs remain under
ignored `tmp/`; only aggregate counts are recorded here.

Feature tests are new-feature coverage, not regression locks against `a0a1c74`,
which lacks the measurement feature. No missing-module failure is claimed as a
behavioral regression proof. Full gate results will be recorded below.

See [measurement commands and limits](../../../docs/measurements.md).

VERIFIED: the user explicitly confirmed proceeding with independent adapter,
packaging and diagnostic slices while keeping forecasts disabled. That decision
permits independent slices to proceed without presenting missing real
calibration or slice 10C policy improvement as completed.

VERIFIED: the focused hermetic measurement suite passed 18 tests, 0 failures,
seed 900302. It covers deterministic bytes and provenance; privacy exclusions
and retained numeric features; concurrent runs; missing/stale/late observations;
scope/provider/version/reset boundaries; unfinished and inconsistent timestamps;
chronological evidence availability; malformed history; fixed-size refusal;
private exports, overwrite refusal, and confirmed cache-only deletion. A
provider CLI guard recorded no provider launches in the storage/command tests.

VERIFIED: `timeout 590 mix precommit < /dev/null` exited 0 for slice 10A:
4 doctests, 2350 tests, 0 failures, 1 skipped, 6 excluded; seed 16560. ExUnit
completed in 553.6 seconds (11.7 async, 541.8 sync). Rust formatting/Clippy
passed, with 4 unit and 5 integration tests passing. JavaScript passed 52/52
and 14/14, 0 failures. SQLite warnings occurred, but the completed run had no
failures. One full gate was run for this slice, without retry.

## Slice 10B foundation: shadow-only evaluation

REPO-INSPECTION: forecast/evaluator v1 computes a conservative finite-sample
99% upper order statistic per exact versioned cohort, with minimum 100 training
and 100 strictly later evaluation rows. Held-out coverage must be at least 99%
(at most 1% observed underprediction). Sparse, uncertain, mismatched-version,
future, malformed or undercalibrated cohorts produce explicit fallback. These
are initial shadow targets, not a real-world calibration or statistical claim.
Every output retains static policy with no dispatch effect; there is no enable
switch or production admission integration.

VERIFIED: combined measurement/shadow tests passed 29 tests, 0 failures, seed
213299. Constructed 200-row cohorts verify interval computation, chronological
exclusion, sparse/version-shift/contamination fallback and exact underprediction
counts. Task acceptance and forecast accuracy are separate metrics. The real v1
extractor still cannot produce eligible consumption labels. Provider tests and
network calls were not used. This is new-feature coverage, not a regression
claim against a pre-feature commit.

VERIFIED: the repository-only local shadow report completed with class_count 0,
forecast_count 0 and fallback no_fully_classified_rows. The development ledger
still has no run samples. Real calibration (10B) and forecast-assisted policy
acceptance (10C) remain UNVERIFIED and disabled, by the user's explicit decision.
The last full gate above belongs to 10A; final full integration verification
after later independent slices is still required.

See [shadow reporting and limitations](../../../docs/shadow-forecasts.md).

## Slice 10D foundation: durable API spend authority

REPO-INSPECTION: API policy defaults to disabled and zero cap. Positive allowance
also needs an accepted effective price version. A run request cannot choose its
cap/prices. Immediate SQLite transactions reserve a whole-call maximum against
a durable dispatch/run identity. Duplicate delivery cannot authorize another
call. Reconciliation uses the immutable quote; ambiguous usage retains the full
maximum across restart and month rollover. Cross-month calls conservatively
occupy both endpoints. This is upper-bound bookkeeping, not exact billing.

VERIFIED: the first focused invocation stopped before tests because SQLite
rejects ALTER TABLE ADD CONSTRAINT. The migration was corrected to define
checks inline in CREATE TABLE, following the repository convention. The next
focused run passed 42 combined measurement/shadow/spend tests, 0 failures, seed
177781, in 1.4 seconds. No assertion was skipped, slept, widened or retried.
Eight independent SQLite connections could reserve only three maxima; duplicate
delivery, restart, uncertainty, month rollover, lower caps, price drift, invalid
usage, immutable settlement and database constraints are covered. No provider
CLI or API request is used. These are new-feature tests, not pre-feature
regression locks.

REPO-INSPECTION: official OpenAI documentation was fetched for Responses usage,
model bounds and pricing. The built-in dated schedule is conservative and
requires operator acceptance; commercial prices remain assumptions, not a bill
guarantee. [Spend authority and pricing assumptions](../../../docs/api-spend.md)
record exact sources and limits. No credentials were read, and no API call was
made. Adapter lifecycle integration and the slice 10D shared adapter/failure
suite are still pending; this foundation alone does not complete 10D.

## Slice 10F: bounded diagnostic preview and export

REPO-INSPECTION: diagnostic format v1 uses an allowlisted projection, local
goal/run/event aliases and relative timing. It excludes original identities,
paths, auth material, prompts, source, output and arbitrary prose. Historical
compatibility metadata and bounded enum/numeric lifecycle evidence remain.
Policy explanations use local templates instead of copying stored text.
Selected source is bounded to 8 MiB and exports to 512 KiB; selection is at most
200 recent events, with explicit omitted counts. This is lossy diagnostic data,
not replayable history or an anonymity guarantee.

REPO-INSPECTION: preview prints the complete proposed bytes and manifest. Export
regenerates them and requires the exact preview SHA-256, then creates an
exclusive file with mode 0600 before writing content. Existing files/symlinks
are refused. No upload, provider probe, migration or cleanup is performed by the
diagnostic operation. The CLI opens only existing state; SQLite may create its
ordinary sidecars. Authentication and actual helper compatibility explicitly
remain unchecked. The compiled fixture hashes cover two named compatibility
fixtures, not an exhaustive inventory.

VERIFIED: the focused diagnostics/measurement/shadow/spend suite passed 58
tests, 0 failures, seed 863710, in 1.5 seconds. Diagnostic tests cover privacy
exclusions AND retained useful fields; exact-byte confirmation; changed source
and configuration; selections; oversized source; private/exclusive exports;
symlink refusal; missing-state inspection; history preservation; and provider
CLI guards. These are new-feature tests, not behavioral regression locks
against the pre-feature commit. No live inference call was made.

VERIFIED: `mix shoestring.diagnostics preview --limit 10` completed against
existing local development state: three selected capacity events, zero omitted,
and 1,742 canonical bundle bytes. No user diagnostic export was created or
shared. The preview remained local in ignored `tmp/`. Release packaging and a
release doctor remain independent, unfinished slice 10E work.

See [diagnostic commands and limits](../../../docs/diagnostics.md).

VERIFIED: `timeout 590 mix precommit < /dev/null` exited 0 after the diagnostic
slice and integrated measurement/shadow/spend foundations: 4 doctests, 2390
tests, 0 failures, 1 skipped, 6 excluded; seed 582684. ExUnit completed in 575.3
seconds (12.1 async, 563.1 sync). Rust formatting/Clippy passed, with 4 unit and
5 integration tests passing. JavaScript passed 52/52 and 14/14, 0 failures.
Expected fixture warnings and SQLite warnings occurred; there were no test
failures. One full gate was run for this slice, without retry. This verifies
the current independent foundations, not real calibration or unfinished adapter
and release acceptance.

## Slice 10E preflight: local release candidate

VERIFIED: `MIX_ENV=prod mix assets.deploy` exited 0. The initial release command
found an existing default output and stopped at its overwrite prompt with
closed stdin; that output was not reused or overwritten. A subsequent
`MIX_ENV=prod mix release --path tmp/iter10-release-cfd28ad` assembled a fresh
candidate from `cfd28ad`, exiting 0. All commands were bounded and foreground.
Generated extensionless digested license copies now have explicit ignore rules;
the original vendored license files remain tracked. No files were deleted.

VERIFIED: the candidate contains ERTS 16.2 and the native PTY helper. A bounded
hello-only handshake returned protocol 1, helper version 0.1.1 and max_frame
65536; control EOF ended the helper. No provider session was started. Mach-O
link inspection found a runtime dependency on Homebrew's OpenSSL 3; the build
is not independent of that library. The SQLite NIF also carries a build-host
install-name label; this is not proof of a runtime dependency on that path.
Neither path nor other machine details are copied into this evidence record.

VERIFIED: a bounded release `eval` with only system tools on PATH, distribution
disabled, an isolated unused state directory and no endpoint secret exited 1:
runtime configuration requires SECRET_KEY_BASE. The eval marker did not run.
This verifies bundled-runtime invocation and the current first-run failure,
not successful first-run initialization, migration or UI startup. No endpoint,
worker or provider was started; no credentials were read or created.
Correction to that last scope: no provider credentials were inspected and no
endpoint secret was created. Standard Mix assembly generated a candidate-local
distribution cookie, which its launcher reads even with distribution disabled.
Its value was not printed or copied into tracked evidence. Per-install cookie
handling must be resolved before publishing an archive.

UNVERIFIED/open: clean-machine installation; automatic private first-run
initialization; release manifest and doctor; upgrade/backup/rollback; Homebrew
formula; final archive/checksums; and signing/notarization. No release has been
published. The local candidate is an inspection artifact, not 10E acceptance.
