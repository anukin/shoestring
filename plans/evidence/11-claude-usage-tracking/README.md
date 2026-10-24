# Iteration 11 evidence — Claude usage readings and reset-aware holds

Date: 2026-10-24 (UTC). Branch `claude/iter11-claude-usage`, base
`f653854`. Delivered as a PR; iteration 10's direct-to-main authorization was
not reused.

## Live capture

VERIFIED: the user authorized use of the Claude subscription for live checks.
Two tool-free calls were made with Claude Code 2.1.310 from an empty
directory, stdin closed, a 120-second bound, no retries:

- `claude -p --verbose --output-format stream-json --tools= --strict-mcp-config --no-session-persistence`
  emitted frames in the order `system`, `assistant`, `rate_limit_event`,
  `result`: one usage frame, after the reply. It carries `status`,
  `rateLimitType`, and `unifiedWindows.five_hour` / `seven_day` with
  `utilization` (0.15 / 0.15), `resetsAt` (Unix seconds) and, new since the
  2.1.263 capture, a per-window `status`.
- `claude -p --output-format json` (the planner/reviewer mode) returned no
  rate-limit or usage-window field.

Fixture: `test/fixtures/capacity/claude/headless-rate-limit-event-2.1.310-live.json`,
mirrored byte-identically under `plans/evidence/00a-capacity-feasibility/fixtures/claude/`.
Only the usage frame is kept. Its `uuid` and `session_id` were removed (the
capacity fixture scanner forbids session identifiers) and the removal is
recorded in the fixture; every other byte of the frame is as captured. The
`init` frame (paths, tools, model, account fields) was not committed. Secret
scan: `mix shoestring.capacity.fixtures --scan` → 24 fixtures clean; the manual
pattern check matched only the field name inside `identifiers_removed`.
The fixture still needs the human redaction review `docs/capacity-fixtures.md`
requires; that review happens on the PR.

UNVERIFIED: whether the reading reflects usage before or after the run's own
request. The 2.1.263 capture had two frames (start and end); 2.1.310 had one,
after the reply. Calibration does not use Claude readings.

## What changed (REPO-INSPECTION)

- `Capacity.normalize(:claude, :headless_stream_json, frame, ...)` reads
  `rate_limit_event`: utilization × 100 → whole percent, `resetsAt` → UTC,
  provider and per-window status → `claude:*` extensions, CLI version →
  `capacity:cli_version`. Source event `update_notification`. Missing windows
  are unknown, malformed values never become observations.
- The registry's `headless_stream_json` entry is `conservative_partial` and
  compatible for 2.1.261, 2.1.263 and 2.1.310 (the Gate 0A 2.1.251 probe had
  failed before any frame).
- `ClaudeHeadless.Session` normalizes each usage frame and ingests it into
  the Observatory (`:claude_capacity_sink`, default `Observatory`; disabled in
  test config). A frame with no observed window records nothing; sink errors
  are logged and never affect the run.
- Run event extensions keep `*_resets_at` (UTC ISO-8601) next to utilization.
- `AdmissionEvaluation`: a Claude window breach whose reset plus 60 seconds
  has passed no longer hard-stops. Before this, the old reading deferred
  Claude work every `delayed_recheck_seconds` forever, because nothing
  re-reads Claude. Codex behaviour is unchanged.
- The Usage page shows Claude's windows and resets from these readings and a
  notice when Claude reported `allowed_warning`.

## Regression check

VERIFIED: with `lib/` and `config/` reverted to `f653854`, the new tests fail
for behavioural reasons — 11 failures in 37 tests: no reading reaches the sink
or the Observatory, stream-json is classified incompatible, reset times are
absent from run events, the Usage page has no Claude bar, and the old reading
keeps deferring after its reset (`left: :defer_until`, `right:
:require_confirmation`). Two session tests ("a failing sink never affects the
run", "a frame without an observed window records nothing") also pass on the
base: they guard invariants, they are not regression locks.

## Not done

- Automatic resumption without confirmation after a known reset (locked as a
  separate decision).
- Readings from the planner and reviewer: their json mode reports none.
- The twin hard-stop for a Claude *refusal* snapshot with a past reset still
  schedules delayed rechecks; no current path produces such a Claude snapshot.
- Advisory per-task usage estimates (package G).
