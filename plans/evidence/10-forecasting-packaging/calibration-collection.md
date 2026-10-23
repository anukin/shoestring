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
