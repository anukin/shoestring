# Iteration 13 — package A preflight (opencode transport spike)

Date: 2026-10-24. opencode v2.0.31 on macOS arm64. The user directed the start
of iteration 13 on 2026-10-24. Session identifiers below are replaced with
synthetic values of the same shape (`ses_` + 26 characters); paths are
replaced with `REPO`.

## Status

Packages A–F are implemented and the gate is green. Everything that needs no
inference is VERIFIED against the real opencode 2.0.31, including the
sandboxed launch through the real adapter. The prompt stream (agent messages,
tool calls, permission requests), a completed task, cancellation of a running
tool, the process groups of opencode's tools and resume after a prompt are
UNVERIFIED with a real model: every provider integration on this machine is
rejected (see "Authentication"), and Shoestring never signs in for opencode.
They are built against the published ACP schema and covered by hermetic tests
over real stdio against a scripted stand-in.

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
--standalone` returns `provider.auth` "Request failed: 401". The free models
(`opencode/…-free`) fail the same way: opencode's own providers go through an
OpenCode Console API key, and the provider answers `401 api_key_expired`
("Create a new API key in OpenCode Console … Signing in again will not renew
this key"). So no model is usable here until the user renews a login.

This is also the needs-sign-in signal the adapter classifies
(`:authentication_required`, code `provider_auth_required`): it arrives before
any model call, so it costs no inference. Detecting it without a prompt was
not found.

## Sandbox findings (VERIFIED, real opencode 2.0.31, no inference)

The adapter wraps `opencode acp` in `sandbox-exec` with a profile built from
Shoestring's paths (`OpencodeAcp.Sandbox`). Checked by running the real
binary under the generated profile in a scratch private run worktree:

- With home reads denied, `session/new` failed (`-32603` "Internal service
  failure"). Removing rules one at a time, then dropping home entries one at a
  time until only the required ones remained, showed opencode reads
  `~/.claude` and `~/.agents` when a session starts. Allowing those would
  expose Claude's settings and transcripts to the agent's shell, so instead
  `HOME` points at the run's temporary directory and the XDG variables at
  opencode's real data, state, cache and config directories
  (`OPENCODE_DISABLE_CLAUDE_CODE` and `OPENCODE_DISABLE_AUTOUPDATE` are also
  set). `initialize`, `session/new` and the model selection then succeed.
- A prompt under the profile then hung with no response:
  opencode's log showed `EPERM … lstat` on its global `AGENTS.md`, which on
  this machine is a symlink to a file elsewhere under home, followed by
  "Instruction initialization blocked by unavailable sources" and no reply.
  The profile now allows reading the resolved targets of symlinks at the top
  of opencode's config directory, and nothing else under home.
- Through the real adapter (`OpencodeAcp.start/2` with `sandbox: true`, model
  `opencode/glm-5.3-flash-free`): the run reported one `:error` event,
  `authentication_required/provider_auth_required`, 612 ms after the prompt
  was sent, and no opencode process remained afterwards.
- Hermetic enforcement check (`sandbox_test.exs`, real `sandbox-exec` on a
  shell): writes to the worktree, opencode's data directory and the run's
  temporary directory succeed; writes to the source repository, elsewhere in
  home and the shared temporary directory are refused; `git status` inside the
  worktree reads its private store (fails without the store rule, checked by
  removing it).

## Design decisions

- Transport `opencode acp`; the Elf adopts the acp process group
  (`process_owner: :adapter`). Cancellation and release reap every process
  group under it, plus groups remembered while it was alive, because the
  server child leads its own group and the Elf kills the acp group before
  releasing the adapter on a verdict (regression test fails without the
  remembered groups).
- Permission requests: allowed once only when the adapter built the sandbox,
  refused otherwise; a caller cannot claim a sandbox through options.
- Resume is implemented (`session/resume`) but `:resume` is not declared:
  a resumed prompt's completion is unverified (the Claude adapter's
  precedent).
- Effort: opencode's effort values differ per model (VERIFIED above), so a
  role cannot pin one; the session applies an effort only when the model
  offers it.
- Capacity: honest unknown, tier `reactive_only`. Admission records that
  reading, so opencode tasks ask for the usual confirmation. Nothing maps to
  `quota_refused`.
- Collection windows (package F decision): an opencode task on an `openai/…`
  model waits while a Codex collection window is open, and starts once it is
  closed. opencode runs are never bracketed, so never calibration examples.
- Doctor reads only `opencode --version` (VERIFIED not to start the
  background server); sign-in is not detectable, so a tested opencode is
  `unknown`, never `ready`.

## Gate

`mix precommit` in the worktree (`9daa7fb` plus the CLI test commit), seed
893299: 4 doctests, 2534 tests, 0 failures, 3 skipped (the existing one plus
the two withheld-resume contract tests), 6 excluded; Rust 4 + 5; Node 52/52
and 14/14.

## Regression check (base `1b9a2ed`)

The tests that use only pre-existing modules were copied onto the base and
fail there for behavioural reasons (5 of 5): the dataset row's provider is
`unknown`; `models add opencode` is refused as an unknown provider; the
catalog has no `opencode` list; `agents create` with an opencode worker gives
no coordinator refusal; the checkpoint names no opencode command outcome or
unfinished call. The adapter, session, sandbox, admission, lease-spend and
UI tests exercise new modules and are new-feature tests.

## Not done

- A live prompt, cancellation of a running tool, the tools' process groups
  and resume: UNVERIFIED until the user renews an opencode login
  (`opencode auth login`; an OpenCode Console key covers the free models).
- Manual runs from the Runs page do not offer opencode (plan tasks only).
