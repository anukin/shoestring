# Codex app-server transport probe (iter4 wave-0 spike B)

Date: 2026-09-04. CLI: `codex-cli 0.153.2`. Owner: app-server --stdio
execution adapter spike (the parallel agent owns `codex exec --json`).

Question: does app-server expose THREAD/TURN methods rich enough to run and
supervise a bounded implementation run — typed item boundaries plus IN-BAND
cancellation — making it better than exec for the Cancel and Lease-boundary
evals?

Short answer: **yes**. `turn/interrupt` is acknowledged in-band and the turn
stops cleanly (`turn/completed` status `interrupted`), and the item stream
gives typed start/completion boundaries for commands. Both VERIFIED live with
exactly ONE bounded model turn. Descendant processes SURVIVE the interrupt, so
the adapter must kill the process group itself. Verdict: **app-server --stdio
for Work Package C**, with mitigations listed below.

Spend note: quota is scarce (account secondary window was already 79% at probe
time), so only one tiny live turn was run (prompt: run `sleep 45`, reply DONE;
interrupted after ~4.5 s). Everything else is zero-model-cost stdio probing or
static schema inspection. The single turn cost ~16.6k input tokens
(6.4k cached) per the observed `thread/tokenUsage/updated` notification. No
further live runs were made; anything not observed is marked UNVERIFIED.

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

## 2. Method / notification inventory (VERIFIED = observed live or in schema + live traffic)

### Start a bounded turn in a specified cwd — VERIFIED

- `thread/start` (params: `cwd`, `ephemeral`, `approvalPolicy`,
  `sandbox`, `model`, `modelProvider`, …). VERIFIED live: started with
  `{cwd: $FIXTURE, ephemeral: true, approvalPolicy: "never",
  sandbox: "workspace-write"}`; response echoes `cwd`, returns
  `thread: {id, sessionId (= id), status: {type: "idle"}, …}` and a
  `thread/started` notification mirrors it. Fixture `thread-start.json`.
- `turn/start` (params: `threadId`, `input: [{type:"text", text}]`,
  `approvalPolicy`, `cwd` override, `sandboxPolicy`, `effort`, …).
  VERIFIED live: response `{turn: {id (UUIDv7), status: "inProgress",
  items: [], itemsView: "notLoaded"}}`. The cwd binds the turn to the
  disposable fixture repo — the observed `commandExecution` item echoed
  `"cwd": "$FIXTURE"`.
- Bounding levers (schema-VERIFIED, behavior UNVERIFIED): per-turn `effort`,
  `sandboxPolicy` (`readOnly` | `workspaceWrite` + `writableRoots` |
  `dangerFullAccess`), `approvalPolicy: "never"` (no interactive approvals
  hang the supervised run), `outputSchema` to constrain the final message.
  No lease/timeout field exists on the turn itself — wall-clock bounding stays
  adapter-side.

### Running-turn event stream — VERIFIED (one live turn)

Observed sequence for the interrupted `sleep 45` turn (fixture
`turn-interrupt.json`):

`thread/status/changed (active)` → `turn/started (inProgress)` →
`item/started (userMessage)` → `item/completed (userMessage)` →
`item/started (commandExecution)` → `thread/tokenUsage/updated` →
`account/rateLimits/updated` → `thread/status/changed (idle)` →
`turn/completed (interrupted, error: null)`

- Assistant output: `item/agentMessage/delta` (schema-VERIFIED;
  UNVERIFIED live — the turn was interrupted before any assistant text).
- Tool/command start AND completion: `item/started` /
  `item/completed` with typed `item.type` (VERIFIED live for `userMessage`
  start+completion and `commandExecution` start). The command item carries
  `command` (`/bin/zsh -lc 'sleep 45'`), `cwd`, `processId` (string,
  `"43138"` — its mapping to an OS pid is UNVERIFIED), `status:
  "inProgress"`, `exitCode`/`durationMs` (null until completion).
- Command output streaming: `item/commandExecution/outputDelta`
  (schema-VERIFIED, UNVERIFIED live — no output produced before interrupt).
- File changes: `item/fileChange/patchUpdated` + legacy
  `item/fileChange/outputDelta` (schema-VERIFIED, UNVERIFIED live).
- Errors: `turn.error: {message, codexErrorInfo, …}` on failure turns
  (schema-VERIFIED, UNVERIFIED live — no failure was induced).
- FINAL result: `turn/completed` with full `turn: {id, status,
  items, …}` (VERIFIED live; `status` ∈ `completed | interrupted |
  failed | inProgress` per schema). In this run `items: []` with
  `itemsView: "notLoaded"` — the adapter must rely on the streamed
  `item/*` notifications, not the completion payload, for boundaries.

### Thread / session ID and resume — VERIFIED with a caveat

- `thread.id == sessionId`, stable across the connection (VERIFIED).
- `thread/list` (filter by `cwd`, pagination) and `thread/read`
  (VERIFIED live). `thread/list` frames are large (43 KB observed with real
  history) and leak previews/paths/git URLs — the adapter must never persist
  them raw (same redaction posture as `codex_monitor.ex`).
- `thread/resume {threadId}` EXISTS (schema + live rejection shape VERIFIED)
  but fresh pre-turn threads have NO rollout file yet, so resume fails
  cleanly: `-32600 "no rollout found for thread id …"` (VERIFIED live for
  both ephemeral AND non-ephemeral pre-turn threads; fixture
  `resume-negative.json`). Resume-after-restart therefore requires a
  persisted (post-first-turn) rollout; post-turn resume itself is UNVERIFIED
  (would cost a model turn to set up — explicitly skipped).
- Related: `thread/fork`, `thread/archive|unarchive|delete`,
  `thread/rollback` (DEPRECATED), `thread/revert {beforeTurnId}` for history
  truncation, `turn/steer {expectedTurnId, input}` for same-turn steering
  (all schema-VERIFIED, UNVERIFIED live). `thread/turns/list` FAILS on
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
- Negative path VERIFIED: interrupting a non-existent turn returns
  `-32600 "no active turn to interrupt"` — typed, no side effects.
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
  serverOverloaded | …` (schema-VERIFIED). The capacity classifier does NOT
  cover this shape — the adapter needs a small new mapping
  (`usageLimitExceeded|rateLimitExceeded → :quota_refused`). No refusal was
  induced live (UNVERIFIED end-to-end, deliberately — quota is scarce).

### 262144-byte line cap for execution payloads

- Largest frame observed: 43 KB (`thread/list` with real history).
  Execution frames in the tiny run: ≤ 1123 bytes. So the cap is safe for ALL
  observed traffic, but execution-sized payloads (large `aggregatedOutput`,
  big plan text, transcript catch-up) were NOT observed — safety for large
  outputs is UNVERIFIED. This matters directly for the Log flood eval.
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
  dies (VERIFIED: no `codex app-server` process remained after each probe),
  but grandchildren outlive it.
- Consequence for the Cancel eval: NEITHER `turn/interrupt` NOR transport
  close is sufficient. The adapter must own the process group (spawn the
  server in its own pgid / job object) and `killpg` on cancel/lease-expiry,
  then verify with a reaping pass. Recommend an eval assertion that fails on
  any surviving descendant, since silent leaks are the default outcome.

## 4. ContractSuite mapping (`test/support/harness_contract_suite.ex`, 7 areas)

1. **Identity** — SATISFIABLE. Fabricate from `discover_version` +
   `initialize` platform fields (`adapter_id: "codex_app_server_stdio"`,
   `provider: "codex"`, `invocation_mode: :process`).
2. **Start/stream/completion/failure/cancellation** — SATISFIABLE with two
   design constraints: (a) buffer the live `item/*` stream (no backfill on
   ephemeral threads — `thread/items/list` unsupported); (b) map
   `turn/completed` statuses (`completed|interrupted|failed`) to `:result` /
   `:error` / `:cancelled` HarnessEvents. All primitives VERIFIED except
   failure-turn shape (schema only).
3. **Resume** — NOT satisfiable as written: the suite does start→immediate
   resume, and fresh pre-turn threads have no rollout (`no rollout found`
   VERIFIED). Adapter must either omit `:resume` initially or scope it to
   persisted (post-turn) thread ids, which are UNVERIFIED live.
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
  exit code), `thread/status` active/idle bracketing, per-turn token usage,
  and mid-turn rate-limit telemetry (all VERIFIED live) give the adapter real
  supervision hooks. Exec's JSON stream cannot bracket or steer mid-run.
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
- No instability observed: 3 connections, 1 live interrupted turn, zero
  crashes/hangs; server exits cleanly on transport close.
- Required adapter mitigations (non-negotiable): own-process-group +
  `killpg` on cancel/expiry with reaping assertion; raised frame cap with
  oversize = fail-closed + cancel; live-event buffering; safe-subset
  projection (no raw account/thread payloads persisted); new
  `codexErrorInfo → :quota_refused` mapping; omit or scope `:resume`.

## 6. Fixtures (`test/fixtures/codex/app_server/`, all redacted)

IDs remapped to THREAD-n/TURN-n/EXEC-n, `$HOME`/`$FIXTURE`/email redacted,
large payloads truncated and noted. Secret scan (home path, email, bearer,
`sk-`, raw UUIDs) is clean.

- `initialize-handshake.json` — handshake frames; no capabilities field.
- `thread-start.json` — `thread/start` req/resp + `thread/started`.
- `turn-interrupt.json` — the one live turn: `turn/start` resp,
  interrupt ack, `interrupted` completion, event sequence, command item.
- `method-inventory.json` — 99 base / 155 experimental client methods, 81
  server notifications, core thread/turn lists.
- `resume-negative.json` — `no rollout found`, ephemeral `turns/list`,
  unsupported `items/list` rejections.
- `rate-limits-mid-turn.json` — sparse update keys observed mid-turn.
- `process-group.json` — descendant-survival experiment outcome.

Live run explicitly SKIPPED beyond the single interrupt turn: post-turn
`thread/resume`, failure-turn `codexErrorInfo` end-to-end, and large-payload
line-cap behavior are UNVERIFIED by choice (quota scarcity); all are marked
above with the exact evidence gap and the fixture/schema basis for the
interim conclusion. No production adapter written; `lib/` untouched.

## 7. Repro (zero-model, except the one noted live turn)

```sh
codex app-server generate-json-schema --out /tmp/opencode/codex-schema
codex app-server generate-json-schema --experimental --out /tmp/opencode/codex-schema-exp
# stdio probes kept OUT of the tree (/tmp/opencode/spike-probe/probe*.js):
# initialize → initialized → account/read → account/rateLimits/read →
# thread/start (cwd=$FIXTURE) → thread/list|read →
# turn/interrupt (bogus ids) → unknown method (runtime inventory)
# Live turn (1×, ~16.6k input tokens): turn/start [`sleep 45`] →
# await item/started(commandExecution) → turn/interrupt → turn/completed
```
