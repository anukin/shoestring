# Codex app-server Quota Refusal Shape Capture

**Milestone**: `plans/milestones/04-single-elf.md`  
**Date**: 2026-09-06  
**CLI**: `codex-cli 0.153.4`  
**Status**: VERIFIED live (wire frames & normalizer unit mapping)  
**Fixture Files**:
- App-server capture: `plans/evidence/04-single-elf/fixtures/codex/app-server-quota-refusal.json` (`.jsonl`)
- Exec scratch capture: `plans/evidence/04-single-elf/fixtures/codex/exec-quota-refusal.jsonl`  
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

`plans/evidence/04-single-elf/codex-app-server.md:231-235` previously recorded this mapping as **SCHEMA-ONLY**, because no quota refusal had been induced live during earlier spikes. Furthermore, an execution capture of `codex exec --json` during quota exhaustion (`_scratch/exec-refusal-raw.jsonl`, committed as `plans/evidence/04-single-elf/fixtures/codex/exec-quota-refusal.jsonl`) revealed that the `exec` transport emits **prose-only** errors without error codes or structured metadata:

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

This field is present on the wire in **both**:
1. The server push notification `method: "error"`, and
2. The terminal turn completion notification `method: "turn/completed"` under `params.turn.error`.

### Impact on Normalization: VERIFIED Unit Mapping (Elf Runtime UNVERIFIED)
Because `codexErrorInfo` is populated with `"usageLimitExceeded"`, the clause in `Shoestring.Harness.CodexAppServer.EventNormalizer.normalize_codex_error/1`:

```elixir
info when info in ["usageLimitExceeded", "rateLimitExceeded"] ->
  :quota_refused
```

is **VERIFIED** against this live captured wire payload via a regression test in `test/shoestring/harness/codex_app_server/event_normalizer_test.exs` consuming `plans/evidence/04-single-elf/fixtures/codex/app-server-quota-refusal.jsonl`. The test proves that `EventNormalizer` maps this real refusal frame to `:quota_refused` with code `"usageLimitExceeded"`.

**Scope boundary**: This verification establishes that the normalizer parses and maps the captured wire bytes correctly. No full Elf execution run or adapter session lifecycle ran during quota exhaustion; adapter-level and Elf-level behavior under live quota refusal remains **UNVERIFIED**.

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

> **REPO-INSPECTION note on `method: "error"`**: At commit `e168261`, `Shoestring.Harness.CodexAppServer.EventNormalizer` has no `do_normalize` clause for `method: "error"`. Under code inspection (`event_normalizer.ex:497-507`), this standalone notification falls through to the catch-all clause `{:skip, :unhandled_method}` — it is neither logged nor mis-normalized. Error classification rides solely on the subsequent `turn/completed` frame.

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
| **Data Provenance** | Operator scratch capture (`_scratch/exec-refusal-raw.jsonl`), committed as `exec-quota-refusal.jsonl` | Live foreground capture, committed as `app-server-quota-refusal.json` / `.jsonl` |
| **Error Type** | Prose-only | Structured + Prose |
| **`error.codexErrorInfo`** | **Absent** (null/undefined) | **Present**: `"usageLimitExceeded"` |
| **Turn Status** | `"turn.failed"` | `"turn/completed"` with `turn.status: "failed"` |
| **Pre-failure Capacity Push** | None | `account/rateLimits/updated` (`balance: "0"`) |
| **Pre-failure Thread State** | N/A | `thread/status/changed` (`status.type: "systemError"`) |
| **Adapter Normalization** | Requires prose regex / heuristic | Maps directly via `codexErrorInfo` |

> **Provenance & Attribution**: The `codex exec --json` data was captured in operator scratch (`_scratch/exec-refusal-raw.jsonl`) during the same quota exhaustion window. It has been committed as a redacted fixture at `plans/evidence/04-single-elf/fixtures/codex/exec-quota-refusal.jsonl` so that both sides of the comparison are permanently verifiable in repository history.

This structural divergence justifies the architectural selection of `codex app-server --stdio` as the primary execution transport for Iteration 4: it maintains protocol-level distinction between quota exhaustion and arbitrary agent failures.

---

## 5. Label Discipline

- **VERIFIED live (wire frames)**:
  - `codex app-server --stdio` turn refusal wire frame carries `codexErrorInfo: "usageLimitExceeded"` on `turn/completed` (`turn.error`) (committed fixture: `plans/evidence/04-single-elf/fixtures/codex/app-server-quota-refusal.jsonl`).
  - `codex app-server --stdio` emits wire `error` notification with `params.error.codexErrorInfo: "usageLimitExceeded"`.
  - `account/rateLimits/updated` is pushed prior to turn failure with `credits.balance: "0"` and `credits.hasCredits: false`.
  - `thread/status/changed` transitions to `{"type": "systemError"}` on refusal.

- **VERIFIED (normalizer unit mapping)**:
  - `Shoestring.Harness.CodexAppServer.EventNormalizer.normalize/4` produces `Error.new(:quota_refused, "usageLimitExceeded", message)` when fed the live captured `turn/completed` frame (locked by golden test in `test/shoestring/harness/codex_app_server/event_normalizer_test.exs`).

- **REPO-INSPECTION**:
  - `method: "error"` push notification falls to `{:skip, :unhandled_method}` in `EventNormalizer` at `e168261` (no clause in `do_normalize`).

- **SCHEMA-ONLY**:
  - `codexErrorInfo: "rateLimitExceeded"` (present in schema and normalizer match list, but not observed in this specific quota window).
  - `codexErrorInfo: "serverOverloaded"` (schema variant).
  - `codexErrorInfo: "unauthorized"` (schema variant).

- **UNVERIFIED**:
  - Full Elf execution run or adapter session lifecycle handling of live quota refusal (no Elf ran; testing is unit normalization on captured wire bytes).
