# Spike A: `codex exec --json` Execution Capture and Analysis

**Milestone**: `plans/milestones/04-single-elf.md`  
**Date**: 2026-09-04  
**Status**: Completed Spike / Captured Fixture Verified  
**Fixture File**: `test/fixtures/codex/execution/exec_json_success.jsonl`

---

## 1. Executive Summary & Captured Run Context

This spike evaluates the CLI invocation and JSON event stream emitted by `codex exec --json` when executing an agentic turn in a workspace.

### Environment & Invocation
- **Platform**: macOS (Darwin arm64)
- **Codex CLI**: `codex-cli`
- **Fixture Repository**: `/tmp/iter4-spike-exec-repo` (clean Git repository with one initial commit)
- **Working Command**:
  ```bash
  codex -a on-request exec --json -C /tmp/iter4-spike-exec-repo -s workspace-write "create a file hello.txt containing the word hello, then run: printf ok" < /dev/null
  ```
- **Exit Code**: `0`
- **Standard Error**: `Reading additional input from stdin...` (single notification prior to closing EOF)
- **Artifact Outcome**: `hello.txt` was created in the fixture workspace containing `hello`, and command output `ok` was captured.
- **Redaction & Anonymization**: The fixture stream contains no home directory paths, usernames, or secrets. The provider session identifier (`thread_id: "01a06fec-0fef-74f3-bf09-56502a44de4f"`) was retained as captured to preserve the real provider UUIDv7 format produced by the Codex CLI.

---

## 2. Hard Findings (Requirements on the Elf Process Launcher)

Two critical operational findings were identified during invocation testing. Both must be treated as strict architectural requirements on the Elf launcher in Work Package B, not optional nuances.

### Hard Finding 1: Standard Input (`stdin`) Must Be Explicitly Closed

- **Observed Behavior**: Running the identical command without `< /dev/null` causes the process to hang indefinitely. Stderr emits `Reading additional input from stdin...`, exactly zero JSON events are written to stdout, and the backend model is never invoked.
- **Root Cause**: According to `codex exec --help`, standard input piped to `codex exec` is interpreted as user context and appended to the prompt as a `<stdin>` block. Consequently, the CLI blocks on `read(0)` waiting for `EOF`.
- **Consequence for Iteration 4**: If the launcher creates an OS pipe or port for `stdin` without immediately closing it or sending EOF, the run turns into a live-but-silent process. This accidentally triggers the milestone's **"Quiet but working"** evaluation failure mode by launcher defect rather than model stall.
- **Launcher Requirement**: The Elf process launcher (whether using `Port.open/2`, `System.cmd/3`, `MuonTrap`, or a custom port wrapper) **must explicitly close standard input** or redirect standard input from `/dev/null` upon spawn. Under no circumstances may `stdin` be left unclosed.

### Hard Finding 2: `-a/--ask-for-approval` Is a Top-Level Global Flag, Not an `exec` Subcommand Option

- **Observed Behavior**: Passing `-a` after `exec`, such as:
  ```bash
  codex exec -s workspace-write -a on-request ...
  ```
  fails immediately with:
  ```text
  error: unexpected argument '-a' found
  ```
- **Root Cause**: The Codex CLI parses flags hierarchically. The approval policy `-a` / `--ask-for-approval` is defined on the root CLI parser, whereas `exec` defines subcommands and its own options (`-C`, `-s`, `--json`, etc.).
- **Launcher Requirement**: The command-line builder in the adapter must place top-level options before the subcommand:
  ```bash
  codex -a on-request exec --json -C <workspace> -s workspace-write "<prompt>" < /dev/null
  ```

---

## 3. Verified Event Stream & Event Vocabulary Mapping

The captured JSONL stream contains exactly 9 newline-delimited JSON objects emitted in strict sequential order.

### Discriminator Architecture
- There is **no top-level `item_type` field**.
- The root discriminator for event objects is `type`.
- For item events (`item.started` and `item.completed`), the inner discriminator is `item.type`.
- Item transitions (`started` → `completed`) are correlated across events by `item.id`.

### Event Mapping Table

| Sequence | Raw Event `type` | Raw Discriminator & Key Fields | Semantics & Payload | Normalized `Shoestring.Harness.HarnessEvent` Kind | Harness Event Fields & Details |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | `thread.started` | Top-level `type: "thread.started"`<br>`thread_id: "01a06fec-..."` | Provider session identity established. | `:lifecycle` | `provider_session_id: thread_id`<br>`extensions: %{"codex.exec:event" => "thread.started"}` |
| 2 | `turn.started` | Top-level `type: "turn.started"` | Start of model reasoning & execution turn. | `:lifecycle` | `extensions: %{"codex.exec:event" => "turn.started"}` |
| 3 | `item.completed` | `item.type: "agent_message"`<br>`item.id: "item_0"`<br>`item.text: "..."` | Agent emitted human-facing explanation / intent message before tool use. | `:output` | `extensions: %{"codex.exec:item_id" => "item_0", "codex.exec:item_type" => "agent_message", "text" => item.text}` |
| 4 | `item.started` | `item.type: "command_execution"`<br>`item.id: "item_1"`<br>`item.command: "/bin/zsh -lc ..."`<br>`item.status: "in_progress"` | Execution of shell command initiated in workspace. | `:command` | `extensions: %{"codex.exec:item_id" => "item_1", "command" => item.command, "status" => "in_progress"}` |
| 5 | `item.completed` | `item.type: "command_execution"`<br>`item.id: "item_1"`<br>`item.exit_code: 0`<br>`item.status: "completed"`<br>`item.aggregated_output: ""` | Shell command finished with return code and stdout/stderr capture. | `:command` | `extensions: %{"codex.exec:item_id" => "item_1", "command" => item.command, "exit_code" => 0, "status" => "completed", "aggregated_output" => ""}` |
| 6 | `item.started` | `item.type: "command_execution"`<br>`item.id: "item_2"`<br>`item.command: "/bin/zsh -lc 'printf ok'"`<br>`item.status: "in_progress"` | Second command initiated. | `:command` | `extensions: %{"codex.exec:item_id" => "item_2", "command" => item.command, "status" => "in_progress"}` |
| 7 | `item.completed` | `item.type: "command_execution"`<br>`item.id: "item_2"`<br>`item.exit_code: 0`<br>`item.status: "completed"`<br>`item.aggregated_output: "ok"` | Second command completed with output `"ok"`. | `:command` | `extensions: %{"codex.exec:item_id" => "item_2", "command" => item.command, "exit_code" => 0, "status" => "completed", "aggregated_output" => "ok"}` |
| 8 | `item.completed` | `item.type: "agent_message"`<br>`item.id: "item_3"`<br>`item.text: "..."` | Final explanatory agent message summarizing results. | `:output` | `extensions: %{"codex.exec:item_id" => "item_3", "codex.exec:item_type" => "agent_message", "text" => item.text}` |
| 9 | `turn.completed` | Top-level `type: "turn.completed"`<br>`usage: %{input_tokens: ..., ...}` | Model turn finalized; token telemetry provided; terminal event of the run. | `:result` | `result: %{status: "completed", artifact_id: nil}`<br>`extensions: %{"usage" => usage}` |

---

## 4. Safe-Boundary Analysis for Lease Non-Renewal

A core requirement of Milestone 04 is the safe termination or quiescence of an Elf when its execution lease expires and cannot be renewed.

### Evaluation of Candidate Boundaries
1. **`item.completed` (Command Execution Boundary)**:
   - **Recommendation**: **Unsafe.**
   - **Analysis**: In the captured run, the model executed `item_1` (`printf 'hello' > hello.txt`), which completed, followed immediately by `item_2` (`printf ok`), and then final message `item_3`. An agent turn frequently consists of multiple interdependent steps (e.g., creating a module, running a test suite, rolling back on failure).
   - If the supervisor intercepts at `item.completed` and halts the process, the workspace is left in an intermediate, partial, and potentially corrupted state.
   - More crucially, `codex exec` does not offer an API to "pause between items". Halting at `item.completed` requires sending a hard signal (SIGTERM/SIGKILL) to the running CLI process while it is preparing its next action.
2. **`turn.completed` (Turn Finalization Boundary)**:
   - **Recommendation**: **Safe.**
   - **Analysis**: `turn.completed` indicates that the agent has finished its complete sequence of actions for the given turn, all child shell processes have exited, final agent messages have been delivered, and token counts have been reported.
   - For a one-shot `codex exec` invocation, `turn.completed` is the natural terminal event immediately preceding process exit (`code 0`).
   - For multi-turn runs, `turn.completed` is the only point where the workspace is in a self-consistent state, ready for human or supervisor checkpointing.

**Conclusion**: The only safe boundary for lease non-renewal or voluntary quiescence is **`turn.completed`**. If the lease expires prior to `turn.completed`, the supervisor must classify the condition as a deadline overrun and initiate structured cancellation.

---

## 5. Final Result and Success vs. Failure Classification

- **Observed Terminal State**: `turn.completed` with CLI process exit code `0`.
- **Harness Mapping**: Normal completion maps to `Shoestring.Harness.HarnessEvent` with `kind: :result` and `result: %{status: "completed", artifact_id: nil}`.
- **Distinguishing Failures**:
  - **Tool/Command Failure**: An individual command may fail (e.g., non-zero exit code in `item.completed`), but the turn itself may succeed if the model handles the error or reports it to the user.
  - **Turn Failure**: In the event of an unrecoverable model or runtime error (such as a rate limit, context overflow, prompt rejection, or process crash), the stream behavior is **UNVERIFIED**. We expect either:
    1. A non-zero CLI exit code with error text on `stderr`.
    2. An event with `type: "error"` or `type: "turn.failed"`.
  - **Adapter Responsibility**: The adapter must verify both the stream terminal event and the OS process exit code. A non-zero exit code without a clean `turn.completed` must be normalized to `{:error, %Shoestring.Harness.Error{category: :task_failed, ...}}` or `:transport`.

---

## 6. File and Artifact Events

- **Capture Finding**: `codex exec --json` emitted **zero file-modification or artifact events**.
- **Mechanism**: The file `hello.txt` was created strictly by spawning `/bin/zsh -lc "printf 'hello' > hello.txt"` as a child shell under `command_execution`. Codex did not track or report workspace mutations as structured stream events.
- **Implication for Milestone 04**:
  - Milestone 04 requires tracking file/artifact modifications.
  - Because provider stream events cannot be relied upon for filesystem observability, the Elf runtime **must derive artifact changes from Git worktree state** (e.g., inspecting `git status --porcelain`, `git diff`, or commit trees before and after the execution turn).
  - An event of kind `:artifact` will be produced synthetically by the Shoestring Elf lifecycle reconciler, not directly translated from the Codex JSON stream.

---

## 7. Hidden Reasoning and Model Thoughts

- **Capture Finding**: The captured usage block reported `reasoning_output_tokens: 0`. No `item` with a reasoning or thought type was present in the JSON stream.
- **Implication**: It remains **UNVERIFIED** whether reasoning-heavy models (e.g., `o1`, `o3-mini`, or configurations with extended thinking) emit distinct raw thought items.
- **Invariant Requirement**: To preserve Shoestring's strict transcript-free and secret-free event contract (`Shoestring.Harness.ContractSuite.assert_secret_free/3`), any future reasoning item or private scratchpad block emitted by a model must be discarded or scrubbed before the event is normalized and persisted.

---

## 8. Capacity and Usage Telemetry

- **Captured Token Block**:
  ```json
  "usage": {
    "input_tokens": 34710,
    "cached_input_tokens": 29184,
    "cache_write_input_tokens": 0,
    "output_tokens": 128,
    "reasoning_output_tokens": 0
  }
  ```
- **Relevance to Iteration 3 Capacity Architecture**:
  - In Iteration 3, capacity gating is driven by the account-level primary (5-hour) and secondary (7-day) sliding window percentages queried via the Codex App Server (`account/rateLimits/read`).
  - `codex exec --json` usage telemetry **does not provide rate-limit sliding windows or reset timestamps**.
  - However, it provides vital real-time operational metrics:
    1. **Per-Turn Cost / Consumption**: Exact input, cached, and output token counts per task execution.
    2. **Cache Hit Efficiency**: In this single turn, 29,184 out of 34,710 input tokens were cached (~84.1% cache hit rate).
    3. **Intermediate Consumption Telemetry**: Provides leading indicators of token burn between periodic App Server capacity probes.

---

## 9. Cancellation and Process Hierarchy Risks

- **CLI Capability**: `codex exec` provides **no CLI flag or interactive mechanism for in-flight cancellation**.
- **Termination Mechanism**: Cancellation must be executed via OS process termination (`SIGTERM` followed by a grace period and `SIGKILL`).
- **Process Group & Descendant Risk**:
  - The captured execution shows that commands are run via `/bin/zsh -lc "<command>"`.
  - Codex spawns a child shell, which in turn spawns tools, compilers, test runners, or long-running daemons.
  - Sending `SIGTERM` only to the parent `codex` process risks leaving orphaned child processes running in the workspace background.
- **Launcher Requirement (Work Package B)**: The Elf launcher must launch `codex` in its own **process group** (e.g., `setpgid`) and issue cancellation signals to the entire process group (`kill(-pgid, SIGTERM)` / `kill(-pgid, SIGKILL)`).

---

## 10. `Shoestring.Harness.ContractSuite` Compatibility

Evaluating `codex exec --json` against the 7 test areas defined in `test/support/harness_contract_suite.ex`:

| Contract Area | Suite Test Assertion | `codex exec --json` Capabilities | Verdict & Architectural Strategy |
| :--- | :--- | :--- | :--- |
| **1. Identity** | `assert_identity/1` | Exposes adapter version, provider `"codex"`, mode `:process`. Declares capabilities `[:cancel]`. | **Satisfied**: Straightforward adapter identity definition. |
| **2. Start, Stream, Completion, Failure, Cancel** | `assert_start_stream_completion_failure_cancellation/3` | Starts OS process, streams JSONL events, emits `:result` on `turn.completed`, kills process group on cancel. | **Satisfied**: Full lifecycle conforms cleanly to the contract when wrapping the child process. |
| **3. Resume** | `assert_resume/4` | Requires `:resume` capability. CLI syntax `codex exec resume` exists but was not tested or verified in this spike. | **Deferred / Skipped**: The adapter must NOT declare `:resume` until `codex exec resume` event streaming is verified. ContractSuite will cleanly `@tag skip:` this test. |
| **4. Quota Refusal** | `assert_quota_refusal/2` | Requires `probe/1` returning `{:error, %Error{category: :quota_refused}}`. | **Not Satisfied Directly**: `codex exec` has no rate-limit probe CLI. Quota probing must delegate to the Iteration 3 Codex App Server monitor or return simulated error when configured. |
| **5. Capacity Handling** | `assert_missing_capacity/2` | Requires `probe/1` handling missing or invalid config. | **Delegated**: Handled by the composite capacity probe module, not by `codex exec` alone. |
| **6. Secret-Free Invariant** | `assert_secret_free/3` | Prohibits tokens, keys, or passwords in `RunIdentity` or `HarnessEvent` payloads. | **Satisfied**: `codex exec` does not log authentication tokens to stdout. Adapter will strip any raw secrets from command strings or extensions. |
| **7. Terminal Idempotency** | `assert_terminal_idempotency/3` | Multiple `cancel/2` calls or cancels after exit must succeed or return typed error without crashing. | **Satisfied**: Process group kill logic is inherently idempotent when checking PID status. |

---

## 11. Unverified Behaviors & Future Spikes

The following areas could not be confirmed from this capture alone and are cataloged as **UNVERIFIED**:

1. **`codex exec resume`**: While `codex exec resume --json <thread_id>` exists in CLI help, the exact streaming behavior, event shape across resumed turns, and error modes under resume were **NOT tested** in this spike.
2. **Quota Refusal Shape**: The exact JSON event or exit code emitted when Codex quota is exhausted during an `exec` run was **NOT observed**.
3. **Failure and Error Events**: Provider-level failures (network drops, invalid auth, context length exceeded, prompt moderation rejections) were **NOT observed**. The exact JSON schema for an unrecoverable failure remains unverified.
