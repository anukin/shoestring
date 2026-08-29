#!/usr/bin/env node

const {execFileSync, spawn} = require("node:child_process")
const readline = require("node:readline")

if (require.main === module) {
  readAfterRestart()
    .then(output => {
      if (output.evidence_status === "error") process.exitCode = 1
      process.stdout.write(`${JSON.stringify(output, null, 2)}\n`)
    })
    .catch(_error => {
      process.stdout.write(`${JSON.stringify({
        schema_version: 1,
        evidence_status: "error",
        provider: "codex",
        invocation_mode: "codex app-server --stdio process restart",
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

async function readAfterRestart() {
  const first = await readSnapshot("before_restart")
  const second = await readSnapshot("after_restart")
  const evidenceStatus = classifyEvidence([first, second])

  return {
    schema_version: 1,
    evidence_status: evidenceStatus,
    provider: "codex",
    cli_version: versionOf("codex"),
    runtime: {
      os: process.platform,
      architecture: process.arch,
      node_version: process.version,
    },
    invocation_mode: "codex app-server --stdio process restart",
    observed_at: new Date().toISOString(),
    observations: [first, second],
    comparison: compare(first, second),
    limitations: [
      "Each observation is a fresh account/rate-limit read after a new App Server process was started.",
      "This is a restart consistency sample, not a guarantee about future process or provider behavior.",
      "Opaque identifiers, paths, and unrelated payload fields were discarded.",
    ],
  }
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

    const processFailure = code => {
      for (const entry of pending.values()) {
        clearTimeout(entry.timer)
      }
      finish({session: label, outcome: code})
    }

    child.once("error", _error => processFailure("executable_unavailable"))
    child.stdin.once("error", _error => processFailure("process_io_error"))

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
        finish({session: label, outcome: "provider_rpc_error"})
      } else if (!message.result || typeof message.result !== "object") {
        finish({session: label, outcome: "malformed_provider_response"})
      } else if (entry.method === "account/rateLimits/read") {
        finish({
          session: label,
          outcome: "observed",
          observed_at: new Date().toISOString(),
          rate_limits: safeSnapshot(message.result),
        })
      } else {
        entry.resolve(message.result)
      }
    })

    const request = (method, params) => new Promise((resolveRequest, rejectRequest) => {
      const id = nextId++
      const timer = setTimeout(() => {
        pending.delete(id)
        rejectRequest({code: "TIMEOUT"})
      }, 30000)
      pending.set(id, {method, resolve: resolveRequest, reject: rejectRequest, timer})

      try {
        child.stdin.write(`${JSON.stringify({method, id, params})}\n`)
      } catch (_error) {
        clearTimeout(timer)
        pending.delete(id)
        rejectRequest({code: "PROCESS_IO_ERROR"})
      }
    })

    ;(async () => {
      try {
        await request("initialize", {
          clientInfo: {
            name: "shoestring_gate_0a_restart",
            title: "Shoestring Gate 0A restart read",
            version: "0.1.0",
          },
        })
        child.stdin.write('{"method":"initialized","params":{}}\n')
        const result = await request("account/rateLimits/read", {})
        if (!settled) {
          finish({
            session: label,
            outcome: "observed",
            observed_at: new Date().toISOString(),
            rate_limits: safeSnapshot(result),
          })
        }
      } catch (error) {
        if (!settled) {
          const outcome = error && error.code === "TIMEOUT"
            ? "timed_out"
            : error && error.code === "PROCESS_IO_ERROR"
              ? "process_io_error"
              : "provider_rpc_error"
          finish({session: label, outcome})
        }
      }
    })()
  })
}

module.exports = {isUsableWindow, hasUsableEvidence, classifyEvidence}

function compare(first, second) {
  if (first.outcome !== "observed" || second.outcome !== "observed") return "inconclusive"
  return JSON.stringify(first.rate_limits) === JSON.stringify(second.rate_limits)
    ? "identical"
    : "divergent"
}
