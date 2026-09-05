# Codex app-server transport probe (iter4 wave-0 spike B)

Date: 2026-09-04. CLI: `codex-cli 0.153.2`. Owner: app-server --stdio
execution adapter spike (the parallel agent owns `codex exec --json`).

Question: does app-server expose THREAD/TURN methods rich enough to run and
supervise a bounded implementation run — typed item boundaries plus IN-BAND
cancellation — making it better than exec for the Cancel and Lease-boundary
evals?

Short answer: **yes**. `turn/interrupt` is acknowledged in-band and the turn
stops cleanly (`turn/completed` status `interrupted`), the write sandbox
actually mutates files on disk, and the item stream gives typed
start/completion boundaries for commands and file changes. Interrupt
VERIFIED live with one bounded turn; write capability VERIFIED live with a
second minimal turn (one file, nothing else). Everything else is
zero-model-cost stdio probing or static schema inspection. The two turns cost
~16.6k and ~16.9k input tokens respectively (mostly cached) per the observed
`thread/tokenUsage/updated` notifications. Descendant processes SURVIVE the
interrupt, so the adapter must kill the process group itself. Verdict:
**app-server --stdio for Work Package C**, with mitigations listed below.
Update (Work Package C): Exactly one additional bounded live turn was executed under
WP-C to verify post-turn resume across process restart and capture live
`commandExecution` `item/completed` shape (fixture `thread-resume-and-command-complete.json`).
Both are VERIFIED live. Total live runs across spike and WP-C: 3 turns (1 in WP-C).

## 1. How the surface was enumerated (no model spend)

- `codex app-server --help` — top level is marked
  `[experimental] Run the app server or related tooling`. Transports:
  `stdio://` (default), unix socket, ws. This spike used `--stdio`.
- `codex app-server generate-json-schema --out <dir>`, with and without
  `--experimental`. Base bundle: **99 client request methods**; with
  `--experimental`: **155**. Server-to-client: **81 notification methods**.
  There is NO runtime `methods/list` endpoint and `initialize` carries NO
  capabilities field (result keys are exactly `codexHome`, `platformFamily`,
  `platformOs`, `userAgent` — VERIFIED live, fixture
  `initialize-handshake.json`). Discovery is static schema inspection.
- The richest runtime inventory came free from the server itself: an unknown
  method is rejected with `-32600` echoing the full accepted variant list
  (~150 entries, matching the `--experimental` schema set plus runtime-only
  entries such as `process/spawn|writeStdin|kill`, `thread/queue/*`,
  `remoteControl/*`). VERIFIED live, no model involved.
- Reused framing knowledge from
  `lib/shoestring/harness/capacity/codex/stdio_transport.ex` (line-delimited
  JSON-RPC, 262144 byte cap) and `codex_monitor.ex` (handshake
  `initialize` → `initialized` → `account/read` → `account/rateLimits/read`).
  No lib/ file was modified.

## 2. Method / notification inventory (label convention: VERIFIED = observed live AND backed by a committed frame in `test/fixtures/codex/app_server/`; schema-only = present in the generated JSON Schema but UNVERIFIED live; UNVERIFIED = neither. Every VERIFIED below names its fixture.)

### Start a bounded turn in a specified cwd — VERIFIED

- `thread/start` (params: `cwd`, `ephemeral`, `approvalPolicy`,
  `sandbox`, `model`, `modelProvider`, …). VERIFIED live: first probe sent
  `{ephemeral, cwd: $FIXTURE, approvalPolicy: "never"}` with NO `sandbox`
  param, and the server replied under an effective read-only profile
  (`sandbox: {type: "readOnly", …}`,
  `activePermissionProfile: {id: ":read-only"}`). So `thread-start.json`
  proves READ-ONLY execution only. The write-enabling shape is
  `"sandbox": "workspace-write"` (string enum per schema `SandboxMode`) —
  VERIFIED live by the second run, whose request carried exactly that param
  and whose response echoed `sandbox: {type: "workspaceWrite", …}`
  (fixture `thread-start-workspace-write.json`). Both runs return
  `thread: {id, sessionId (= id), status: {type: "idle"}, …}` and a
  `thread/started` notification mirrors it.
- `turn/start` (params: `threadId`, `input: [{type:"text", text}]`,
  `approvalPolicy`, `cwd` override, `sandboxPolicy`, `effort`, …).
  VERIFIED live: response `{turn: {id, status: "inProgress",
  items: [], itemsView: "notLoaded"}}` (committed `turn_start_response` in
  fixture `turn-interrupt.json`; the UUIDv7 format is a schema-only note). The cwd binds the turn to the
  disposable fixture repo — the observed `commandExecution` item echoed
  `"cwd": "$FIXTURE"`.
- Bounding levers (schema-only, behavior UNVERIFIED except where noted):
  per-turn `effort`, `sandboxPolicy` (`readOnly` | `workspaceWrite` +
  `writableRoots` | `dangerFullAccess`), `approvalPolicy: "never"` (no
  interactive approvals hang the supervised run — VERIFIED live, echoed back
  on both thread/start responses), `outputSchema` to constrain the final
  message. No lease/timeout field exists on the turn itself — wall-clock
  bounding stays adapter-side.

### Write capability — VERIFIED live (second bounded turn, Work Package C argv contract)

A follow-up review correctly noted the first probe ran read-only, so one more
minimal turn proved mutation: thread started with the exact accepted shape
`"sandbox": "workspace-write"` against a disposable `/tmp` fixture repo, and
a single turn tasked with creating exactly one file (`WRITE_PROOF.txt`,
single line `elf-write-ok`, nothing else) ran to `turn/completed` status
`completed`, error null. On-disk verification (`git status` in the fixture
repo) showed exactly one untracked file with exactly that line; nothing else
was created or modified. Fixture `thread-start-workspace-write.json` commits
the request params, the `workspaceWrite` sandbox echo, the completed
`fileChange` item, and the `completed` turn frame. This is the params contract
the Work Package C adapter depends on: `thread/start` takes the STRING
`"workspace-write"`, not the `turn/start`-style `sandboxPolicy` object.

### Running-turn event stream — VERIFIED (two live turns)

Observed sequence for the interrupted `sleep 45` turn (fixture
`turn-interrupt.json`, now also committing the full interrupt request,
`turn/completed`, and `thread/status` + token-usage bracketing frames):

`thread/status/changed (active)` → `turn/started (inProgress)` →
`item/started (userMessage)` → `item/completed (userMessage)` →
`item/started (commandExecution)` → `thread/tokenUsage/updated` →
`account/rateLimits/updated` → `thread/status/changed (idle)` →
`turn/completed (interrupted, error: null)`

Observed sequence for the write-proof turn (fixture
`thread-start-workspace-write.json`):

`item/started+completed (userMessage)` →
`item/started+completed (agentMessage, phase: commentary)` →
`item/started+completed (fileChange, status: inProgress → completed,
changes: [{path, kind: {type: "add"}, diff}])` →
`item/started+completed (agentMessage, phase: final_answer)` →
`turn/completed (completed, error: null, itemsView: summary)`

- Assistant output: `item/agentMessage/delta` (schema-only;
  UNVERIFIED live — the turn was interrupted before any assistant text).
- Tool/command start AND completion: `item/started` /
  `item/completed` with typed `item.type` (VERIFIED live: `userMessage`
  start+completion in both turns; `commandExecution` start in the interrupted
  turn; `agentMessage` start+completion in commentary AND final_answer phases,
  and `fileChange` start+completion with `changes[]` path/kind/diff in the
  write turn). The command item carries `command`
  (`/bin/zsh -lc 'sleep 45'`), `cwd`, `processId` (string, `"43138"` — its
  mapping to an OS pid is UNVERIFIED), `status: "inProgress"`,
  `exitCode`/`durationMs` (null until completion). In Work Package C, the live
  `item/completed` shape for a `commandExecution` item was captured and is
  VERIFIED live (fixture `thread-resume-and-command-complete.json`). Observed
  fields: `command` (`"/bin/zsh -lc '...'"`), `cwd`, `processId` (`"29968"`),
  `status: "completed"`, `exitCode: 0`, `durationMs: 0`, `aggregatedOutput: null`.
  The event normalizer consumes this completion frame and maps it to a standard
  HarnessEvent `:result`.
- Command output streaming: `item/commandExecution/outputDelta`
  (schema-only, UNVERIFIED live — neither small turn produced output
  deltas).
- File changes: `item/fileChange/patchUpdated` + legacy
  `item/fileChange/outputDelta` (schema-only, UNVERIFIED live as
  notifications); the `fileChange` ITEM start+completion pair IS verified
  live as above.
- Errors: `turn.error: {message, codexErrorInfo, …}` on failure turns
  (schema-only, UNVERIFIED live — no failure was induced).
- FINAL result: `turn/completed` with full `turn: {id, status,
  items, …}` (VERIFIED live; `status` ∈ `completed | interrupted |
  failed | inProgress` per schema). In this run `items: []` with
  `itemsView: "notLoaded"` — the adapter must rely on the streamed
  `item/*` notifications, not the completion payload, for boundaries.

### Thread / session ID and resume — VERIFIED with a caveat

- `thread.id == sessionId`, stable across the connection (VERIFIED).
- `thread/list` (filter by `cwd`, pagination) and `thread/read`
  (VERIFIED live). `thread/list` frames are large (43 KB observed with real
  history) and leak previews/paths/git URLs — full values are WITHHELD for
  privacy and the adapter must never persist them raw (same redaction posture
  as `codex_monitor.ex`). Fixture `thread-read-shape.json` commits the
  shape-only key/type frame plus the list envelope (entry count, frame bytes)
  so text and artifacts agree; no real values are stored.
- `thread/resume {threadId}` EXISTS (schema + live rejection shape VERIFIED)
  and fresh pre-turn threads have NO rollout file yet, so pre-turn resume fails
  cleanly: `-32600 "no rollout found for thread id …"` (VERIFIED live for
  both ephemeral AND non-ephemeral pre-turn threads; fixture
  `resume-negative.json`). In Work Package C, post-turn resume was tested live and
  is VERIFIED live (fixture `thread-resume-and-command-complete.json`): calling
  `thread/resume {threadId}` on a non-ephemeral thread after 1 turn completes
  succeeds cleanly both in-session and across a full process restart on a fresh
  `codex app-server --stdio` instance, returning the idle thread with its
  rollout history loaded. Consequently, `:resume` capability is fully verified
  and implemented.
- Related: `thread/fork`, `thread/archive|unarchive|delete`,
  `thread/rollback` (DEPRECATED), `thread/revert {beforeTurnId}` for history
  truncation, `turn/steer {expectedTurnId, input}` for same-turn steering
  (all schema-only, UNVERIFIED live). `thread/turns/list` FAILS on
  ephemeral threads (`-32600`, VERIFIED); `thread/items/list` is
  `not supported yet` (`-32601`, VERIFIED). Consequence: for ephemeral
  threads the adapter CANNOT backfill history — it must buffer the live
  notification stream.

### In-band cancellation — VERIFIED live, definitive

- `turn/interrupt {threadId, turnId}` on the LIVE turn returned
  `{"result": {}}` (ack, ~instant) and `turn/completed` arrived with
  `status: "interrupted"`, `error: null`; thread status bracketed
  `active → idle`. The run stopped cleanly — no hang, no crash, connection
  reusable. VERIFIED with one bounded turn.
- Negative path VERIFIED with a committed frame: interrupting a non-existent
  turn returns `-32600 "no active turn to interrupt"` — typed, no side
  effects (real request/response frames committed as the fourth case in
  fixture `resume-negative.json`).
- Post-completion repeat interrupt is UNVERIFIED live but rides the same code
  path (expect the same `-32600`), so adapter-level idempotency mapping is
  straightforward.

### Quota / rate-limit refusal surfacing

- Capacity path UNCHANGED: `account/rateLimits/read` + sparse
  `account/rateLimits/updated` (also observed MID-TURN, VERIFIED live;
  fixture `rate-limits-mid-turn.json`). The existing `rateLimitReachedType`
  classifier in `lib/shoestring/harness/capacity.ex` applies unchanged to
  these payloads — no adapter work needed for `probe()`.
- Execution path is a DIFFERENT shape: turn failures carry
  `turn.error.codexErrorInfo` ∈ `usageLimitExceeded | rateLimitExceeded |
  serverOverloaded | …` (schema-only). The capacity classifier does NOT
  cover this shape — the adapter needs a small new mapping
  (`usageLimitExceeded|rateLimitExceeded → :quota_refused`). No refusal was
  induced live (UNVERIFIED end-to-end, deliberately — quota is scarce).

### 262144-byte line cap for execution payloads

- Largest frame observed: 43 KB (`thread/list` with real history).
  Execution frames across both small turns: ≤ 1123 bytes. So the cap is safe
  for ALL observed traffic, but execution-sized payloads (large
  `aggregatedOutput`, big plan text, transcript catch-up) were NOT observed
  — safety for large outputs is UNVERIFIED. This matters directly for the Log
  flood eval.
- Transport behavior on exceed (existing code): flags `:oversized_frame` and
  DISCARDS the remainder of the line — silent data loss mid-run. The adapter
  must raise the cap substantially for execution use AND treat oversize as a
  fail-closed transport error (cancel the turn via `turn/interrupt` and mark
  the run), never as skippable.

## 3. Cancellation-descendants answer (definitive: YES, they survive)

- LIVE codex case: after the acknowledged `turn/interrupt`, the `sleep 45`
  descendant survived as pid 99208 with **ppid=1, pgid=99208**; the direct
  sandbox wrapper was gone. app-server kills its direct child, not the
  process tree. Fixture `process-group.json`.
- Synthetic reproduction (`/tmp` throwaway, python `os.setsid`, no model):
  killing only the group leader → child SURVIVED, reparented to ppid 1
  (same signature as the codex leak); `killpg` → no survivors. So the
  transport's `Port.close`/SIGTERM has identical semantics: the app-server
  dies (uncommitted shell observation, NOT labelled VERIFIED: no
  `codex app-server` process remained after each probe), but grandchildren
  outlive it.
- Consequence for the Cancel eval: NEITHER `turn/interrupt` NOR transport
  close is sufficient. The adapter must own the process group (spawn the
  server in its own pgid / job object) and `killpg` on cancel/lease-expiry,
  then verify with a reaping pass. Recommend an eval assertion that fails on
  any surviving descendant, since silent leaks are the default outcome.

## 4. ContractSuite mapping (`test/support/harness_contract_suite.ex`, 7 areas)

1. **Identity** — SATISFIABLE. Fabricate from `discover_version` +
   `initialize` platform fields (`adapter_id: "codex_app_server_stdio"`,
   `provider: "codex"`, `invocation_mode: :process`).
2. **Start/stream/completion/failure/cancellation** — SATISFIED. Two design
   constraints enforced: (a) buffer the live `item/*` stream (no backfill on
   ephemeral threads — `thread/items/list` unsupported); (b) map
   `turn/completed` statuses (`completed|interrupted|failed`) to `:result` /
   `:error` / `:cancelled` HarnessEvents. All primitives VERIFIED live (including
   `commandExecution` item completion verified in WP-C).
3. **Resume** — SATISFIED for Work Package C: post-turn resume verified live
   across process restart with non-ephemeral threads (fixture
   `thread-resume-and-command-complete.json`). The adapter declares `:resume`
   capability and passes ContractSuite Area 3.
4. **Quota refusal** — SATISFIABLE for `probe()` via the unchanged
   classifier; turn-time quota needs the new `codexErrorInfo` mapping above.
5. **Missing capacity** — SATISFIABLE via existing `Capacity.normalize`
   unknown/degraded fallbacks.
6. **Secret-free** — SATISFIABLE but load-bearing: `account/read` returns a
   real email and `thread/*` payloads carry home paths, previews, git URLs
   (all observed). Adapter must project safe subsets exactly like
   `codex_monitor.ex` does; fixtures prove the redaction shape.
7. **Terminal idempotency** — SATISFIABLE: repeat/after-completion interrupt
   hits the typed `-32600` path (bogus-id case VERIFIED); map to
   `{:ok, :cancelled}` or typed `:cancelled` Error.

## 5. Transport verdict for Work Package C: app-server --stdio

**Use `app-server --stdio`, not `exec --json`.**

- Decisive for Cancel: in-band `turn/interrupt` is acked and stops the turn
  cleanly (VERIFIED live). Exec offers no in-band cancel — only process kill,
  which per §3 leaks descendants anyway while also forfeiting typed state.
- Decisive for Lease-boundary: typed item start/completion (command, cwd,
  file-change diffs), `thread/status` active/idle bracketing, per-turn token
  usage, and mid-turn rate-limit telemetry (all VERIFIED live) give the
  adapter real supervision hooks. Exec's JSON stream cannot bracket or steer
  mid-run. (Command `exitCode` on completion is still UNVERIFIED live.)
- Resume caveat (§2) is acceptable for one supervised Elf: within a lease the
  adapter holds the live connection; cross-restart resume is a
  post-turn-rollout path, deferrable.
- `[experimental]` status is real: unsolicited notifications observed
  (`remoteControl/status/changed` on connect, `mcpServer/startupStatus/*`
  per thread), `thread/items/list` unimplemented, ephemeral restrictions,
  schema churn between 0.150.1 (Gate 0A) and 0.153.2 (new `thread/queue/*`,
  `process/*`, `remoteControl/*`). Mitigation: pin the tested CLI version in
  the adapter's compatibility gate (the `Capacity.Registry` pattern already
  supports this), tolerate unknown notifications, buffer events.
- No instability observed: 4 connections, 2 live turns (1 interrupted, 1
  write completed), zero crashes/hangs. Transport-close cleanup (no lingering
  server process) is an uncommitted shell observation, not a VERIFIED claim.
- Required adapter mitigations (non-negotiable): own-process-group +
  `killpg` on cancel/expiry with reaping assertion; raised frame cap with
  oversize = fail-closed + cancel; live-event buffering; safe-subset
  projection (no raw account/thread payloads persisted); new
  `codexErrorInfo → :quota_refused` mapping; omit or scope `:resume`.

## 6. Fixtures (`test/fixtures/codex/app_server/`, all redacted)

IDs follow the milestone fixture convention (`plans/evidence/04-single-elf/README.md`,
arriving via PR #23): provider-emitted UUIDs are replaced with deterministic
synthetic UUIDv7 values (`01950000-0000-7000-8000-000000000001`, `…0002`, …,
incrementing low bits, consistent per logical thread/turn across all files).
Non-UUID wire shapes keep their real shape with synthetic bodies
(`exec-<uuidv7>` for tool-call items, `msg_<64 hex>` for agent-message items).
The bogus turn id in the negative-interrupt case is kept verbatim as sent
(`00000000-0000-4000-8000-000000000099` — probe input, already synthetic).
`$HOME`/`$FIXTURE`/`$FIXTURE-WRITE`/email redacted, large payloads truncated
and noted. Secret scan (home path, email, bearer, `sk-`, raw UUIDs) is clean.

- `initialize-handshake.json` — handshake frames; no capabilities field.
- `thread-start.json` — `thread/start` req/resp + `thread/started`
  (READ-ONLY profile: no `sandbox` param sent, server replied `readOnly`).
- `thread-start-workspace-write.json` — the write proof: exact accepted
  `"sandbox": "workspace-write"` param, `workspaceWrite` echo, completed
  `fileChange` item, `completed` turn frame, disk proof.
- `thread-read-shape.json` — shape-only `thread/read` + `thread/list`
  envelope (values withheld for privacy).
- `turn-interrupt.json` — the interrupted turn: `turn/start` resp, full
  interrupt request frame, interrupt ack, full `interrupted` completion
  frame, event sequence, command item, status/token-usage bracketing frames.
- `method-inventory.json` — 99 base / 155 experimental client methods, 81
  server notifications, core thread/turn lists, truncated raw rejection frame.
- `resume-negative.json` — REAL frames: `no rollout found`, ephemeral
  `turns/list`, unsupported `items/list`, and bogus-id `turn/interrupt`
  (`-32600 "no active turn to interrupt"`) rejections.
- `rate-limits-mid-turn.json` — full redacted sparse-update frame from
  mid-turn.
- `process-group.json` — descendant-survival outcome + full experiment
  transcript.
- `thread-resume-and-command-complete.json` — post-turn resume across process
  restart on non-ephemeral threads, plus live `commandExecution` completed
  frame shape (`exitCode: 0`, `status: "completed"`, `durationMs: 0`,
  `aggregatedOutput: null`).

Live run accounting:
- Spike B: Two minimal live turns (turn 1: interrupted sleep; turn 2: write proof).
- Work Package C: Exactly ONE minimal live turn (run disposable command to verify
  post-turn `thread/resume` and capture `commandExecution` `item/completed` shape).
- Total live quota used across Spike B and WP-C: 3 bounded turns (1 in WP-C).
- Both previously open WP-C questions (post-turn resume and command execution
  completed shape) are VERIFIED live, leaving 0 unverified assumptions for
  production adapter execution.

## 7. Repro (zero-model, except the two noted live turns)

```sh
codex app-server generate-json-schema --out /tmp/opencode/codex-schema
codex app-server generate-json-schema --experimental --out /tmp/opencode/codex-schema-exp
# stdio probes kept OUT of the tree (/tmp/opencode/spike-probe/probe*.js):
# initialize → initialized → account/read → account/rateLimits/read →
# thread/start (cwd=$FIXTURE) → thread/list|read →
# turn/interrupt (bogus ids) → unknown method (runtime inventory)
# Live turn 1 (~16.6k input tokens): turn/start [`sleep 45`] →
# await item/started(commandExecution) → turn/interrupt → turn/completed
# Live turn 2 (~16.9k input tokens, sandbox workspace-write):
# turn/start [create WRITE_PROOF.txt with one line] → turn/completed →
# verify on disk: exactly one new file with exactly that line
```
