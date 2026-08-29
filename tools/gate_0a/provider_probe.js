#!/usr/bin/env node

const {execFileSync, spawn, spawnSync} = require("node:child_process")
const readline = require("node:readline")

const PROVIDER = process.argv[2]

if (require.main === module) {
  if (PROVIDER === "codex") {
    runCodexProbe().catch(_error => {
      process.exitCode = 1
    })
  } else if (PROVIDER === "claude") {
    runClaudePreflight().catch(_error => {
      process.exitCode = 1
    })
  } else {
    console.error(JSON.stringify({
      provider: PROVIDER || null,
      outcome: "unsupported_probe_argument",
      supported_arguments: ["codex", "claude"],
    }))
    process.exitCode = 2
  }
}

function now() {
  return new Date().toISOString()
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

function windowSnapshot(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null

  return {
    used_percent: numberOrNull(value.usedPercent),
    window_duration_minutes: integerOrNull(value.windowDurationMins),
    resets_at: integerOrNull(value.resetsAt),
  }
}

function rateLimitsSnapshot(result) {
  const value = result && result.rateLimits
  const resetCredits = result && result.rateLimitResetCredits
  const multiBucket = result && result.rateLimitsByLimitId
  const credits = resetCredits && resetCredits.credits

  return {
    primary: windowSnapshot(value && value.primary),
    secondary: windowSnapshot(value && value.secondary),
    rate_limit_reached_type: value && typeof value.rateLimitReachedType === "string"
      ? value.rateLimitReachedType
      : null,
    spend_control_reached: typeof (value && value.spendControlReached) === "boolean"
      ? value.spendControlReached
      : null,
    plan_type: value && typeof value.planType === "string" ? value.planType : null,
    reset_credit_count: resetCredits && Number.isInteger(resetCredits.availableCount)
      ? resetCredits.availableCount
      : null,
    reset_credit_detail_state: credits === undefined
      ? "absent"
      : credits === null
      ? "unavailable"
      : Array.isArray(credits)
        ? credits.length === 0 ? "empty" : "present_redacted"
        : "unknown",
    multi_bucket_keys: multiBucket && typeof multiBucket === "object" && !Array.isArray(multiBucket)
      ? Object.keys(multiBucket).sort()
      : [],
  }
}

function isUsableWindow(window) {
  return !!window && typeof window.used_percent === "number"
}

function isUsableClaudeWindow(window) {
  return !!window && typeof window.used_percentage === "number"
}

function hasUsableClaudeSnapshot(snapshot) {
  return !!snapshot && (
    isUsableClaudeWindow(snapshot.five_hour) ||
    isUsableClaudeWindow(snapshot.seven_day) ||
    isUsableClaudeWindow(snapshot.spend_limit)
  )
}

function classifyClaudeHeadlessEvidence(headlessProbes, executableMissing) {
  if (executableMissing) return "error"

  const anyProcessFailed = headlessProbes.some(probe =>
    ["process_terminated", "timed_out", "process_error"].includes(probe.outcome)
  )
  const allSignaled = headlessProbes.length > 0 &&
    headlessProbes.every(probe => probe.rate_limit_signal === "observed" || probe.outcome === "rate_limit_refusal")

  if (allSignaled) return "live_observed"
  if (anyProcessFailed) return "error"
  return "live_unverified"
}

function turnCompletion(message) {
  const turn = message && message.params && message.params.turn
  return {
    status: turn && typeof turn.status === "string" ? turn.status : "unknown",
  }
}

async function runClaudePreflight() {
  const authStatus = spawnSync("claude", ["auth", "status", "--json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  })
  let status = {}

  try {
    status = JSON.parse(authStatus.stdout || "{}")
  } catch (_error) {
    status = {}
  }

  const authentication = {
    logged_in: typeof status.loggedIn === "boolean" ? status.loggedIn : null,
    auth_method: typeof status.authMethod === "string" ? status.authMethod : null,
  }
  const executableMissing = authStatus.error != null
  const headlessProbes = authentication.logged_in ? runClaudeHeadlessProbes() : []
  const evidenceStatus = classifyClaudeHeadlessEvidence(headlessProbes, executableMissing)

  const output = {
    schema_version: 1,
    evidence_status: evidenceStatus,
    provider: "claude",
    cli_version: versionOf("claude"),
    runtime: {
      os: process.platform,
      architecture: process.arch,
      node_version: process.version,
    },
    observed_at: now(),
    invocation_mode: "claude auth status --json",
    authentication,
    live_capacity_probe: executableMissing
      ? "blocked_executable_unavailable"
      : authentication.logged_in
        ? "authenticated_headless_probe"
        : "blocked_not_authenticated",
    headless_probes: headlessProbes,
    limitations: authentication.logged_in
      ? [
        "Claude status-line callback delivery was not asserted by the headless probes.",
        "No credential, account identifier, authentication path, prompt, or response payload was retained.",
      ]
      : [
        "No Claude model request or status-line callback was attempted after the failed authentication preflight.",
        "No credential, account identifier, authentication path, prompt, or response payload was retained.",
      ],
  }

  if (evidenceStatus === "error") process.exitCode = 1
  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`)
}

function runClaudeHeadlessProbes() {
  return [
    runClaudeHeadlessProbe("json", ["--output-format", "json"]),
    runClaudeHeadlessProbe("stream-json", ["--output-format", "stream-json"]),
  ]
}

function runClaudeHeadlessProbe(mode, formatArgs) {
  const startedAt = Date.now()
  const result = spawnSync("claude", [
    "--print",
    "--no-session-persistence",
    "--permission-mode",
    "dontAsk",
    ...formatArgs,
    "Reply with exactly OK.",
  ], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 120000,
    maxBuffer: 4 * 1024 * 1024,
  })
  const messages = parseClaudeOutput(mode, result.stdout || "")
  const rateLimitSnapshots = messages
    .map(message => safeClaudeRateLimits(message))
    .filter(snapshot => snapshot !== null)
  const usableSnapshots = rateLimitSnapshots.filter(hasUsableClaudeSnapshot)

  return {
    mode,
    invocation_mode: `claude --print --no-session-persistence --output-format ${mode}`,
    outcome: classifyClaudeOutcome(result, messages),
    exit_status: Number.isInteger(result.status) ? result.status : null,
    signal: typeof result.signal === "string" ? result.signal : null,
    elapsed_ms: Date.now() - startedAt,
    message_type_counts: countClaudeMessageTypes(messages),
    rate_limit_signal: usableSnapshots.length === 0
      ? "absent"
      : "observed",
    rate_limits: rateLimitSnapshots[0] || null,
  }
}

function parseClaudeOutput(mode, stdout) {
  if (mode === "json") {
    try {
      const value = JSON.parse(stdout)
      return value && typeof value === "object" ? [value] : []
    } catch (_error) {
      return []
    }
  }

  return stdout
    .split(/\r?\n/)
    .map(line => {
      try {
        return JSON.parse(line)
      } catch (_error) {
        return null
      }
    })
    .filter(value => value && typeof value === "object")
}

function classifyClaudeOutcome(result, messages) {
  if (result.signal) return "process_terminated"
  if (result.error && result.error.code === "ETIMEDOUT") return "timed_out"

  const errorResult = messages.find(message => message.is_error === true)
  if (errorResult) {
    return ["rate_limit", "rate_limit_reached"].includes(errorResult.subtype)
      ? "rate_limit_refusal"
      : "provider_error"
  }

  if (messages.some(message => message.type === "result" && message.subtype === "success")) {
    return "completed"
  }

  return result.status === 0 ? "no_structured_result" : "process_error"
}

function countClaudeMessageTypes(messages) {
  const knownTypes = new Set(["assistant", "rate_limit_event", "result", "stream_event", "system", "user"])

  return messages.reduce((counts, message) => {
    const type = knownTypes.has(message.type) ? message.type : "other"
    counts[type] = (counts[type] || 0) + 1
    return counts
  }, {})
}

function safeClaudeRateLimits(message) {
  const value = message && message.rate_limits
  if (!value || typeof value !== "object" || Array.isArray(value)) return null

  return {
    five_hour: safeClaudeWindow(value.five_hour),
    seven_day: safeClaudeWindow(value.seven_day),
    spend_limit: safeClaudeWindow(value.spend_limit),
  }
}

function safeClaudeWindow(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null

  return {
    used_percentage: numberOrNull(value.used_percentage),
    resets_at: integerOrNull(value.resets_at),
  }
}

async function runCodexProbe() {
  const startedAt = now()
  const child = spawn("codex", ["app-server", "--stdio"], {
    stdio: ["pipe", "pipe", "ignore"],
  })
  const pending = new Map()
  const notificationWaiters = []
  const rateLimitUpdates = []
  const accountUpdates = []
  const turns = []
  let nextId = 1

  const output = {
    schema_version: 1,
    evidence_status: "live_unverified",
    provider: "codex",
    cli_version: versionOf("codex"),
    runtime: {
      os: process.platform,
      architecture: process.arch,
      node_version: process.version,
    },
    started_at: startedAt,
    invocation_mode: "codex app-server --stdio",
    tested_modes: [
      "initialize handshake",
      "account/read with refreshToken=false",
      "account/rateLimits/read before a model response",
      "two ephemeral-thread no-tool turns",
      "account/rateLimits/read after each model response",
    ],
    handshake: null,
    account: null,
    initial_rate_limits: null,
    post_turn_rate_limits: [],
    rate_limit_updates: rateLimitUpdates,
    account_updates: accountUpdates,
    turns,
    limitations: [
      "This is a point-in-time observation, not a reservation or provider guarantee.",
      "No hard limit was deliberately induced.",
      "Opaque identifiers, paths, prompts, response text, and other payload fields were discarded.",
    ],
  }

  const lines = readline.createInterface({input: child.stdout})

  const rejectPending = error => {
    for (const [id, entry] of pending) {
      clearTimeout(entry.timer)
      pending.delete(id)
      entry.reject(error)
    }

    for (const waiter of notificationWaiters.splice(0)) {
      clearTimeout(waiter.timer)
      waiter.reject(error)
    }
  }

  const onProcessError = _error => {
    const error = new Error("provider process unavailable")
    error.code = "SPAWN_ERROR"
    rejectPending(error)
  }

  child.on("error", onProcessError)
  child.stdin.on("error", onProcessError)
  child.stdout.on("error", onProcessError)
  lines.on("line", line => {
    let message
    try {
      message = JSON.parse(line)
    } catch (_error) {
      return
    }

    if (message && message.id !== undefined && pending.has(message.id)) {
      const entry = pending.get(message.id)
      pending.delete(message.id)
      clearTimeout(entry.timer)

      if (message.error) {
        const error = new Error("provider request failed")
        error.code = "RPC_ERROR"
        error.rpc_code = Number.isInteger(message.error.code) ? message.error.code : null
        entry.reject(error)
      } else {
        entry.resolve(message)
      }
      return
    }

    if (message && message.method === "account/rateLimits/updated") {
      rateLimitUpdates.push({
        observed_at: now(),
        rate_limits: rateLimitsSnapshot(message.params || {}),
      })
    }

    if (message && message.method === "account/updated") {
      const params = message.params || {}
      accountUpdates.push({
        observed_at: now(),
        auth_mode: typeof params.authMode === "string" ? params.authMode : null,
        plan_type: typeof params.planType === "string" ? params.planType : null,
      })
    }

    for (let index = notificationWaiters.length - 1; index >= 0; index -= 1) {
      const waiter = notificationWaiters[index]
      if (waiter.predicate(message)) {
        notificationWaiters.splice(index, 1)
        clearTimeout(waiter.timer)
        waiter.resolve(message)
      }
    }
  })

  const request = (method, params) => {
    const id = nextId++

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id)
        const error = new Error("request timed out")
        error.code = "TIMEOUT"
        reject(error)
      }, 30000)

      pending.set(id, {resolve, reject, timer})

      try {
        child.stdin.write(`${JSON.stringify({method, id, params})}\n`)
      } catch (_error) {
        clearTimeout(timer)
        pending.delete(id)
        const processError = new Error("provider process unavailable")
        processError.code = "SPAWN_ERROR"
        reject(processError)
      }
    })
  }

  const notify = (method, params) => {
    child.stdin.write(`${JSON.stringify({method, params})}\n`)
  }

  const waitForNotification = predicate => new Promise((resolve, reject) => {
    const waiter = {predicate, timer: null, reject, resolve}
    waiter.timer = setTimeout(() => {
      const index = notificationWaiters.indexOf(waiter)
      if (index >= 0) notificationWaiters.splice(index, 1)
      const error = new Error("notification timed out")
      error.code = "TIMEOUT"
      reject(error)
    }, 30000)
    notificationWaiters.push(waiter)
  })

  const checkedRequest = async (method, params) => {
    const message = await request(method, params)
    if (message.error) throw Object.assign(new Error("provider request failed"), message.error)
    return message.result || {}
  }

  try {
    const initialize = await checkedRequest("initialize", {
      clientInfo: {
        name: "shoestring_gate_0a",
        title: "Shoestring Gate 0A probe",
        version: "0.1.0",
      },
    })
    output.handshake = {
      result: "ok",
      platform_family: typeof initialize.platformFamily === "string" ? initialize.platformFamily : null,
      platform_os: typeof initialize.platformOs === "string" ? initialize.platformOs : null,
      result_keys: Object.keys(initialize).sort(),
    }
    notify("initialized", {})

    const account = await checkedRequest("account/read", {refreshToken: false})
    const accountValue = account.account || {}
    output.account = {
      type: typeof accountValue.type === "string" ? accountValue.type : null,
      plan_type: typeof accountValue.planType === "string" ? accountValue.planType : null,
      requires_openai_auth: typeof account.requiresOpenaiAuth === "boolean"
        ? account.requiresOpenaiAuth
        : null,
    }

    const initialRateLimits = await checkedRequest("account/rateLimits/read", {})
    output.initial_rate_limits = {
      observed_at: now(),
      rate_limits: rateLimitsSnapshot(initialRateLimits),
    }

    const thread = await checkedRequest("thread/start", {
      ephemeral: true,
      cwd: process.cwd(),
      approvalPolicy: "never",
    })
    const threadId = thread.thread && thread.thread.id
    if (typeof threadId !== "string") throw new Error("thread did not return an id")

    for (let turnNumber = 1; turnNumber <= 2; turnNumber += 1) {
      const turnStartedAt = Date.now()
      const turn = await checkedRequest("turn/start", {
        threadId,
        input: [{type: "text", text: "Reply with exactly OK."}],
        approvalPolicy: "never",
      })
      const turnId = turn.turn && turn.turn.id
      if (typeof turnId !== "string") throw new Error("turn did not return an id")

      const completion = await waitForNotification(message => {
        if (!message || message.method !== "turn/completed") return false
        const params = message.params || {}
        const completedTurn = params.turn || {}
        return completedTurn.id === turnId || params.turnId === turnId
      })
      const completedAt = now()
      turns.push({
        turn_number: turnNumber,
        status: turnCompletion(completion).status,
        elapsed_ms: Date.now() - turnStartedAt,
        completed_at: completedAt,
      })

      const afterTurn = await checkedRequest("account/rateLimits/read", {})
      output.post_turn_rate_limits.push({
        turn_number: turnNumber,
        observed_at: now(),
        rate_limits: rateLimitsSnapshot(afterTurn),
      })
    }

    await new Promise(resolve => setTimeout(resolve, 750))
    output.finished_at = now()
    output.live_notification_count = rateLimitUpdates.length
    output.evidence_status = hasUsableRateLimitEvidence(output, rateLimitUpdates)
      ? "live_observed"
      : "live_unverified"
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`)
  } catch (error) {
    const envelope = sanitizedCodexFailureEnvelope(startedAt, error, rateLimitUpdates.length)
    process.stdout.write(`${JSON.stringify(envelope, null, 2)}\n`)
    process.exitCode = 1
    return
  } finally {
    for (const entry of pending.values()) clearTimeout(entry.timer)
    for (const waiter of notificationWaiters) clearTimeout(waiter.timer)
    lines.close()
    child.kill("SIGTERM")
  }
}

function hasUsableRateLimitEvidence(output, rateLimitUpdates) {
  const snapshots = [
    output.initial_rate_limits && output.initial_rate_limits.rate_limits,
    ...output.post_turn_rate_limits.map(entry => entry.rate_limits),
    ...rateLimitUpdates.map(entry => entry.rate_limits),
  ]

  return snapshots.some(snapshot =>
    !!snapshot && (
      isUsableWindow(snapshot.primary) ||
      isUsableWindow(snapshot.secondary) ||
      (typeof snapshot.rate_limit_reached_type === "string" && snapshot.rate_limit_reached_type !== "")
    )
  )
}

function rpcFailure(error) {
  if (error && error.code === "TIMEOUT") return {category: "timed_out"}
  if (error && error.code === "SPAWN_ERROR") return {category: "executable_unavailable"}
  if (error && error.code === "RPC_ERROR") {
    return {
      category: "provider_rpc_error",
      code: Number.isInteger(error.rpc_code) ? error.rpc_code : null,
    }
  }
  return {category: "process_or_protocol_error"}
}

function sanitizedCodexFailureEnvelope(startedAt, error, liveNotificationCount) {
  return {
    schema_version: 1,
    provider: "codex",
    evidence_status: "error",
    outcome: error && error.code === "TIMEOUT" ? "timed_out" : "failed",
    failure: rpcFailure(error),
    started_at: startedAt,
    finished_at: now(),
    live_notification_count: liveNotificationCount,
  }
}

module.exports = {
  windowSnapshot,
  rateLimitsSnapshot,
  safeClaudeWindow,
  safeClaudeRateLimits,
  isUsableWindow,
  isUsableClaudeWindow,
  hasUsableClaudeSnapshot,
  hasUsableRateLimitEvidence,
  classifyClaudeHeadlessEvidence,
  sanitizedCodexFailureEnvelope,
}
