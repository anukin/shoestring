# Local run measurements

Iteration 10 begins with measurements, before forecasting changes admission.
Dataset/extractor version 1 reads canonical trajectory events, not terminal
output, current worktree contents, mutable run projections, or provider history.
It neither starts providers nor changes admission, leases or reservations.

```sh
mix shoestring.measurements report
mix shoestring.measurements rebuild --split-at 2026-10-01T00:00:00Z
mix shoestring.measurements export ./measurements.json --split-at 2026-10-01T00:00:00Z
mix shoestring.measurements delete --confirm
```

`report` derives an aggregate quality report without saving a cache. `rebuild`
explicitly replaces the disposable `measurements/dataset-v1.json` cache under
the configured state directory. `export` derives a new snapshot and creates a
mode-0600 file; existing files are never overwritten. All commands work without
starting the Shoestring application, monitors, execution workers or provider CLIs.

`delete --confirm` removes only the fixed derived cache. It leaves trajectory
history and exported copies intact. Those copies must be removed separately
with ordinary file management. Rebuild/export can regenerate measurements from
the remaining history; this command does not erase source history. A failed
write may leave an incomplete export or rebuild temporary file; no background
cleanup deletes files or other worktrees.

## Contents and provenance

Every row identifies the local run, goal and task, and the IDs, goal sequences,
types and schema versions of its source events. Dataset watermarks and a source
digest identify the complete input snapshot. Canonical JSON makes repeated
rebuilds byte-identical for the same events and explicit split timestamp.
Changing current run projections cannot change the result.

Rows contain recognized provider/harness classes, numeric CLI versions when
available, lease budgets/reserves/deadlines, lifecycle outcome and elapsed time,
gate kinds/results/durations, attempts, checkpoint/handoff counts and before/after
capacity provenance. A completed run is distinct from a task accepted by
Shoestring's gates. Unknown adapter labels are exported as `unknown`.

Prompt/source content, workspace paths, provider session IDs, arbitrary
extensions, command arguments, error prose and terminal bytes are excluded.
Account scope is represented by a digest for local correlation, not raw text;
provider-controlled window labels become ordinal numbers. Local event/run IDs
and timestamps remain in exports, so choose their destination deliberately.

Several historical facts were not recorded with sufficient provenance. Model,
effort, adapter version, repository/context features, concurrent reservation
units and handoff tax remain missing, rather than being inferred from prompts,
the current checkout, or the current adapter binary. The quality report counts
missing fields against its explicit run count. It does not present zero missing
values in an empty dataset as evidence of coverage.

## Attribution and chronological evaluation

Before capacity comes from the run's admitted lease snapshot, in the same goal
and provider. After capacity is the first subsequent reading in that exact
provider/adapter/mode/account bucket. The extractor reports stale or late
boundaries, unfinished runs, version/window/reset changes and known overlapping
Shoestring runs. Provider-wide overlapping runs are counted conservatively even
when their account scope is not known. Historical reservation occupancy is
missing; current reservation state cannot reconstruct past occupancy honestly.

An observed percentage change is not attributable run consumption. Version 1
cannot establish the absence of external sessions. Every row therefore has
`external_usage: unknown`, no assignable consumption value, and
`training_eligible: false`. No forecast or savings claim follows from the
observed changes. Invalid, unsupported, duplicate or gapped history fails
visibly rather than producing a partial successful dataset. Extraction refuses
more than 10,000 events or 32 MiB of source payloads; export also has a 32 MiB
bound. These are explicit initial limits, without truncation.

The optional split uses the latest source-evidence availability, including a
post-run capacity reading and later gate acceptance, rather than the run's
finish time alone. Evidence available exactly at the split belongs to evaluation;
unfinished runs never become training examples. No current-time split is chosen
implicitly. A subsequent rebuild can change a row when new evidence arrives,
and its source digest/availability timestamp makes that change visible.

Before even a shadow forecast is considered data-ready, the initial requirement
is at least 100 attributable training runs and 100 later evaluation runs per
provider/harness/model/effort/version/task class, with independently established
external-session isolation. These sample minima are a prerequisite, not a
statistical guarantee or permission to enable routing. Shadow interval coverage,
underprediction, drift and baseline comparisons must still be evaluated under
slice 10B; policy enforcement needs slice 10C's separate acceptance evidence.

VERIFIED in the initial local inventory: three capacity observations, zero run
samples. Forecast readiness is false. Codex readings did not record their CLI
version until version 2's change, so historical rows have none. No live provider calls were used to build
or test this slice.

## Version 2: attested collection

Version 2 adds the prerequisites version 1 lacks. It reuses version 1's
history validation and row provenance unchanged, and v1 output is unchanged.

```sh
mix shoestring.measurements collection open --provider codex --by operator
mix shoestring.measurements collection status
mix shoestring.measurements collection close --provider codex [--reason external_use_reported]
mix shoestring.measurements report --dataset-version 2 [--split-at ISO8601]
mix shoestring.forecasts report --dataset-version 2 --split-at ISO8601 --at ISO8601
```

**Pinned class.** Agent-profile roles can pin a reasoning effort. Model and
effort travel in the immutable execution binding on `run.requested`, so they
are recorded before dispatch. A role left at provider default has no effort
and its rows miss a class feature. The task class is the sorted set of gate
names the approved plan assigned to the task (`gates:mix_test`), a coarse
structural class known before dispatch; gate parameters are not used. The
Shoestring version and the provider CLI version come from the before reading.

**Collection windows.** A person opens a window per provider and scope,
attesting that nothing outside this installation uses the account until it is
closed. Opening requires typing the attestation; an agent must never open one.
Close with `external_use_reported` if the account was used elsewhere: every row
in that window is then excluded. Windows are canonical events in the protected
Observatory stream.

**Readings around each run.** Inside a window, Shoestring takes an explicit
Codex `account/rateLimits/read` right after an attempt is admitted and right
after its run terminates. These run no model turn. Claude's only capacity
signal comes from an inference session, which would spend the quota being
measured, so Claude runs are never read and never become examples. Fan-out
siblings get no after reading; they overlap each other and are excluded.
Readings are evidence only and never change admission, dispatch or gates.

**Attribution.** A row is assignable only when all of these hold:

- every class feature is present;
- the before reading is at most 120 seconds before the run started, the after
  reading at most 120 seconds after it finished, both explicit reads;
- both readings are observed, from the same provider bucket and CLI version,
  with identical window resets that are still in the future, and no window
  decreased;
- both readings fall in one window not closed for external use;
- within that window, every after reading equals the next run's before
  reading — any difference is usage nobody accounted for, and the whole window
  loses its examples;
- no other Shoestring run of the provider, in any goal, overlapped (from its
  request to its finish).

The consumption value is the change in the shortest window (Codex's five-hour
window), in the provider's whole-percent units; every window's change is kept.
A one-point change is the smallest step the provider reports, so short tasks
often measure zero. Rows still need 100 training and 100 later evaluation
examples per class before a shadow forecast can be evaluated, and routing stays
disabled whatever the shadow report says.

**What this cannot see.** Usage outside Shoestring that happens during a run
and is not followed by a between-run mismatch is invisible; the attestation is
what excludes it. The between-run check only works when consecutive runs fall
in one window.
