#!/usr/bin/env node

const {spawn} = require("node:child_process")
const readline = require("node:readline")

Promise.all([readSnapshot("session_a"), readSnapshot("session_b")])
  .then(observations => {
    process.stdout.write(JSON.stringify({
      schema_version: 1,
      evidence_status: "live_observed",
      provider: "codex",
      invocation_mode: "two concurrent codex app-server --stdio connections",
      observed_at: new Date().toISOString(),
      observations,
      comparison: compare(observations),
      limitations: [
        "The two connections read the same account without starting model turns.",
        "This is one point-in-time concurrency sample, not a universal synchronization guarantee.",
        "Opaque identifiers, paths, and all unrelated payload fields were discarded.",
      ],
    }, null, 2) + "\n")
  })
  .catch(_error => {
    process.stderr.write(JSON.stringify({provider: "codex", outcome: "concurrent_probe_failed"}) + "\n")
    process.exitCode = 1
  })

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
  return new Promise((resolve, reject) => {
    const child = spawn("codex", ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "ignore"],
    })
    const lines = readline.createInterface({input: child.stdout})
    let nextId = 1
    let settled = false

    const finish = (result, error) => {
      if (settled) return
      settled = true
      lines.close()
      child.kill("SIGTERM")
      error ? reject(error) : resolve(result)
    }

    const request = (method, params) => {
      const id = nextId++
      child.stdin.write(`${JSON.stringify({method, id, params})}\n`)
      return new Promise((resolveRequest, rejectRequest) => {
        const timer = setTimeout(() => rejectRequest(new Error("request timed out")), 30000)
        const onLine = line => {
          let message
          try {
            message = JSON.parse(line)
          } catch (_error) {
            return
          }
          if (message.id !== id) return
          clearTimeout(timer)
          lines.off("line", onLine)
          if (message.error) rejectRequest(new Error("rpc error"))
          else resolveRequest(message.result || {})
        }
        lines.on("line", onLine)
      })
    }

    ;(async () => {
      await request("initialize", {
        clientInfo: {
          name: "shoestring_gate_0a_concurrent",
          title: "Shoestring Gate 0A concurrent read",
          version: "0.1.0",
        },
      })
      child.stdin.write('{"method":"initialized","params":{}}\n')
      const result = await request("account/rateLimits/read", {})
      finish({session: label, rate_limits: safeSnapshot(result)}, null)
    })().catch(error => finish({session: label}, error))
  })
}

function compare(observations) {
  if (observations.length !== 2) return "inconclusive"
  return JSON.stringify(observations[0].rate_limits) === JSON.stringify(observations[1].rate_limits)
    ? "identical"
    : "divergent"
}
