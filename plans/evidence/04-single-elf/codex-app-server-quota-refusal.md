# Codex app-server Quota Refusal Shape Capture

**Milestone**: `plans/milestones/04-single-elf.md`  
**Date**: 2026-09-06  
**CLI**: `codex-cli 0.153.4`  
**Status**: VERIFIED live  
**Fixture File**: `plans/evidence/04-single-elf/fixtures/codex/app-server-quota-refusal.json`  
**Conventions**: `plans/evidence/04-single-elf/README.md` (format-valid synthetic identifiers, zero secrets, zero machine paths)

---

## 1. Executive Summary & Core Question

### The Question
In `lib/shoestring/harness/codex_app_server/event_normalizer.ex:547-554`, turn execution error normalization includes the mapping:

```elixir
category =
  case codex_error_info do
    info when info in ["usageLimitExceeded", "rateLimitExceeded"] ->
      :quota_refused
```

`plans/evidence/04-single-elf/codex-app-server.md:231-235` previously recorded this mapping as **SCHEMA-ONLY**, because no quota refusal had been induced live during earlier spikes. Furthermore, an execution capture of `codex exec --json` during quota exhaustion (`_scratch/exec-refusal-raw.jsonl`) revealed that the `exec` transport emits **prose-only** errors without error codes or structured metadata:

```json
{"type":"error","message":"You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 8:52 PM."}
{"type":"turn.failed","error":{"message":"You've hit your usage limit..."}}
```

The question investigated here: **Does a real `codex app-server --stdio` turn refusal actually carry `codexErrorInfo`, or is it prose-only?**

### The Answer: VERIFIED LIVE
**Yes.** Unlike `codex exec --json`, the `codex app-server --stdio` transport emits structured error payloads carrying:

```json
"codexErrorInfo": "usageLimitExceeded"
```

This field is present in **both**:
1. The server notification `method: "error"`, and
2. The terminal turn completion notification `method: "turn/completed"` under `params.turn.error`.

### Impact on Normalization
Because `codexErrorInfo` is populated with `"usageLimitExceeded"`, the clause in `Shoestring.Harness.CodexAppServer.EventNormalizer.normalize_codex_error/1`:

```elixir
info when info in ["usageLimitExceeded", "rateLimitExceeded"] ->
  :quota_refused
```

is **VERIFIED live**. Live quota refusals under `codex app-server --stdio` are cleanly classified as `:quota_refused` with code `"usageLimitExceeded"`, rather than falling through to generic `:task_failed`.

---

## 2. Capture Environment & Methodology

- **Date & Window**: 2026-09-06 during an active quota-exhaustion window (reset time 20:52 PDT).
- **Platform**: macOS (Darwin arm64)
- **CLI**: `codex-cli 0.153.4`
- **Fixture Workspace**: Disposable Git repository created via `mktemp -d /tmp/codex-quota-probe-XXXXXX` and initialized with `git init`.
- **Invocation**: Foreground process execution of `codex app-server --stdio` in the fixture directory.
- **Protocol Driver**: Sent the exact JSON-RPC sequence specified in `Shoestring.Harness.CodexAppServer.Session`:
  1. `initialize` request (`id: 1`, `clientInfo: {"name": "shoestring_codex_adapter", ...}`)
  2. `initialized` notification (`params: {}`)
  3. `thread/start` request (`id: 2`, `approvalPolicy: "never"`, `sandbox: "workspace-write"`, `ephemeral: false`, `cwd: "$WORKSPACE"`)
  4. `turn/start` request (`id: 3`, `threadId: "<thread_id>"`, `input: [{"type": "text", "text": "Execute task."}]`)
- **Teardown**: Standard input closed cleanly upon receiving terminal `turn/completed`, prompting the app-server to terminate gracefully.
- **Standard Error**: Exactly 0 bytes emitted.
- **Standard Output**: 21 frames captured verbatim, redacted in accordance with `plans/evidence/04-single-elf/README.md`.

---

## 3. Observed Wire Payloads

### Terminal Error Notification (`method: "error"`)
Emitted at frame 20:

```json
{
  "method": "error",
  "params": {
    "error": {
      "message": "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 8:52 PM.",
      "codexErrorInfo": "usageLimitExceeded",
      "additionalDetails": null,
      "misalignment": null
    },
    "willRetry": false,
    "threadId": "01950000-0000-7000-8000-000000000001",
    "turnId": "01950000-0000-7000-8000-000000000002"
  },
  "emittedAtMs": 1788735107622
}
```

### Terminal Turn Completion Notification (`method: "turn/completed"`)
Emitted at frame 21:

```json
{
  "method": "turn/completed",
  "params": {
    "threadId": "01950000-0000-7000-8000-000000000001",
    "turn": {
      "id": "01950000-0000-7000-8000-000000000002",
      "items": [],
      "itemsView": "notLoaded",
      "status": "failed",
      "error": {
        "message": "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 8:52 PM.",
        "codexErrorInfo": "usageLimitExceeded",
        "additionalDetails": null,
        "misalignment": null
      },
      "startedAt": 1788735105,
      "completedAt": 1788735107,
      "durationMs": 2078
    }
  },
  "emittedAtMs": 1788735107624
}
```

### Corroborating Lifecycle Notifications
Immediately prior to the refusal error, the app server emitted two diagnostic status updates:
1. `account/rateLimits/updated` (frame 18):
   ```json
   {
     "method": "account/rateLimits/updated",
     "params": {
       "rateLimits": {
         "limitId": "premium",
         "limitName": null,
         "primary": null,
         "secondary": null,
         "credits": {
           "hasCredits": false,
           "unlimited": false,
           "balance": "0"
         },
         "individualLimit": null,
         "spendControlReached": null,
         "planType": null,
         "rateLimitReachedType": null
       }
     },
     "emittedAtMs": 1788735107622
   }
   ```
2. `thread/status/changed` (frame 19):
   ```json
   {
     "method": "thread/status/changed",
     "params": {
       "threadId": "01950000-0000-7000-8000-000000000001",
       "status": {
         "type": "systemError"
       }
     },
     "emittedAtMs": 1788735107622
   }
   ```

---

## 4. Comparison: `exec --json` vs `app-server --stdio`

| Feature / Field | `codex exec --json` (CLI) | `codex app-server --stdio` (JSON-RPC) |
| :--- | :--- | :--- |
| **Error Type** | Prose-only | Structured + Prose |
| **`error.codexErrorInfo`** | **Absent** (null/undefined) | **Present**: `"usageLimitExceeded"` |
| **Turn Status** | `"turn.failed"` | `"turn/completed"` with `turn.status: "failed"` |
| **Pre-failure Capacity Push** | None | `account/rateLimits/updated` (`balance: "0"`) |
| **Pre-failure Thread State** | N/A | `thread/status/changed` (`status.type: "systemError"`) |
| **Adapter Normalization** | Requires prose regex / heuristic | Maps directly via `codexErrorInfo` |

This structural divergence justifies the architectural selection of `codex app-server --stdio` as the primary execution transport for Iteration 4: it maintains protocol-level distinction between quota exhaustion and arbitrary agent failures.

---

## 5. Label Discipline

- **VERIFIED live**:
  - `codex app-server --stdio` turn refusal carries `codexErrorInfo: "usageLimitExceeded"` on `turn/completed` (`turn.error`).
  - `codex app-server --stdio` emits `error` notification with `params.error.codexErrorInfo: "usageLimitExceeded"`.
  - `account/rateLimits/updated` is pushed prior to turn failure with `credits.balance: "0"` and `credits.hasCredits: false`.
  - `thread/status/changed` transitions to `{"type": "systemError"}` on refusal.
  - Normalization in `Shoestring.Harness.CodexAppServer.EventNormalizer` yields `Error.new(:quota_refused, "usageLimitExceeded", message)` for this refusal shape.
- **SCHEMA-ONLY**:
  - `codexErrorInfo: "rateLimitExceeded"` (present in schema and normalizer match list, but not observed in this specific quota window).
  - `codexErrorInfo: "serverOverloaded"` (schema variant).
  - `codexErrorInfo: "unauthorized"` (schema variant).
