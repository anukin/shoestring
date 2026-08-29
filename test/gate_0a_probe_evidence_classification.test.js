const assert = require("node:assert/strict")
const test = require("node:test")

const concurrentCodexRead = require("../tools/gate_0a/concurrent_codex_read")
const codexRestartRead = require("../tools/gate_0a/codex_restart_read")
const claudeStatuslineProbe = require("../tools/gate_0a/claude_statusline_probe")
const providerProbe = require("../tools/gate_0a/provider_probe")

const FORBIDDEN_SUBSTRINGS = [
  "usedPercent",
  "used_percent",
  "used_percentage",
  "rateLimits",
  "rate_limits",
  "handshake",
  "account",
  "turns",
  "callbacks",
  "observations",
  "headless_probes",
  "authentication",
  "Error:",
  "at Object.",
  "node_modules",
]

function assertNoForbiddenSubstrings(envelope) {
  const raw = JSON.stringify(envelope)
  for (const forbidden of FORBIDDEN_SUBSTRINGS) {
    assert.equal(raw.includes(forbidden), false, `envelope must not contain ${JSON.stringify(forbidden)}`)
  }
}

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

  test(`${name}: sanitizedFailureEnvelope only contains the allowlisted fields and never leaks a sibling's real snapshot`, () => {
    const observations = [
      {session: "session_a", outcome: "observed", observed_at: "2026-01-01T00:00:00.000Z", rate_limits: {primary: {used_percent: 42}, secondary: null}},
      {session: "session_b", outcome: "executable_unavailable"},
    ]
    const envelope = mod.sanitizedFailureEnvelope(observations)

    assert.deepEqual(Object.keys(envelope).sort(), [
      "evidence_status",
      "invocation_mode",
      "observed_at",
      "outcome",
      "probe_outcomes",
      "provider",
      "schema_version",
    ])
    assert.equal(envelope.evidence_status, "error")
    assert.deepEqual(envelope.probe_outcomes, ["observed", "executable_unavailable"])
    assertNoForbiddenSubstrings(envelope)
  })
}

// --- claude_statusline_probe.js: process/callback aggregation ---

test("classifyStatuslineEvidence: all completed with usable evidence for every required process is live_observed", () => {
  const processResults = [{label: "single", outcome: "completed", exit_status: 0}]
  const callbacks = [{probe_run: "single", rate_limit_signal: "observed"}]
  assert.equal(claudeStatuslineProbe.classifyStatuslineEvidence(processResults, callbacks), "live_observed")
})

test("classifyStatuslineEvidence: a completed process with zero callbacks is live_unverified, never live_observed", () => {
  const processResults = [{label: "single", outcome: "completed", exit_status: 0}]
  const callbacks = []
  assert.equal(claudeStatuslineProbe.classifyStatuslineEvidence(processResults, callbacks), "live_unverified")
})

test("classifyStatuslineEvidence: two completed processes with usable evidence for only one is live_unverified, never live_observed", () => {
  const processResults = [
    {label: "before_restart", outcome: "completed", exit_status: 0},
    {label: "after_restart", outcome: "completed", exit_status: 0},
  ]
  // Only "before_restart" produced a callback carrying usable evidence;
  // "after_restart" completed as a process but never reported one.
  const callbacks = [{probe_run: "before_restart", rate_limit_signal: "observed"}]
  assert.equal(claudeStatuslineProbe.classifyStatuslineEvidence(processResults, callbacks), "live_unverified")
})

test("classifyStatuslineEvidence: a callback tagged for a different probe_run does not count toward its sibling", () => {
  const processResults = [
    {label: "session_a", outcome: "completed", exit_status: 0},
    {label: "session_b", outcome: "completed", exit_status: 0},
  ]
  // Both callbacks are tagged "session_a" -- session_b never produced one.
  const callbacks = [
    {probe_run: "session_a", rate_limit_signal: "observed"},
    {probe_run: "session_a", rate_limit_signal: "observed"},
  ]
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

test("claude_statusline_probe: sanitizedStatuslineFailureEnvelope only contains the allowlisted fields", () => {
  const processResults = [
    {label: "session_a", outcome: "process_error", exit_status: 1},
    {label: "session_b", outcome: "timed_out", exit_status: null},
  ]
  const envelope = claudeStatuslineProbe.sanitizedStatuslineFailureEnvelope(processResults)

  assert.deepEqual(Object.keys(envelope).sort(), [
    "evidence_status",
    "invocation_mode",
    "observed_at",
    "outcome",
    "probe_outcomes",
    "provider",
    "schema_version",
    "tested_mode",
  ])
  assert.equal(envelope.evidence_status, "error")
  assert.deepEqual(envelope.probe_outcomes, ["process_error", "timed_out"])
  assertNoForbiddenSubstrings(envelope)
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

test("provider_probe: allRequiredCodexSnapshotsUsable requires every required snapshot, not just some", () => {
  const usableSnapshot = {primary: {used_percent: 10}, secondary: null, rate_limit_reached_type: null}
  const emptySnapshot = {primary: null, secondary: null, rate_limit_reached_type: null}
  const refusalSnapshot = {primary: null, secondary: null, rate_limit_reached_type: "rate_limit_reached"}

  const allUsable = {
    initial_rate_limits: {rate_limits: usableSnapshot},
    post_turn_rate_limits: [{rate_limits: usableSnapshot}, {rate_limits: usableSnapshot}],
  }
  assert.equal(providerProbe.allRequiredCodexSnapshotsUsable(allUsable), true)

  const mixed = {
    initial_rate_limits: {rate_limits: usableSnapshot},
    post_turn_rate_limits: [{rate_limits: emptySnapshot}, {rate_limits: usableSnapshot}],
  }
  assert.equal(providerProbe.allRequiredCodexSnapshotsUsable(mixed), false)

  const allEmpty = {
    initial_rate_limits: {rate_limits: emptySnapshot},
    post_turn_rate_limits: [{rate_limits: emptySnapshot}, {rate_limits: emptySnapshot}],
  }
  assert.equal(providerProbe.allRequiredCodexSnapshotsUsable(allEmpty), false)

  const allRefusal = {
    initial_rate_limits: {rate_limits: refusalSnapshot},
    post_turn_rate_limits: [{rate_limits: refusalSnapshot}, {rate_limits: refusalSnapshot}],
  }
  assert.equal(providerProbe.allRequiredCodexSnapshotsUsable(allRefusal), true)
})

test("provider_probe: allRequiredCodexSnapshotsUsable ignores incidental push notifications, only initial/post-turn reads are required", () => {
  const usableSnapshot = {primary: {used_percent: 10}, secondary: null, rate_limit_reached_type: null}
  const emptySnapshot = {primary: null, secondary: null, rate_limit_reached_type: null}

  // Both required reads are usable; an unrelated push notification being
  // empty/malformed must not affect the aggregate claim either way.
  const output = {
    initial_rate_limits: {rate_limits: usableSnapshot},
    post_turn_rate_limits: [{rate_limits: usableSnapshot}],
  }
  assert.equal(providerProbe.allRequiredCodexSnapshotsUsable(output), true)
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

test("provider_probe: selectReportedClaudeRateLimits reports the actual usable snapshot, not an earlier malformed one", () => {
  const messages = [
    {type: "assistant", rate_limits: {}},
    {type: "system", rate_limits: {five_hour: {used_percentage: "not-a-number"}}},
    {type: "result", rate_limits: {five_hour: {used_percentage: 30, resets_at: 111}}},
  ]

  const reported = providerProbe.selectReportedClaudeRateLimits(messages)

  assert.equal(reported.rate_limit_signal, "observed")
  assert.deepEqual(reported.rate_limits, {
    five_hour: {used_percentage: 30, resets_at: 111},
    seven_day: null,
    spend_limit: null,
  })
})

test("provider_probe: selectReportedClaudeRateLimits falls back to the first parsed snapshot when none are usable", () => {
  const messages = [{type: "assistant", rate_limits: {five_hour: null, seven_day: {}}}]
  const reported = providerProbe.selectReportedClaudeRateLimits(messages)

  assert.equal(reported.rate_limit_signal, "absent")
  assert.deepEqual(reported.rate_limits, {
    five_hour: null,
    seven_day: {used_percentage: null, resets_at: null},
    spend_limit: null,
  })
})

test("provider_probe: classifyClaudeHeadlessEvidence requires completion AND an observed signal for every probe", () => {
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

test("provider_probe: classifyClaudeHeadlessEvidence treats a failed process as an error even if its own signal was marked observed", () => {
  const inconsistentFailedProbe = {outcome: "process_error", rate_limit_signal: "observed"}
  const observedProbe = {outcome: "completed", rate_limit_signal: "observed"}

  // Failure takes precedence: a process-level failure must never be
  // overridden into live_observed by an inconsistently-marked signal, nor
  // by a sibling probe that genuinely observed evidence.
  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([inconsistentFailedProbe], false), "error")
  assert.equal(providerProbe.classifyClaudeHeadlessEvidence([observedProbe, inconsistentFailedProbe], false), "error")
})

test("provider_probe: classifyClaudeHeadlessEvidence preserves an explicit rate-limit refusal as valid evidence without requiring completion", () => {
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

test("provider_probe: sanitizedClaudePreflightFailureEnvelope only contains the allowlisted fields and never leaks headless probe data", () => {
  const headlessProbes = [
    {mode: "json", outcome: "completed", rate_limit_signal: "observed", rate_limits: {five_hour: {used_percentage: 40, resets_at: 111}}},
    {mode: "stream-json", outcome: "process_error", rate_limit_signal: "absent", rate_limits: null},
  ]
  const envelope = providerProbe.sanitizedClaudePreflightFailureEnvelope(false, headlessProbes)

  assert.deepEqual(Object.keys(envelope).sort(), [
    "evidence_status",
    "invocation_mode",
    "live_capacity_probe",
    "observed_at",
    "outcome",
    "probe_outcomes",
    "provider",
    "schema_version",
  ])
  assert.equal(envelope.evidence_status, "error")
  assert.deepEqual(envelope.probe_outcomes, ["completed", "process_error"])
  assertNoForbiddenSubstrings(envelope)
})

test("provider_probe: sanitizedTopLevelFailureEnvelope only contains the allowlisted fields", () => {
  const envelope = providerProbe.sanitizedTopLevelFailureEnvelope("codex")

  assert.deepEqual(Object.keys(envelope).sort(), [
    "evidence_status",
    "observed_at",
    "outcome",
    "provider",
    "schema_version",
  ])
  assert.equal(envelope.evidence_status, "error")
  assert.equal(envelope.provider, "codex")
})

for (const provider of ["codex", "claude"]) {
  test(`provider_probe: runProviderEntrypoint(${provider}) emits a fresh sanitized envelope and exits non-zero on an unexpected rejection, without leaking the error message or stack`, async () => {
    const originalWrite = process.stdout.write
    const originalExitCode = process.exitCode
    let captured = ""
    process.stdout.write = chunk => {
      captured += chunk
      return true
    }

    try {
      await providerProbe.runProviderEntrypoint(
        provider,
        () => Promise.reject(new Error(`unexpected ${provider} rejection with a sensitive detail and a stack trace`)),
      )
    } finally {
      process.stdout.write = originalWrite
    }

    const exitCode = process.exitCode
    process.exitCode = originalExitCode

    assert.equal(exitCode, 1)
    const output = JSON.parse(captured)
    assert.deepEqual(Object.keys(output).sort(), [
      "evidence_status",
      "observed_at",
      "outcome",
      "provider",
      "schema_version",
    ])
    assert.equal(output.evidence_status, "error")
    assert.equal(output.provider, provider)
    assert.equal(captured.includes("unexpected"), false)
    assert.equal(captured.includes("sensitive"), false)
    assert.equal(captured.includes("Error"), false)
    assert.equal(captured.includes("at "), false)
  })
}
