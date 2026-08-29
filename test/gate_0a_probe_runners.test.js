const assert = require("node:assert/strict")
const test = require("node:test")
const path = require("node:path")
const {spawnSync} = require("node:child_process")

const REPO_ROOT = path.join(__dirname, "..")
const NODE = process.execPath

function runScript(scriptPath, args, envOverrides) {
  const result = spawnSync(NODE, [scriptPath, ...args], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    env: {...process.env, ...envOverrides},
    timeout: 30000,
  })

  return result
}

test("provider_probe.js codex: missing binary reports an error evidence status, not live_observed", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/provider_probe.js")
  const result = runScript(probe, ["codex"], {PATH: "/usr/bin"})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(output.outcome, "failed")
  assert.equal(output.failure.category, "executable_unavailable")
  assert.equal(Object.hasOwn(output, "token"), false)
})

test("provider_probe.js claude: missing binary reports an error evidence status, not live_observed", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/provider_probe.js")
  const result = runScript(probe, ["claude"], {PATH: "/usr/bin"})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(output.live_capacity_probe, "blocked_executable_unavailable")
  assert.deepEqual(output.headless_probes, [])
  assert.equal(Object.hasOwn(output, "token"), false)
})

test("concurrent_codex_read.js: missing binary reports an error evidence status and exits non-zero", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/concurrent_codex_read.js")
  const result = runScript(probe, [], {PATH: "/usr/bin"})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(
    output.observations.every(observation => observation.outcome === "executable_unavailable"),
    true,
  )
})

test("codex_restart_read.js: missing binary reports an error evidence status and exits non-zero", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/codex_restart_read.js")
  const result = runScript(probe, [], {PATH: "/usr/bin"})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.equal(
    output.observations.every(observation => observation.outcome === "executable_unavailable"),
    true,
  )
})

test("claude_statusline_probe.js: missing expect binary yields zero callbacks and an error evidence status", () => {
  const probe = path.join(REPO_ROOT, "tools/gate_0a/claude_statusline_probe.js")
  const result = runScript(probe, ["single"], {PATH: "/opt/homebrew/bin:/bin"})
  const output = JSON.parse(result.stdout)

  assert.equal(result.status, 1)
  assert.equal(output.evidence_status, "error")
  assert.deepEqual(output.callbacks, [])
  assert.equal(output.comparison, "inconclusive")
  assert.equal(Object.hasOwn(output, "token"), false)
})
