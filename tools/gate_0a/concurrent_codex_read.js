#!/usr/bin/env node

const {execFileSync, spawn} = require("node:child_process")
const readline = require("node:readline")

if (require.main === module) {
  Promise.all([readSnapshot("session_a"), readSnapshot("session_b")])
    .then(observations => {
      const evidenceStatus = classifyEvidence(observations)
      if (evidenceStatus === "error") process.exitCode = 1

      process.stdout.write(`${JSON.stringify({
        schema_version: 1,
        evidence_status: evidenceStatus,
        provider: "codex",
        cli_version: versionOf("codex"),
        runtime: {
          os: process.platform,
          architecture: process.arch,
          node_version: process.version,
        },
        invocation_mode: "two concurrent codex app-server --stdio connections",
        observed_at: new Date().toISOString(),
        observations,
        comparison: compare(observations),
        limitations: [
          "The two connections read the same account without starting model turns.",
          "This is one point-in-time concurrency sample, not a universal synchronization guarantee.",
          "Opaque identifiers, paths, and all unrelated payload fields were discarded.",
        ],
      }, null, 2)}\n`)
    })
    .catch(_error => {
      process.stdout.write(`${JSON.stringify({
        schema_version: 1,
        evidence_status: "error",
        provider: "codex",
        invocation_mode: "two concurrent codex app-server --stdio connections",
        outcome: "probe_failed",
        failure: "process_or_protocol_error",
      }, null, 2)}\n`)
      process.exitCode = 1
    })
}

function isUsableWindow(window) {
  return !!window && typeof window.used_percent === "number"
}

function hasUsableEvidence(observation) {
  if (observation.outcome !== "observed") return false
  const rateLimits = observation.rate_limits
  if (!rateLimits) return false

  return isUsableWindow(rateLimits.primary) ||
    isUsableWindow(rateLimits.secondary) ||
    (typeof rateLimits.rate_limit_reached_type === "string" && rateLimits.rate_limit_reached_type !== "")
}

function classifyEvidence(observations) {
  if (observations.length > 0 && observations.every(hasUsableEvidence)) return "live_observed"
  if (observations.some(observation => observation.outcome !== "observed")) return "error"
  return "live_unverified"
}

function versionOf(command) {
  try {
    return execFileSync(command, ["--version"], {encoding: "utf8"})
      .trim()
      .split(/\r?\n/)[0]
  } catch (_error) {
    return null
  }
}

function numberOrNull(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function integerOrNull(value) {
  return Number.isInteger(value) ? value : null
}

function safeWindow(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null

  return {
    used_percent: numberOrNull(value.usedPercent),
    window_duration_minutes: integerOrNull(value.windowDurationMins),
    resets_at: integerOrNull(value.resetsAt),
  }
}

function safeSnapshot(result) {
  const rateLimits = result && result.rateLimits

  return {
    primary: safeWindow(rateLimits && rateLimits.primary),
    secondary: safeWindow(rateLimits && rateLimits.secondary),
    rate_limit_reached_type: rateLimits && typeof rateLimits.rateLimitReachedType === "string"
      ? rateLimits.rateLimitReachedType
      : null,
    spend_control_reached: typeof (rateLimits && rateLimits.spendControlReached) === "boolean"
      ? rateLimits.spendControlReached
      : null,
    plan_type: rateLimits && typeof rateLimits.planType === "string" ? rateLimits.planType : null,
  }
}

function readSnapshot(label) {
  return new Promise(resolve => {
    const child = spawn("codex", ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "ignore"],
    })
    const lines = readline.createInterface({input: child.stdout})
    const pending = new Map()
    let nextId = 1
    let settled = false

    const finish = observation => {
      if (settled) return
      settled = true
      for (const entry of pending.values()) clearTimeout(entry.timer)
      pending.clear()
      lines.close()
      child.kill("SIGTERM")
      resolve(observation)
    }

    const failure = category => {
      for (const entry of pending.values()) {
        clearTimeout(entry.timer)
        entry.reject({code: category})
      }

      finish({session: label, outcome: category})
    }

    child.once("error", _error => failure("executable_unavailable"))
    child.stdin.once("error", _error => failure("process_io_error"))

    lines.on("line", line => {
      let message
      try {
        message = JSON.parse(line)
      } catch (_error) {
        return
      }

      const entry = pending.get(message && message.id)
      if (!entry) return
      clearTimeout(entry.timer)
      pending.delete(message.id)

      if (message.error) {
        entry.reject({code: "provider_rpc_error"})
      } else if (!message.result || typeof message.result !== "object") {
        entry.reject({code: "malformed_provider_response"})
      } else {
        entry.resolve(message.result)
      }
    })

    const request = (method, params) => new Promise((resolveRequest, rejectRequest) => {
      const id = nextId++
      const timer = setTimeout(() => {
        pending.delete(id)
        rejectRequest({code: "timed_out"})
      }, 30000)
      pending.set(id, {resolve: resolveRequest, reject: rejectRequest, timer})

      try {
        child.stdin.write(`${JSON.stringify({method, id, params})}\n`)
      } catch (_error) {
        clearTimeout(timer)
        pending.delete(id)
        rejectRequest({code: "process_io_error"})
      }
    })

    ;(async () => {
      try {
        await request("initialize", {
          clientInfo: {
            name: "shoestring_gate_0a_concurrent",
            title: "Shoestring Gate 0A concurrent read",
            version: "0.1.0",
          },
        })
        child.stdin.write('{"method":"initialized","params":{}}\n')
        const result = await request("account/rateLimits/read", {})
        finish({
          session: label,
          outcome: "observed",
          observed_at: new Date().toISOString(),
          rate_limits: safeSnapshot(result),
        })
      } catch (error) {
        finish({session: label, outcome: error && error.code || "process_or_protocol_error"})
      }
    })()
  })
}

function compare(observations) {
  if (observations.length !== 2) return "inconclusive"
  if (observations.some(observation => observation.outcome !== "observed")) return "inconclusive"

  return JSON.stringify(observations[0].rate_limits) === JSON.stringify(observations[1].rate_limits)
    ? "identical"
    : "divergent"
}

module.exports = {isUsableWindow, hasUsableEvidence, classifyEvidence}
