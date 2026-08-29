const assert = require("node:assert/strict")
const test = require("node:test")

const {normalizeStatusLineInput} = require("../tools/gate_0a/claude_statusline_observer")

test("normalizes only documented Claude rate-limit fields", () => {
  const result = normalizeStatusLineInput({
    version: "2.1.251 (Claude Code)",
    session_id: "must-not-be-retained",
    cwd: "/private/path",
    rate_limits: {
      five_hour: {used_percentage: 23.5, resets_at: 1_738_425_600},
      seven_day: {used_percentage: 41.2, resets_at: 1_738_857_600},
      spend_limit: {used_percentage: 62.8, resets_at: 1_740_787_200},
    },
  }, "2026-08-29T07:00:00.000Z")

  assert.deepEqual(result, {
    schema_version: 1,
    evidence_status: "live_observed",
    provider: "claude",
    source_event: "status_line_callback",
    probe_run: null,
    observed_at: "2026-08-29T07:00:00.000Z",
    cli_version: "2.1.251 (Claude Code)",
    rate_limit_signal: "observed",
    rate_limits: {
      five_hour: {used_percentage: 23.5, resets_at: 1_738_425_600},
      seven_day: {used_percentage: 41.2, resets_at: 1_738_857_600},
      spend_limit: {used_percentage: 62.8, resets_at: 1_740_787_200},
    },
  })
  assert.equal(Object.hasOwn(result, "session_id"), false)
  assert.equal(Object.hasOwn(result, "cwd"), false)
})

test("keeps absent or malformed windows explicit without inventing usage", () => {
  const result = normalizeStatusLineInput({
    version: "2.1.251 (Claude Code)",
    rate_limits: {
      five_hour: {used_percentage: "23.5", resets_at: "later"},
      seven_day: null,
    },
  }, "2026-08-29T07:00:01.000Z")

  assert.equal(result.rate_limit_signal, "observed")
  assert.deepEqual(result.rate_limits, {
    five_hour: {used_percentage: null, resets_at: null},
    seven_day: null,
    spend_limit: null,
  })
})

test("does not expose malformed callback input", () => {
  const result = normalizeStatusLineInput(null, "2026-08-29T07:00:02.000Z")

  assert.equal(result.outcome, "malformed_status_line_input")
  assert.equal(result.rate_limit_signal, "absent")
  assert.equal(result.rate_limits, null)
  assert.equal(Object.hasOwn(result, "session_id"), false)
})
