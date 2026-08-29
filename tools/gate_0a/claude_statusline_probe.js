#!/usr/bin/env node

const {execFileSync, spawn, spawnSync} = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")

const MODE = process.argv[2] || "single"
const VALID_MODES = new Set(["single", "restart", "concurrent", "refresh", "tools"])
const REPO_ROOT = process.cwd()
const OBSERVER = path.join(REPO_ROOT, "tools/gate_0a/claude_statusline_observer.js")

if (!VALID_MODES.has(MODE)) {
  process.stdout.write(`${JSON.stringify({
    schema_version: 1,
    evidence_status: "unsupported_probe_argument",
    provider: "claude",
    supported_modes: [...VALID_MODES],
  }, null, 2)}\n`)
  process.exitCode = 2
} else {
  runProbe().then(output => {
    if (output.evidence_status === "error") process.exitCode = 1
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`)
  }).catch(_error => {
    process.stdout.write(`${JSON.stringify({
      schema_version: 1,
      evidence_status: "error",
      provider: "claude",
      invocation_mode: "interactive statusLine command",
      outcome: "probe_failed",
    }, null, 2)}\n`)
    process.exitCode = 1
  })
}

async function runProbe() {
  const captureDir = fs.mkdtempSync(path.join(os.tmpdir(), "shoestring-gate-0a-"))
  const captureFile = path.join(captureDir, "status-line.ndjson")
  const settings = JSON.stringify({
    statusLine: {
      type: "command",
      command: `node ${OBSERVER}`,
      ...(MODE === "refresh" ? {refreshInterval: 1} : {}),
    },
  })
  const labels = labelsFor(MODE)

  try {
    const processResults = MODE === "concurrent"
      ? await Promise.all(labels.map(label => runSession(label, settings, captureFile)))
      : labels.map(label => runSessionSync(label, settings, captureFile))
    const callbacks = readCallbacks(captureFile)
    const observedCallback = callbacks.some(callback => callback.rate_limit_signal === "observed")
    const allProcessesFailed = processResults.length > 0 &&
      processResults.every(result => result.outcome !== "completed")
    const evidenceStatus = observedCallback
      ? "live_observed"
      : allProcessesFailed
        ? "error"
        : "live_unverified"

    return {
      schema_version: 1,
      evidence_status: evidenceStatus,
      provider: "claude",
      cli_version: versionOf("claude"),
      runtime: {
        os: process.platform,
        architecture: process.arch,
        node_version: process.version,
      },
      invocation_mode: "interactive Claude Code with official statusLine command via session --settings",
      tested_mode: MODE,
      captured_at: callbacks[0] && callbacks[0].observed_at || new Date().toISOString(),
      process_results: processResults,
      callbacks,
      comparison: compareByRun(callbacks, MODE),
      limitations: [
        MODE === "tools"
          ? "The fixed interaction allowed only the read-only printf tool command and requested one short response."
          : "The fixed interaction used no tools and requested one short response.",
        "No prompt, response text, session identifier, path, or raw status-line input was retained.",
        "A callback timestamp is local process receipt time, not provider-side generation time.",
      ],
    }
  } finally {
    fs.rmSync(captureDir, {recursive: true, force: true})
  }
}

function labelsFor(mode) {
  if (mode === "restart") return ["before_restart", "after_restart"]
  if (mode === "concurrent") return ["session_a", "session_b"]
  return ["single"]
}

function runSessionSync(label, settings, captureFile) {
  const result = spawnSync("expect", ["-c", expectProgram(MODE)], {
    cwd: REPO_ROOT,
    env: {
      ...process.env,
      SHOESTRING_GATE_0A_CAPTURE_FILE: captureFile,
      SHOESTRING_GATE_0A_RUN_LABEL: label,
      SHOESTRING_GATE_0A_STATUSLINE_SETTINGS: settings,
    },
    encoding: "utf8",
    stdio: ["ignore", "ignore", "ignore"],
    timeout: 120000,
  })

  return processResult(label, result)
}

function runSession(label, settings, captureFile) {
  return new Promise(resolve => {
    const child = spawn("expect", ["-c", expectProgram(MODE)], {
      cwd: REPO_ROOT,
      env: {
        ...process.env,
        SHOESTRING_GATE_0A_CAPTURE_FILE: captureFile,
        SHOESTRING_GATE_0A_RUN_LABEL: label,
        SHOESTRING_GATE_0A_STATUSLINE_SETTINGS: settings,
      },
      stdio: ["ignore", "ignore", "ignore"],
    })

    const timeout = setTimeout(() => {
      child.kill("SIGTERM")
      resolve({label, outcome: "timed_out", exit_status: null})
    }, 120000)

    child.once("error", _error => {
      clearTimeout(timeout)
      resolve({label, outcome: "process_error", exit_status: null})
    })
    child.once("close", (code, signal) => {
      clearTimeout(timeout)
      resolve({
        label,
        outcome: code === 0 && signal === null ? "completed" : "process_error",
        exit_status: Number.isInteger(code) ? code : null,
      })
    })
  })
}

function expectProgram(mode) {
  const toolArgs = mode === "tools" ? "--tools Bash --allowedTools {Bash(printf *)}" : "--tools {}"
  const prompt = mode === "tools"
    ? "{Use Bash to run exactly `printf TOOL_OK`, then reply with exactly OK.}"
    : "{Reply with exactly OK.}"

  return [
    "set timeout 20",
    "log_user 0",
    `spawn claude --settings $env(SHOESTRING_GATE_0A_STATUSLINE_SETTINGS) --permission-mode dontAsk ${toolArgs} --no-chrome --ax-screen-reader ${prompt}`,
    "after 8000",
    "send -- \"/exit\\r\"",
    "expect {",
    "  eof {}",
    "  timeout {send -- \"\\003\"}",
    "}",
  ].join("\n")
}

function readCallbacks(captureFile) {
  if (!fs.existsSync(captureFile)) return []

  return fs.readFileSync(captureFile, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map(line => {
      try {
        return JSON.parse(line)
      } catch (_error) {
        return null
      }
    })
    .filter(Boolean)
}

function compareByRun(callbacks, mode) {
  if (["single", "refresh", "tools"].includes(mode)) {
    return callbacks.length >= 2 ? "callbacks_received" : "inconclusive"
  }

  const runs = new Map()
  for (const callback of callbacks) {
    if (!runs.has(callback.probe_run)) runs.set(callback.probe_run, [])
    runs.get(callback.probe_run).push(callback)
  }

  if (runs.size !== 2) return "inconclusive"

  const snapshots = [...runs.values()]
    .map(run => run.find(callback => callback.rate_limit_signal === "observed"))
    .filter(Boolean)

  if (snapshots.length !== 2) return "inconclusive"
  return JSON.stringify(snapshots[0].rate_limits) === JSON.stringify(snapshots[1].rate_limits)
    ? "identical"
    : "divergent"
}

function processResult(label, result) {
  return {
    label,
    outcome: result.status === 0 ? "completed" : "process_error",
    exit_status: Number.isInteger(result.status) ? result.status : null,
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
