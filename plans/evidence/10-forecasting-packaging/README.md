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

## Historical slice 10E preflight: baseline local release candidate

The following preflight describes `cfd28ad`, before the remainder implementation
recorded below. Its implementation gaps are historical, not current status.

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
worker or provider was started; no provider credentials were inspected and no
endpoint secret was created. Standard Mix assembly generated a candidate-local
distribution cookie, which its launcher reads even with distribution disabled.
Its value was not printed or copied into tracked evidence. Per-install cookie
handling must be resolved before publishing an archive.

At that preflight, UNVERIFIED/open items were clean-machine installation; automatic private first-run
initialization; release manifest and doctor; upgrade/backup/rollback; Homebrew
formula; final archive/checksums; and signing/notarization. No release has been
published. The local candidate is an inspection artifact, not 10E acceptance.

## Remainder implementation: optional text adapters (10D)

REPO-INSPECTION: two optional text-only adapters now implement the existing
identity/capability/lifecycle/error/artifact contract. `openai_responses` uses
the durable spend guard before reading its credential or sending a request;
`ollama_local` checks operator local-only attestation, exact server version,
preinstalled tag/digest, local GGUF metadata and absence of remote-model fields.
Neither supports repository tools, resume or interactive input. They are manual
text-response paths, not new repository-editing workers or task acceptance.
Both remain disabled by default. Subscription forecasts are unchanged.

REPO-INSPECTION: a durable once-only HTTP claim fences replay across process
death and restart. Temporary sessions own linked HTTP tasks. Elves use a
request-owner path with no invented process group, nonblocking buffered event
polling, canonical completion/cancellation and explicit task cancellation.
Missing/ambiguous API usage retains the full reservation. No transport retries,
redirects, decompression, downloads, provider fallback or inference replacement
are introduced. Request/response size and connection setup are bounded. Quiet
model work has no receive timer; explicit cancellation or actual transport/size
failure ends the local request. The completion-wait helper likewise has no
silence deadline.

REPO-INSPECTION: operator environment configuration and queue-only manual text
commands support new or existing goal/task records. Named Oban insertion is
applied to new, recovered and missing-job delivery paths. Normalized API events
expose price version, reserved maximum and output bound. Only visible final text
is stored as an artifact after credential-pattern redaction; raw HTTP envelopes,
separate hidden reasoning, provider IDs and raw errors are not persisted here.
Local metadata is not an egress/security guarantee for a separately owned
daemon; its configuration and concurrent mutation remain operator concerns.

VERIFIED: the focused combined measurement/shadow/spend/diagnostic/release/HTTP
suite passed 79 tests, 0 failures, seed 371839, in 2.1 seconds. Shared adapter
identity, lifecycle, secret-free and terminal assertions run for both adapters;
unsupported resume and missing-capacity behavior are explicit. Local subscription
quota is explicitly unsupported, not simulated. Additional tests cover actual
Elf completion/cancellation, owned-task crash fencing, no duplicate inference,
ambiguous spend, cloud refusal, both write-policy key forms, queue-only delivery,
manual goal/task creation, raw HTTP response bounds and redirect refusal.

VERIFIED: earlier focused runs found a missing bootstrap arity, atom/string JSON
policy comparison and a nil boolean in the synthetic transport. Those were fixed
before subsequent runs. These are new-feature tests, not claimed regression locks
against a commit that lacks the features. No tests were skipped, slept, widened
or retried to hide an intermittent failure.

UNVERIFIED: live inference against either new provider. All inference transports
in tests are synthetic; no live inference budget was used. Dated pricing and
local daemon assumptions remain explicit in [text adapter documentation](../../../docs/text-adapters.md).

## Remainder implementation: native release tooling (10E)

REPO-INSPECTION: native macOS arm64 production releases now build assets/helper,
bundle ERTS and write a manifest binding application/helper/protocol versions,
helper and complete file hashes, target, tested OS, source revision/dirty status,
runtime dependencies and unsigned status. A local packager creates an archive, exact checksums and
matching Homebrew formula, refusing overwrite, external symlinks, changed/added
files, unexpected cookies and dirty source unless explicitly verifying locally.
The launcher refuses a different macOS major before loading ERTS.
No upload or release publication is performed.

REPO-INSPECTION: first-run initialization creates a private persistent endpoint
secret, retaining operator overrides without copying them to state or generated
runtime configuration. Invalid,
public or symlinked secret files are refused. Upgrade migrations take a private,
consistent SQLite backup first; backup failure blocks migration. Current schemas
do not generate repeated upgrade backups. No backup/state is deleted or reaped.
The foreground launcher takes an OS advisory state lock and refuses an occupied
port before initialization. Distribution/RPC is disabled, with a public sentinel
cookie replacing the historical build-generated credential.

VERIFIED: synthetic upgrade tests exercise `Release.migrate` itself against the
previous iteration's schema, compare canonical events and goal data before/after,
reopen the pre-migration backup, verify integrity and private modes, and check
that repeat migration does not create another backup. Private first-run secret,
override, invalid file, permission and symlink paths are tested. Helper version,
protocol, application version and checksum mismatches refuse compatibility.

REPO-INSPECTION: passive doctor checks runtime target/manifest, actual helper
hello, executable presence, secret privacy, SQLite health and port availability.
Explicit metadata-only provider probes have bounded owned commands and discard
raw output, keeping numeric versions and reported authentication only. Synthetic
probe tests check privacy exclusion AND retained useful status. No real provider
probe was run during this implementation.

VERIFIED: an extracted local 0.2.0 candidate was relocated and smoke-tested with
synthetic state and a guarded system-tools-only PATH: initialization, persistent
0600 secret, compatible helper, SQLite health, exact-confirmed private diagnostic
export, HTTP 200 health and UI. A concurrent launcher initialization was refused.
Zero provider/system-toolchain launches were recorded. Generated Homebrew Ruby
syntax passed. Local build/package/smoke logs remain under ignored `tmp/`.

UNVERIFIED: a fresh-machine/Homebrew installation, published release URL, live
provider authentication/inference and Developer ID signing/notarization. OpenSSL,
Git and Python remain declared runtime dependencies. Linux remains deferred.
Real calibration (10B) and forecast-assisted policy acceptance (10C) remain open
and disabled by the user's explicit prior decision. Implementation and external
acceptance are distinct; no complete iteration 10 acceptance is declared here.

See [release, upgrade, rollback and uninstall instructions](../../../docs/releases.md).
VERIFIED: after the last lifecycle/privacy/integrity changes, the focused suite
passed 79 tests, 0 failures, seed 675791, in 2.2 seconds. The updated extracted
candidate passed the same guarded relocation smoke and generated formula Ruby
syntax check. A separate synthetic packaging fixture accepted its intact file
set, refused an added file, and refused an untested macOS major before invoking
the runtime. These checks did not contact a provider.

VERIFIED: the first remainder full gate, `timeout 590 mix precommit < /dev/null`,
passed 4 doctests, 2411 tests, 0 failures, 1 skipped, 6 excluded, seed 529400,
in 552.8 seconds. Rust formatting/Clippy, 4 unit and 5 integration tests passed;
JavaScript passed 52/52 and 14/14 tests. That snapshot preceded removal of the
quiet-response timeout and the final secret-cache/file-integrity safeguards.
VERIFIED: the final `timeout 590 mix precommit < /dev/null` passed after those
changes: 4 doctests, 2411 tests, 0 failures, 1 skipped, 6 excluded, seed 160896,
in 566.2 seconds (11.9 async, 554.2 sync). Rust formatting/Clippy, 4 unit and
5 integration tests passed; JavaScript passed 52/52 and 14/14 with zero failures.
The gate was repeated because product code changed after the first run, not to
hide an intermittent result.

## System and structured-memory verification

VERIFIED: a fresh full gate and separate packaged-process durable-context probe
passed on product revision `2a14f99`. The audit also found that locally installed
Claude/Codex versions are degraded in the capacity compatibility registry, so
these results do not establish unconfirmed automatic quota admission on the
current installations. See the [system verification report](system-verification.md)
and [aggregate command evidence](system-verification.json) for exact counts,
required-context checks, test mappings and remaining limits. Semantic memory,
current live capacity protocols, RSS/soak testing and external install acceptance
are not inferred from the passing hermetic gate.

## Installed capacity compatibility follow-up — 2026-10-22

VERIFIED: an explicitly budgeted Codex 0.163.0 session returned two capacity
reads with zero inference turns. The user approved the sanitized fixture. New
regression coverage defends automatic admission against true, unavailable and
sparse spend-control state. Claude 2.1.308 produced no callback before its
authorized deadline and remains UNVERIFIED; its budget was not retried and its
registry/support tier was not promoted. See the [compatibility report](capacity-compatibility.md)
for exact scope, regression proof, gate results and outstanding limits. This
follow-up supersedes the earlier installed-Codex mismatch finding only; no
full iteration acceptance or forecast enablement is inferred.
