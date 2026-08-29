const assert = require("node:assert/strict")
const test = require("node:test")

const concurrentCodexRead = require("../tools/gate_0a/concurrent_codex_read")
const codexRestartRead = require("../tools/gate_0a/codex_restart_read")
const claudeStatuslineProbe = require("../tools/gate_0a/claude_statusline_probe")
const providerProbe = require("../tools/gate_0a/provider_probe")

// --- concurrent_codex_read.js / codex_restart_read.js: usable-window validation ---

for (const [name, mod] of [
  ["concurrent_codex_read", concurrentCodexRead],
  ["codex_restart_read", codexRestartRead],
]) {
  test(`${name}: an empty rate_limits object is not usable evidence`, () => {
    const observation = {outcome: "observed", rate_limits: {primary: null, secondary: null, rate_limit_reached_type: null}}
    assert.equal(mod.hasUsableEvidence(observation), false)
  })

  test(`${name}: a malformed window (missing used_percent) is not usable evidence`, () => {
    const observation = {
      outcome: "observed",
      rate_limits: {primary: {used_percent: null, window_duration_minutes: null, resets_at: null}, secondary: null},
    }
    assert.equal(mod.hasUsableEvidence(observation), false)
  })

  test(`${name}: an explicit rate-limit-reached refusal counts as usable evidence even with null windows`, () => {
    const observation = {
      outcome: "observed",
      rate_limits: {primary: null, secondary: null, rate_limit_reached_type: "rate_limit_reached"},
    }
    assert.equal(mod.hasUsableEvidence(observation), true)
  })

  test(`${name}: classifyEvidence requires every observation to be usable for live_observed`, () => {
    const usable = {outcome: "observed", rate_limits: {primary: {used_percent: 10}, secondary: null}}
    const unusableButObserved = {outcome: "observed", rate_limits: {primary: null, secondary: null}}
    const failed = {outcome: "executable_unavailable"}

    assert.equal(mod.classifyEvidence([usable, usable]), "live_observed")
    assert.equal(mod.classifyEvidence([usable, unusableButObserved]), "live_unverified")
    assert.equal(mod.classifyEvidence([usable, failed]), "error")
    assert.equal(mod.classifyEvidence([failed, failed]), "error")
    assert.equal(mod.classifyEvidence([unusableButObserved, unusableButObserved]), "live_unverified")
  })
}

// --- claude_statusline_probe.js: process/callback aggregation ---

test("classifyStatuslineEvidence: all completed with an observed callback is live_observed", () => {
  const processResults = [{label: "single", outcome: "completed", exit_status: 0}]
  const callbacks = [{rate_limit_signal: "observed"}]
  assert.equal(claudeStatuslineProbe.classifyStatuslineEvidence(processResults, callbacks), "live_observed")
})

test("classifyStatuslineEvidence: a completed process with zero callbacks is live_unverified, never live_observed", () => {
  const processResults = [{label: "single", outcome: "completed", exit_status: 0}]
  const callbacks = []
  assert.equal(claudeStatuslineProbe.classifyStatuslineEvidence(processResults, callbacks), "live_unverified")
})

test("classifyStatuslineEvidence: a failed process cannot be overridden by an earlier observed callback", () => {
  const processResults = [
    {label: "before_restart", outcome: "completed", exit_status: 0},
    {label: "after_restart", outcome: "process_error", exit_status: 1},
  ]
  const callbacks = [{probe_run: "before_restart", rate_limit_signal: "observed"}]
  assert.equal(claudeStatuslineProbe.classifyStatuslineEvidence(processResults, callbacks), "live_unverified")
})

test("classifyStatuslineEvidence: all processes failed is error", () => {
  const processResults = [
    {label: "session_a", outcome: "process_error", exit_status: 1},
    {label: "session_b", outcome: "timed_out", exit_status: null},
  ]
  assert.equal(claudeStatuslineProbe.classifyStatuslineEvidence(processResults, []), "error")
})

// --- provider_probe.js: usable-window validation ---

test("provider_probe: an empty codex rateLimits object is not a usable window", () => {
  const snapshot = providerProbe.rateLimitsSnapshot({rateLimits: {}})
  assert.equal(providerProbe.isUsableWindow(snapshot.primary), false)
  assert.equal(providerProbe.isUsableWindow(snapshot.secondary), false)
})

test("provider_probe: a malformed nested codex window (string usedPercent) is not usable", () => {
  const snapshot = providerProbe.windowSnapshot({usedPercent: "50"})
  assert.equal(snapshot.used_percent, null)
  assert.equal(providerProbe.isUsableWindow(snapshot), false)
})

test("provider_probe: an array in place of a codex window is not usable", () => {
  assert.equal(providerProbe.windowSnapshot([1, 2, 3]), null)
})

test("provider_probe: hasUsableRateLimitEvidence requires a real numeric window or an explicit refusal", () => {
  const emptyOutput = {
    initial_rate_limits: {rate_limits: {primary: null, secondary: null, rate_limit_reached_type: null}},
    post_turn_rate_limits: [],
  }
  assert.equal(providerProbe.hasUsableRateLimitEvidence(emptyOutput, []), false)

  const usableOutput = {
    initial_rate_limits: {rate_limits: {primary: {used_percent: 10}, secondary: null, rate_limit_reached_type: null}},
    post_turn_rate_limits: [],
  }
  assert.equal(providerProbe.hasUsableRateLimitEvidence(usableOutput, []), true)

  const refusalOutput = {
    initial_rate_limits: {rate_limits: {primary: null, secondary: null, rate_limit_reached_type: "rate_limit_reached"}},
    post_turn_rate_limits: [],
  }
  assert.equal(providerProbe.hasUsableRateLimitEvidence(refusalOutput, []), true)
})

test("provider_probe: an empty Claude rate_limits container is not a usable snapshot", () => {
  const snapshot = providerProbe.safeClaudeRateLimits({rate_limits: {}})
  assert.equal(providerProbe.hasUsableClaudeSnapshot(snapshot), false)
})

test("provider_probe: a malformed nested Claude window (string used_percentage) is not usable", () => {
  const window = providerProbe.safeClaudeWindow({used_percentage: "23.5"})
  assert.equal(window.used_percentage, null)
  assert.equal(providerProbe.isUsableClaudeWindow(window), false)
})

test("provider_probe: classifyClaudeHeadlessEvidence requires every probe to succeed, mixed success/failure is not live_observed", () => {
  const observedProbe = {outcome: "completed", rate_limit_signal: "observed"}
  const absentProbe = {outcome: "completed", rate_limit_signal: "absent"}
  const failedProbe = {outcome: "process_error", rate_limit_signal: "absent"}
  const refusalProbe = {outcome: "rate_limit_refusal", rate_limit_signal: "absent"}

  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([observedProbe, observedProbe], false), "live_observed")
  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([observedProbe, failedProbe], false), "error")
  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([observedProbe, absentProbe], false), "live_unverified")
  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([absentProbe, absentProbe], false), "live_unverified")
  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([failedProbe, failedProbe], false), "error")
})

test("provider_probe: classifyClaudeHeadlessEvidence preserves an explicit rate-limit refusal as valid evidence", () => {
  const refusalProbe = {outcome: "rate_limit_refusal", rate_limit_signal: "absent"}
  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([refusalProbe], false), "live_observed")
})

test("provider_probe: classifyClaudeHeadlessEvidence is error when the executable is missing regardless of probes", () => {
  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([], true), "error")
})

test("provider_probe: sanitizedCodexFailureEnvelope only contains the allowlisted fields", () => {
  const error = Object.assign(new Error("provider request failed"), {code: "RPC_ERROR", rpc_code: -32000})
  const envelope = providerProbe.sanitizedCodexFailureEnvelope("2026-08-29T00:00:00.000Z", error, 3)

  assert.deepEqual(Object.keys(envelope).sort(), [
    "evidence_status",
    "failure",
    "finished_at",
    "live_notification_count",
    "outcome",
    "provider",
    "schema_version",
    "started_at",
  ])
  assert.equal(envelope.evidence_status, "error")
  assert.equal(envelope.outcome, "failed")
  assert.deepEqual(envelope.failure, {category: "provider_rpc_error", code: -32000})
})
