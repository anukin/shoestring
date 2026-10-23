# Calibration collection v2 — 2026-10-23

Status: in progress. The user gave the go-ahead for calibration collection on
2026-10-23 and said not to wait for further answers. Real calibration, shadow
acceptance (10B gate) and forecast-assisted routing (10C) remain open; routing
stays disabled. Work continues directly on main under the iteration's recorded
authorization.

The v1 extractor never produces training rows by design: model, effort and task
class were never recorded before dispatch, and nothing established that the
provider account was otherwise idle. v2 adds those prerequisites in steps.

## Step 1: pinned effort

REPO-INSPECTION: agent-profile roles gain an optional effort, validated per
provider (Claude `low medium high xhigh max`, from the 2.1.309 `--effort`
help; Codex `low medium high xhigh`, a subset of the model-advertised values).
It is stored in the immutable revision only when chosen, so revisions without
it keep their previous configuration shape and digest. The execution binding
carries it only when set, so bindings recorded before this change still
validate. Delivery treats the binding as authoritative: a runtime adapter
effort is removed when the binding has none. Codex receives it on
`turn/start` for fresh and resumed threads (the 0.163.0 generated schema has
`effort` on TurnStartParams and not on ThreadStartParams); Claude receives
`--effort`.

VERIFIED: the new and changed tests, run on a detached worktree of `c34a862`
with only the test files copied in: 20 tests, 6 failures, each behavioural —
Codex turn/start lacked effort (fresh and resumed), Claude argv lacked
`--effort`, the revision dropped effort, delivery passed the runtime `"low"`
instead of the pinned `"high"`, and a runtime effort leaked into a binding with
none. The configuration-shape test passes on the base and is a boundary check.

VERIFIED: `timeout 590 mix precommit < /dev/null`, exit 0: Rust 4 + 5; ExUnit
4 doctests, 2424 tests, 0 failures, 1 skipped, 6 excluded, seed 7093,
505.7 seconds; Node 52/52 and 14/14.

## Step 2: operator-attested collection windows

REPO-INSPECTION: `measurement.collection.opened` / `.closed` (schema 1) are
canonical events in the protected Observatory stream, beside the capacity
readings they qualify, so no second protected goal or UI exclusion was
needed. A window names a provider, scope, attestation version and an operator
label (a slug, not an identity). At most one window is open per provider and
scope; open and close each run in one immediate SQLite transaction, and an
ordinal idempotency key makes racing opens collide. Close reasons are
`operator_closed` or `external_use_reported`. Membership opens inclusively
and closes exclusively; a close naming no open window is ignored.

`mix shoestring.measurements collection status|open|close` exposes them.
`open` prints the attestation (nothing other than this installation uses the
provider account until the window is closed) and requires typing `I attest`.
An agent must never open a window: it cannot know what else uses the account.
No window has been opened by this work.

VERIFIED: `collection_test.exs`, 6 tests, 0 failures. This is a new
capability: on the base commit these tests fail only because the module does
not exist, so they are behaviour documentation, not a regression lock.

VERIFIED: `timeout 590 mix precommit < /dev/null`, exit 0: Rust 4 + 5; ExUnit
4 doctests, 2430 tests, 0 failures, 1 skipped, 6 excluded, seed 408391,
506.3 seconds; Node 52/52 and 14/14.

## Step 3: before and after readings

REPO-INSPECTION: while a collection window is open for the provider and
scope, an admitted plan attempt gets an explicit capacity reading right after
its admit decision, and the sequential executor takes another right after
the run's terminal is confirmed, before gates. Both are goal-local
`capacity.snapshot_observed` events (new GoalLocalObservation flows
`measurement-before` / `measurement-after`), actor `measurement`, marked with
`measurement:bracket` and `measurement:context` (execution, task, attempt),
which `cobbler.plan.task.dispatched` maps to the run. Idempotency is per side
and attempt, so a retry keeps the first reading. An after reading needs a
before reading for the same attempt.

Only Codex is read: `account/rateLimits/read` runs no model turn. Claude's
only capacity signal comes from an inference session, which would spend the
quota being measured, so Claude runs are never bracketed and cannot become
calibration examples. Fan-out siblings complete through a different path and
get no after reading; they overlap each other and are excluded anyway.

Readings are evidence only: any failure records nothing and never changes
admission, dispatch, gates or the outcome. They are not projected when
appended, because a goal projector failing on an unrelated event must not
make a durable reading look lost (found while testing: the test's synthetic
terminal left the goal's projector failed, and the earlier version reported
a recorded reading as not recorded).

VERIFIED: `brackets_test.exs` 7 tests and the executor completion test in
`execution_profile_test.exs`, all passing. New capability: on the base commit
they fail only on the missing module, so they document behaviour rather than
lock a regression.

VERIFIED: `timeout 590 mix precommit < /dev/null`, exit 0: Rust 4 + 5; ExUnit
4 doctests, 2438 tests, 0 failures, 1 skipped, 6 excluded, seed 556800,
505.8 seconds; Node 52/52 and 14/14.

## Step 4: dataset v2

REPO-INSPECTION: `Shoestring.Measurement.DatasetV2` builds on the unchanged v1
extractor and adds the pinned class, bracket attribution, window membership,
between-run consistency and overlap checks described in
[docs/measurements.md](../../../docs/measurements.md#version-2-attested-collection).
`report`, `rebuild` and `export` take `--dataset-version 2` (separate cache
file); `mix shoestring.forecasts report --dataset-version 2` evaluates it; the
shadow evaluator accepts version 2 datasets and is otherwise unchanged.
Routing remains disabled.

Found and fixed while building it:

- No producer set the canonical `capacity:cli_version` snapshot extension, so
  every recorded reading had lost its CLI version (v1 reported it missing).
  Codex normalization now records the version it normalized against.
  VERIFIED regression: the new test in
  `installed_version_compatibility_test.exs`, run on a detached worktree of
  `c34a862`, fails with `cli_version` nil instead of `"0.163.0"`. Twin not
  changed: Claude snapshots and Codex refusal/unknown snapshots still carry
  no version; neither can become a v2 example.
- Approved plan content is stored as canonical JSON text; task-class
  derivation decodes it (found by the v2 tests, never shipped).
- Bracket readings stamp the Shoestring version
  (`measurement:shoestring_version`) as the adapter version.

VERIFIED: `dataset_v2_test.exs`, 12 tests, 0 failures. History is built
through the real plan approval, profile-bound dispatch, collection and reading
paths with injected times and readings: an attested, tightly bracketed,
classified run becomes an example with consumption 2 in the 300-minute window;
rebuilds are byte-identical and v1 is unchanged; no window means no readings;
early, late and after-start readings, external-use closure, overlapping runs,
an unexplained between-run change (voids the window) and provider-default
effort are each excluded; consistent consecutive runs both remain examples.
Two test-only corrections were needed and are not product changes: readings
use future reset times (the captured fixture's resets are now past, which the
extractor correctly rejects), and the executor is given the test clock so
`run.requested` is not stamped by the system clock. The overlap rule was not
loosened.

VERIFIED: `timeout 590 mix precommit < /dev/null`, exit 0: Rust 4 + 5; ExUnit
4 doctests, 2451 tests, 0 failures, 1 skipped, 6 excluded, seed 909947,
507.6 seconds; Node 52/52 and 14/14.

UNVERIFIED: no live run has been measured. No collection window exists, and
none will be opened by an agent.
