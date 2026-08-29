#!/usr/bin/env node

const fs = require("node:fs")

const CAPTURE_FILE = process.env.SHOESTRING_GATE_0A_CAPTURE_FILE
const RUN_LABEL = process.env.SHOESTRING_GATE_0A_RUN_LABEL || null

if (require.main === module) {
  collectInput().then(input => {
    const snapshot = normalizeStatusLineInput(input, new Date().toISOString())

    if (CAPTURE_FILE) {
      fs.appendFileSync(CAPTURE_FILE, `${JSON.stringify(snapshot)}\n`, {encoding: "utf8"})
    }

    process.stdout.write(`${JSON.stringify(snapshot)}\n`)
  }).catch(_error => {
    const snapshot = failureSnapshot(new Date().toISOString())

    if (CAPTURE_FILE) {
      try {
        fs.appendFileSync(CAPTURE_FILE, `${JSON.stringify(snapshot)}\n`, {encoding: "utf8"})
      } catch (_captureError) {
        // The status line must not expose a path or stack trace on capture failure.
      }
    }

    process.stdout.write(`${JSON.stringify(snapshot)}\n`)
  })
}

function collectInput() {
  return new Promise((resolve, reject) => {
    let input = ""

    process.stdin.setEncoding("utf8")
    process.stdin.on("data", chunk => { input += chunk })
    process.stdin.on("end", () => {
      try {
        resolve(JSON.parse(input))
      } catch (_error) {
        reject(new Error("malformed_status_line_input"))
      }
    })
    process.stdin.on("error", reject)
  })
}

function normalizeStatusLineInput(input, observedAt) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return failureSnapshot(observedAt)
  }

  const rateLimits = input.rate_limits
  const rateLimitSignal = rateLimits && typeof rateLimits === "object" && !Array.isArray(rateLimits)
    ? "observed"
    : "absent"

  return {
    schema_version: 1,
    evidence_status: rateLimitSignal === "observed" ? "live_observed" : "live_unverified",
    provider: "claude",
    source_event: "status_line_callback",
    probe_run: RUN_LABEL,
    observed_at: observedAt,
    cli_version: typeof input.version === "string" ? input.version : null,
    rate_limit_signal: rateLimitSignal,
    rate_limits: safeRateLimits(rateLimits),
  }
}

function failureSnapshot(observedAt) {
  return {
    schema_version: 1,
    evidence_status: "sanitized_probe_error",
    provider: "claude",
    source_event: "status_line_callback",
    probe_run: RUN_LABEL,
    observed_at: observedAt,
    cli_version: null,
    rate_limit_signal: "absent",
    rate_limits: null,
    outcome: "malformed_status_line_input",
  }
}

function safeRateLimits(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null

  return {
    five_hour: safeWindow(value.five_hour),
    seven_day: safeWindow(value.seven_day),
    spend_limit: safeWindow(value.spend_limit),
  }
}

function safeWindow(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null

  return {
    used_percentage: percentageOrNull(value.used_percentage),
    resets_at: integerOrNull(value.resets_at),
  }
}

function percentageOrNull(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100
    ? value
    : null
}

function integerOrNull(value) {
  return Number.isInteger(value) ? value : null
}

module.exports = {normalizeStatusLineInput}
