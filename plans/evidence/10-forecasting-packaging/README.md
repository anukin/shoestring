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
