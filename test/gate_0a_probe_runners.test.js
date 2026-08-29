const assert = require("node:assert/strict")
const test = require("node:test")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const {spawnSync} = require("node:child_process")

const REPO_ROOT = path.join(__dirname, "..")
const NODE = process.execPath

function hermeticEmptyPath() {
  // A freshly created, empty temporary directory guarantees no real "codex",
  // "claude", or "expect" executable can be found on PATH, independent of
  // what happens to be installed on this machine (no /usr/bin or
  // /opt/homebrew/bin assumptions).
  return fs.mkdtempSync(path.join(os.tmpdir(), "shoestring-gate-0a-empty-path-"))
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
  assert.deepEqual(output.headless_probes, [])
  assert.equal(Object.hasOwn(output, "token"), false)
})

test("concurrent_codex_read.js: missing binary (hermetic empty PATH) reports error and exits non-zero", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/concurrent_codex_read.js")
  const emptyPathDir = hermeticEmptyPath()
  const result = runScript(probe, [], {PATH: emptyPathDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(
    output.observations.every(observation => observation.outcome === "executable_unavailable"),
    true,
  )
})

test("codex_restart_read.js: missing binary (hermetic empty PATH) reports error and exits non-zero", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/codex_restart_read.js")
  const emptyPathDir = hermeticEmptyPath()
  const result = runScript(probe, [], {PATH: emptyPathDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(
    output.observations.every(observation => observation.outcome === "executable_unavailable"),
    true,
  )
})

test("claude_statusline_probe.js: missing expect binary (hermetic empty PATH) yields zero callbacks and error", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/claude_statusline_probe.js")
  const emptyPathDir = hermeticEmptyPath()
  const result = runScript(probe, ["single"], {PATH: emptyPathDir})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.deepEqual(output.callbacks, [])
  assert.equal(output.comparison, "inconclusive")
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
      // Deferred so the caller's turn/completed waiter is registered
      // before the notification is delivered (avoids a same-tick race).
      setImmediate(() => {
        send({method: "turn/completed", params: {turn: {id: "test-turn-id", status: "completed"}, turnId: "test-turn-id"}})
      })
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
