const assert = require("node:assert/strict")
const {test, after} = require("node:test")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const {spawnSync} = require("node:child_process")

const REPO_ROOT = path.join(__dirname, "..")
const NODE = process.execPath

const createdDirs = []

after(() => {
  for (const dir of createdDirs) {
    fs.rmSync(dir, {recursive: true, force: true})
  }
})

function hermeticEmptyPath() {
  // A freshly created, empty temporary directory guarantees no real "codex",
  // "claude", or "expect" executable can be found on PATH, independent of
  // what happens to be installed on this machine (no /usr/bin or
  // /opt/homebrew/bin assumptions). Tracked and removed in the after() hook
  // above so tests don't litter the OS temp directory.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shoestring-gate-0a-empty-path-"))
  createdDirs.push(dir)
  return dir
}

function writeFakeExecutable(dir, name, body) {
  const filePath = path.join(dir, name)
  // Shebang points at the absolute node binary so the OS never needs to
  // resolve an interpreter through PATH (which this test intentionally empties).
  fs.writeFileSync(filePath, `#!${NODE}\n${body}`, {mode: 0o755})
  return filePath
}

function runScript(scriptPath, args, envOverrides) {
  return spawnSync(NODE, [scriptPath, ...args], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    env: {...process.env, ...envOverrides},
    timeout: 30000,
  })
}

const SANITIZED_FAILURE_KEYS = [
  "evidence_status",
  "invocation_mode",
  "observed_at",
  "outcome",
  "probe_outcomes",
  "provider",
  "schema_version",
]

test("provider_probe.js: an unsupported provider argument is never echoed back, even a sentinel sensitive-looking one", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/provider_probe.js")
  const sentinel = "/home/attacker/.ssh/id_rsa_SENTINEL_DO_NOT_LEAK_9f3a1c-secret-prompt-message"
  const result = runScript(probe, [sentinel], {})

  assert.equal(result.status, 2)
  assert.equal(result.stdout.includes("SENTINEL"), false)
  assert.equal(result.stdout.includes("attacker"), false)
  assert.equal(result.stdout.includes("id_rsa"), false)
  assert.equal(result.stderr.includes("SENTINEL"), false)
  assert.equal(result.stderr.includes("attacker"), false)
  assert.equal(result.stderr.includes("id_rsa"), false)

  const output = JSON.parse(result.stdout)
  assert.deepEqual(Object.keys(output).sort(), [
    "evidence_status",
    "observed_at",
    "outcome",
    "provider",
    "schema_version",
    "supported_arguments",
  ])
  assert.equal(output.provider, null)
  assert.equal(output.evidence_status, "error")
  assert.equal(output.outcome, "unsupported_probe_argument")
  assert.deepEqual(output.supported_arguments, ["codex", "claude"])
})

test("provider_probe.js codex: missing binary (hermetic empty PATH) reports error, not live_observed", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/provider_probe.js")
  const emptyPathDir = hermeticEmptyPath()
  const result = runScript(probe, ["codex"], {PATH: emptyPathDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(output.outcome, "failed")
  assert.equal(output.failure.category, "executable_unavailable")
  assert.equal(Object.hasOwn(output, "token"), false)
})

test("provider_probe.js claude: missing binary (hermetic empty PATH) reports error, not live_observed", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/provider_probe.js")
  const emptyPathDir = hermeticEmptyPath()
  const result = runScript(probe, ["claude"], {PATH: emptyPathDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(output.live_capacity_probe, "blocked_executable_unavailable")
  assert.deepEqual(Object.keys(output).sort(), [
    "evidence_status",
    "invocation_mode",
    "live_capacity_probe",
    "observed_at",
    "outcome",
    "probe_outcomes",
    "provider",
    "schema_version",
  ])
  assert.deepEqual(output.probe_outcomes, [])
  assert.equal(Object.hasOwn(output, "headless_probes"), false)
  assert.equal(Object.hasOwn(output, "authentication"), false)
  assert.equal(Object.hasOwn(output, "token"), false)
})

test("concurrent_codex_read.js: missing binary (hermetic empty PATH) reports a fresh sanitized error envelope and exits non-zero", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/concurrent_codex_read.js")
  const emptyPathDir = hermeticEmptyPath()
  const result = runScript(probe, [], {PATH: emptyPathDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.deepEqual(Object.keys(output).sort(), SANITIZED_FAILURE_KEYS)
  assert.deepEqual(output.probe_outcomes, ["executable_unavailable", "executable_unavailable"])
  assert.equal(Object.hasOwn(output, "observations"), false)
})

test("codex_restart_read.js: missing binary (hermetic empty PATH) reports a fresh sanitized error envelope and exits non-zero", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/codex_restart_read.js")
  const emptyPathDir = hermeticEmptyPath()
  const result = runScript(probe, [], {PATH: emptyPathDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.deepEqual(Object.keys(output).sort(), SANITIZED_FAILURE_KEYS)
  assert.deepEqual(output.probe_outcomes, ["executable_unavailable", "executable_unavailable"])
  assert.equal(Object.hasOwn(output, "observations"), false)
})

test("claude_statusline_probe.js: missing expect binary (hermetic empty PATH) reports a fresh sanitized error envelope", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/claude_statusline_probe.js")
  const emptyPathDir = hermeticEmptyPath()
  const result = runScript(probe, ["single"], {PATH: emptyPathDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.deepEqual(Object.keys(output).sort(), [...SANITIZED_FAILURE_KEYS, "tested_mode"].sort())
  assert.equal(output.tested_mode, "single")
  assert.deepEqual(output.probe_outcomes, ["process_error"])
  assert.equal(Object.hasOwn(output, "callbacks"), false)
  assert.equal(Object.hasOwn(output, "process_results"), false)
  assert.equal(Object.hasOwn(output, "token"), false)
})

test("claude_statusline_probe.js: a completed process with zero callbacks is live_unverified, never live_observed, exit 0", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/claude_statusline_probe.js")
  const binDir = hermeticEmptyPath()
  // A fake "expect" that exits 0 immediately without ever invoking the real
  // claude CLI or the status-line observer: the process "completes", but no
  // capture file is ever written, so callbacks stay empty.
  writeFakeExecutable(binDir, "expect", "process.exit(0)\n")

  const result = runScript(probe, ["single"], {PATH: binDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 0)
  assert.equal(output.evidence_status, "live_unverified")
  assert.notEqual(output.evidence_status, "live_observed")
  assert.deepEqual(output.callbacks, [])
  assert.equal(output.comparison, "inconclusive")
  assert.equal(output.process_results.some(entry => entry.outcome === "completed"), true)
})

test("provider_probe.js codex: a failure after real data has accumulated emits a fresh sanitized envelope, not the accumulated output", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/provider_probe.js")
  const binDir = hermeticEmptyPath()
  // A fake codex app-server that answers the handshake, account read, first
  // rate-limit read, thread/turn start, and turn completion with real-looking
  // (synthetic) data, then fails the second rate-limit read. This proves the
  // catch path does not leak whatever had already accumulated in `output`.
  writeFakeExecutable(binDir, "codex", `
const readline = require("node:readline")

if (process.argv[2] === "--version") {
  process.stdout.write("fake-codex 0.0.0-test\\n")
  process.exit(0)
}

if (process.argv[2] === "app-server" && process.argv[3] === "--stdio") {
  const rl = readline.createInterface({input: process.stdin})
  let rateLimitReadCount = 0
  const send = obj => process.stdout.write(JSON.stringify(obj) + "\\n")

  rl.on("line", line => {
    let message
    try {
      message = JSON.parse(line)
    } catch (_error) {
      return
    }
    if (!message || typeof message !== "object") return

    if (message.method === "initialize") {
      send({id: message.id, result: {platformFamily: "test-platform-family", platformOs: "test-platform-os"}})
    } else if (message.method === "account/read") {
      send({id: message.id, result: {account: {type: "test-account-type", planType: "test-plan-name"}, requiresOpenaiAuth: false}})
    } else if (message.method === "account/rateLimits/read") {
      rateLimitReadCount += 1
      if (rateLimitReadCount === 1) {
        send({id: message.id, result: {rateLimits: {
          primary: {usedPercent: 11, windowDurationMins: 300, resetsAt: 1111},
          secondary: {usedPercent: 6, windowDurationMins: 10080, resetsAt: 2222},
        }}})
      } else {
        send({id: message.id, error: {code: -32000, message: "synthetic_failure_after_first_read"}})
      }
    } else if (message.method === "thread/start") {
      send({id: message.id, result: {thread: {id: "test-thread-id"}}})
    } else if (message.method === "turn/start") {
      send({id: message.id, result: {turn: {id: "test-turn-id"}}})
      // Deferred with a real timer (not setImmediate, which can still
      // race under some readline buffering/OS scheduling interleavings) so
      // the caller's turn/completed waiter is reliably registered before
      // the notification is delivered.
      setTimeout(() => {
        send({method: "turn/completed", params: {turn: {id: "test-turn-id", status: "completed"}, turnId: "test-turn-id"}})
      }, 20)
    }
  })

  process.stdin.resume()
}
`)

  const result = runScript(probe, ["codex"], {PATH: binDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(output.outcome, "failed")
  assert.equal(output.failure.category, "provider_rpc_error")

  assert.deepEqual(Object.keys(output).sort(), [
    "evidence_status",
    "failure",
    "finished_at",
    "live_notification_count",
    "outcome",
    "provider",
    "schema_version",
    "started_at",
  ])

  const rawOutput = result.stdout + result.stderr
  for (const forbidden of [
    "test-platform-family",
    "test-platform-os",
    "test-account-type",
    "test-plan-name",
    "test-thread-id",
    "test-turn-id",
    "usedPercent",
    "rateLimits",
    "handshake",
    "account",
    "turns",
    "Error:",
    "at Object.",
    "node_modules",
    REPO_ROOT,
  ]) {
    assert.equal(rawOutput.includes(forbidden), false, `output must not contain ${JSON.stringify(forbidden)}`)
  }
})

test("provider_probe.js codex: usable initial read but unusable post-turn reads is live_unverified, not live_observed (aggregate requires every required snapshot)", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/provider_probe.js")
  const binDir = hermeticEmptyPath()
  // The account/rateLimits/read call before any turn returns real usable
  // data, but both post-turn reads return a structurally valid yet empty
  // rateLimits object. The whole RPC exchange completes successfully (no
  // process/RPC failure), so this must be live_unverified, never
  // live_observed -- a single usable snapshot among the required set is not
  // enough.
  writeFakeExecutable(binDir, "codex", `
const readline = require("node:readline")

if (process.argv[2] === "--version") {
  process.stdout.write("fake-codex 0.0.0-test\\n")
  process.exit(0)
}

if (process.argv[2] === "app-server" && process.argv[3] === "--stdio") {
  const rl = readline.createInterface({input: process.stdin})
  let rateLimitReadCount = 0
  const send = obj => process.stdout.write(JSON.stringify(obj) + "\\n")

  rl.on("line", line => {
    let message
    try {
      message = JSON.parse(line)
    } catch (_error) {
      return
    }
    if (!message || typeof message !== "object") return

    if (message.method === "initialize") {
      send({id: message.id, result: {platformFamily: "test-platform-family", platformOs: "test-platform-os"}})
    } else if (message.method === "account/read") {
      send({id: message.id, result: {account: {type: "test-account-type", planType: "test-plan-name"}, requiresOpenaiAuth: false}})
    } else if (message.method === "account/rateLimits/read") {
      rateLimitReadCount += 1
      if (rateLimitReadCount === 1) {
        send({id: message.id, result: {rateLimits: {
          primary: {usedPercent: 20, windowDurationMins: 300, resetsAt: 1111},
          secondary: {usedPercent: 15, windowDurationMins: 10080, resetsAt: 2222},
        }}})
      } else {
        send({id: message.id, result: {rateLimits: {}}})
      }
    } else if (message.method === "thread/start") {
      send({id: message.id, result: {thread: {id: "test-thread-id"}}})
    } else if (message.method === "turn/start") {
      send({id: message.id, result: {turn: {id: "test-turn-id"}}})
      // Deferred with a real timer (not setImmediate, which can still race
      // under some readline buffering/OS scheduling interleavings) so the
      // caller's turn/completed waiter is reliably registered before the
      // notification is delivered.
      setTimeout(() => {
        send({method: "turn/completed", params: {turn: {id: "test-turn-id", status: "completed"}, turnId: "test-turn-id"}})
      }, 20)
    }
  })

  process.stdin.resume()
}
`)

  const result = runScript(probe, ["codex"], {PATH: binDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 0)
  assert.equal(output.evidence_status, "live_unverified")
  assert.notEqual(output.evidence_status, "live_observed")
  assert.equal(output.initial_rate_limits.rate_limits.primary.used_percent, 20)
  assert.equal(output.post_turn_rate_limits[0].rate_limits.primary, null)
  assert.equal(output.post_turn_rate_limits[1].rate_limits.primary, null)
})
