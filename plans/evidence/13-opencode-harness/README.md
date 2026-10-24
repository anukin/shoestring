# Iteration 13 — package A preflight (opencode transport spike)

Date: 2026-10-24. opencode v2.0.31 on macOS arm64. The user directed the start
of iteration 13 on 2026-10-24. Session identifiers below are replaced with
synthetic values of the same shape (`ses_` + 26 characters); paths are
replaced with `REPO`.

## Status

Package A is **incomplete**. Everything that needs no inference is recorded
below (VERIFIED, command output from this run). The prompt stream, permission
requests, tool-call process tree, cancellation of a running tool and resume
after a prompt are UNVERIFIED: the stored OpenAI integration is rejected by the
provider (see "Authentication"), and Shoestring never signs in for opencode.

Inference used: none. Every prompt attempt was refused before any model call.

## Transport choice: `opencode acp`

VERIFIED. `opencode acp` speaks JSON-RPC 2.0, one JSON object per line, on
stdin/stdout, and writes nothing to stderr in these runs.

- `initialize` (`protocolVersion: 1`, client `fs` read/write false,
  `terminal: false`) returns `protocolVersion: 1`, `agentInfo` `OpenCode`
  `2.0.31`, `loadSession: true`, `sessionCapabilities` `close`, `delete`,
  `fork`, `list`, `resume`, `additionalDirectories`, and one auth method
  (`opencode-login`, "Run `opencode auth login` in the terminal").
- `session/new {cwd, mcpServers: []}` returns `sessionId` and
  `configOptions`: `model` (select, 190 values across the `openai`,
  `opencode` and `opencode-go` providers on this machine), `effort` (category
  `thought_level`) and `mode` (`build`, `plan`).
- `session/set_config_option {sessionId, configId, value}` returns the full
  option list. Effort values depend on the model: the default model offers
  `low, high, max, default`; `openai/gpt-5.4-mini` offers
  `none, low, medium, high, xhigh, default`. An unknown model returns error
  `-32602` "Invalid params: model not found: openai/no-such-model".
  So effort maps to a stable per-model option list read from the session, not
  to a fixed table (package E).
- `session/close` returns `{}`; `session/resume {sessionId, cwd,
  mcpServers}` returns the session's options with model and effort kept;
  `session/list {cwd}` lists sessions for that directory, which opencode keeps
  in its own database (`~/.local/share/opencode/opencode.db`), not in REPO.
- The agent sends `session/update` notifications unprompted
  (`available_commands_update`).

`opencode run --format json` remains a fallback: it emits JSON events with a
`sessionID` and typed errors (`{"type":"error","error":{"type":"provider.auth",
"message":"Request failed: 401"}}`), exit 1.

## Process tree and the background service

VERIFIED.

- `opencode acp` starts one child, `opencode serve --stdio --port 0`, **in a
  different process group** (child pgid = child pid). A `killpg` of the acp
  group therefore does not signal it directly. In two runs each, after
  `killpg(TERM)` and `killpg(KILL)` of the acp group, the serve child was gone
  within 0.5 s; on stdin EOF both exit with status 0 within 2 s.
- Several other subcommands (`opencode models`, `opencode auth list`) start a
  **detached background server** `opencode serve --service` (parent pid 1, its
  own group) and leave it running. `opencode run` uses it unless given
  `--standalone`. Shoestring must never invoke those subcommands from a run
  path; doctor and the probe must use `--version` only, or `--standalone`.
  (The service was stopped again after each observation with
  `opencode service stop`; it was stopped before the spike.)
- UNVERIFIED: the process group of tools the agent runs (bash, `sleep 45`)
  and whether they die with the acp group. The cancellation design (package C)
  depends on this; if they escape, the run must also reap the serve child's
  descendants.

## Authentication

VERIFIED. `opencode auth list` shows `OpenAI  OAuth  stored`. A prompt on
`openai/gpt-5.4-mini` over ACP returns error `-32000` "Authentication
required: provider authentication required" in 0.3 s; `opencode run
--standalone` returns `provider.auth` "Request failed: 401". The stored login
is stale. This is also the needs-sign-in signal the adapter should classify:
it arrives before any model call, so it costs no inference. Detecting it
without a prompt was not found.

## Next

The user re-signs in (`opencode auth login`, OpenAI). Then, within a stated
budget: one small edit, one cancellation during a running `sleep`, one resume
from a new acp process; record redacted frames and the tool process tree.
