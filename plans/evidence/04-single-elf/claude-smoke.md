# First live smoke: Claude headless execution adapter (WP D)

Date: 2026-09-06 UTC. CLI: `claude 2.1.263 (Claude Code)` (VERIFIED — `claude_code_version: "2.1.263"` in committed `init` frame).
Branch: `polly/iter4-claude-smoke` @ base `c0da311`.
Worktree: `/Users/anukin/projects/shoestring/.worktrees/iter4-claude-smoke`.

## 1. Executive Summary & Bottom Line Up Front

This document records the first authorized **LIVE smoke** of the Claude headless adapter path (`Shoestring.Harness.ClaudeHeadless`, Work Package D), authorized for one tiny run in a disposable repository under `mktemp -d`.

- **GO/NO-GO preflight**: **GO**. Local sandbox access to the macOS Keychain was verified directly (`security find-generic-password` returned exit 0 with 505 credential bytes). Claude 2.1.263 authenticated successfully without UI prompts or 401 errors.
- **Live execution outcome**: **SUCCESSFUL TURN** (exit code 0, 0 stderr bytes, 10 JSONL stream frames, `hello.txt` created containing `hello\n`, deterministic command `printf ok` executed and returned `ok`, total cost `$0.0716905`).
- **Seam defect findings**: While the CLI execution and frame normalization match the PR #36 wire contract, the adapter's live path is **UNWIRED** at the system integration seams:
  1. `ClaudeHeadless.start_session/2` drops `request.workspace_ref` and only inspects `opts[:workdir]`, defaulting working directory to the host BEAM cwd if omitted.
  2. `ClaudeHeadless.stream/2` returns an instantaneous snapshot of currently buffered events rather than an active stream.
  3. `Shoestring.Elves` hardcodes `CodexAppServer.Session` for safe-stop requests and immediately drains `pending_events` during `launch_fresh`, causing premature termination.
  4. `ClaudeHeadless` has no mechanism to persist raw stream frames or stderr to disk.

Per contract instructions, no files in `lib/` or `test/` were altered. All defects are recorded here.

## 2. GO/NO-GO Auth Check — GO

Prior sibling worker runs encountered HTTP 401 (`authentication_failed`) caused by sandbox isolation blocking access to the macOS Keychain (`/Users/anukin/Library/Keychains/login.keychain-db`), which was misinterpreted as credential expiration.

Before consuming any model turn, local keychain reachability was verified:
- `which claude` -> `/opt/homebrew/bin/claude` (OPERATOR-OBSERVED-NOT-CAPTURED).
- `claude --version` -> `2.1.263 (Claude Code)` (OPERATOR-OBSERVED-NOT-CAPTURED).
- `claude auth status` -> `loggedIn: true`, `authMethod: "claude.ai"`, `subscriptionType: "pro"` (OPERATOR-OBSERVED-NOT-CAPTURED).
- Keychain entry query: `security find-generic-password -s "Claude Code-credentials" -a "anukin"` -> exit 0 (OPERATOR-OBSERVED-NOT-CAPTURED).
- Keychain password extraction: `security find-generic-password -w -s "Claude Code-credentials" -a "anukin" | wc -c` -> exit 0, 505 bytes returned cleanly without interactive prompt (OPERATOR-OBSERVED-NOT-CAPTURED).

Verdict: **GO** — macOS Keychain was directly accessible from the sandbox.

## 3. Invocation Method & Scope

- **Disposable repository**: initialized under `mktemp -d /tmp/shoestring-claude-smoke-XXXXXX` (redacted to `/tmp/claude-smoke-repo`), with an initial Git commit on `README.md`. The user's checkout was not touched.
- **Execution path choice**: driven directly via the verified invocation shape from PR #36:
  ```bash
  (cd "$DISPOSABLE_DIR" && claude --print --output-format stream-json --verbose \
    --dangerously-skip-permissions --tools="Bash" \
    "Use Bash to create a file hello.txt containing the word hello, then run: printf ok" \
    < /dev/null \
    > "$DISPOSABLE_DIR/capture.stdout.jsonl" \
    2> "$DISPOSABLE_DIR/capture.stderr.txt")
  ```
  *Rationale for driving CLI directly vs adapter*: `Shoestring.Harness.ClaudeHeadless.Transport` and `Session` discard raw JSON lines after parsing and route child stderr directly to the host BEAM's stderr. To satisfy the contract requirement ("committed capture ... RETAIN stderr ... without touching lib/"), driving the CLI directly was required to capture raw stdout bytes and retain stderr cleanly.
- **Execution results**:
  - Exit code: `0`
  - Stderr size: `0` bytes (committed: `fixtures/claude/stream-json-smoke-live.stderr.txt`)
  - Stdout frames: `10` lines (committed: `fixtures/claude/stream-json-smoke-live.jsonl`)
  - File created: `hello.txt` containing `hello\n` (VERIFIED by post-run inspection)
  - Tool commands executed:
    1. `printf 'hello\n' > /tmp/claude-smoke-repo/hello.txt && cat /tmp/claude-smoke-repo/hello.txt` -> stdout `hello`
    2. `printf ok` -> stdout `ok`

## 4. Acceptance Questions Scorecard

### 1. Does the adapter's live path actually work end to end, or is it unwired like WP C's was?

**Ruling: UNWIRED / DEFECTIVE AT SYSTEM SEAMS (REPO-INSPECTION + VERIFIED)**

Unlike WP C's original flaw where `Session` failed to spawn `StdioTransport` when `transport_pid` was absent, `ClaudeHeadless.Session.handle_continue(:init_transport)` *does* call `Transport.start_link/1` to spawn `claude` with Python `setsid` wrapping.

However, the live path is **unwired and defective** across four architectural seams:
1. **Workspace / cwd mapping gap in `start_session/2`**: `ClaudeHeadless.start_session/2` passes `opts |> Map.to_list()` into `Session.start_link/1`. It never inspects `request.workspace_ref`. `Session.init/1` checks only `Keyword.get(opts, :workdir)`. If invoked via standard `ClaudeHeadless.start(%RunRequest{workspace_ref: path}, %{live: true})`, `:workdir` defaults to `nil`, causing `Transport` to launch `claude` in the host BEAM's current working directory.
2. **`stream/2` is an instantaneous buffer snapshot, not an active stream**: `ClaudeHeadless.stream/2` calls `Session.stream_events/1`, which immediately replies with `Enum.reverse(state.buffered_events)`. It does not wait or return an enumerable stream. A caller polling or calling `stream/2` at startup receives only the initial frames buffered up to that instant.
3. **`Shoestring.Elves` integration is completely unwired**:
   - `Shoestring.Elves.request_stop/2` hardcodes `Shoestring.Harness.CodexAppServer.Session.request_safe_stop(server)`. There is no delegation to `ClaudeHeadless.Session.cancel(..., boundary: :safe)`.
   - `Shoestring.Elves.Elf.launch_fresh/1` calls `materialize_stream/1` immediately after adapter launch. The initial stream snapshot empties immediately, causing `Elf` to enter `finish_after_stream/1` with `adapter_verdict: :none`. `Elf` has no mechanism to subscribe or receive streaming frames from `ClaudeHeadless`.
4. **No raw byte or stderr persistence**: Neither `Transport` nor `Session` preserves raw frame bytes or stderr on disk.

### 2. Tool boundaries: do tool_use / tool_result frames arrive correlated by toolu_ id, matching the PR #36 fixtures? Non-alternating order and one message spanning multiple frames were both observed there.

**Ruling: VERIFIED** (committed artifact: `plans/evidence/04-single-elf/fixtures/claude/stream-json-smoke-live.jsonl`)

The live stream confirmed all three behavioral characteristics:
1. **Correlation by `toolu_` ID**:
   - Tool 1 START in Frame 3 (`id: "toolu_000000000000000000000003"`) correlates to END in Frame 5 (`tool_use_id: "toolu_000000000000000000000003"`).
   - Tool 2 START in Frame 4 (`id: "toolu_000000000000000000000004"`) correlates to END in Frame 6 (`tool_use_id: "toolu_000000000000000000000004"`).
2. **Non-alternating order**:
   - Both START frames (Frames 3 and 4) were emitted *before* either END frame (Frames 5 and 6). Sequence: `tool_use(1) -> tool_use(2) -> tool_result(1) -> tool_result(2)`.
3. **One message spanning multiple frames**:
   - Frames 2 (conversational text), 3 (tool 1), and 4 (tool 2) all share the same `message.id` (`msg_000000000000000000000003`) and `request_id` (`req_000000000000000000000003`). Correlating by message ID or frame sequence fails; correlation strictly requires `toolu_` ID matching.

### 3. Is provider_session_id captured from the real stream?

**Ruling: VERIFIED** (committed artifact: `plans/evidence/04-single-elf/fixtures/claude/stream-json-smoke-live.jsonl`)

- Every frame (lines 0 through 9) contains top-level `session_id: "aaaaaaaa-0000-4000-a000-000000000003"` (synthetic format-valid UUIDv4 for observed `20b55137-e744-4018-a961-39b7104ac994`, version 4 variant a).
- `Session.track_session_id/3` extracts `session_id` from the initial `system/init` frame, unblocking `Session.await_run_identity/2` with a populated `provider_session_id` without returning `nil`.

### 4. Quota: do rate_limit_event frames arrive, and does the iteration-3 capacity classifier read them?

**Ruling: VERIFIED (frames arrive) / REPO-INSPECTION (classifier does NOT read them)** (committed artifact: `plans/evidence/04-single-elf/fixtures/claude/stream-json-smoke-live.jsonl`)

1. **`rate_limit_event` frames arrived**: Two separate frames arrived during the single turn:
   - Frame 1 (initial handshake): 5-hour utilization `0.62`, 7-day utilization `0.22`, status `"allowed"`.
   - Frame 8 (turn completion, preceding `result`): 5-hour utilization `0.63` (reflecting model inference consumed), 7-day utilization `0.22`, status `"allowed"`.
2. **Iteration-3 capacity classifier does NOT read them**:
   - `Shoestring.Harness.Capacity.ClaudeMonitor` is locked to passive `statusLine` hook observation from interactive sessions only (`claude_interactive_status_line`).
   - `ClaudeHeadless.EventNormalizer` normalizes `rate_limit_event` into a `:lifecycle` event with extension fields, but does not invoke `Shoestring.Harness.Capacity.normalize_observation/3` and does not update `Shoestring.Harness.Observatory` or the `harness_capacity_snapshots` database table.
   - `ClaudeHeadless.probe/1` returns an `:unknown` snapshot (`"headless_no_live_signal"`).

### 5. Anything the fixtures got wrong.

**Ruling: VERIFIED** (comparing `stream-json-smoke-live.jsonl` with `stream-json-tool-exec.jsonl`)

1. **Multiple `rate_limit_event` frames per run**: PR #36's fixture captured only one `rate_limit_event` immediately after `init`. The live run emitted two quota frames (pre-turn and post-turn), showing that utilization updates are emitted mid-stream.
2. **Conversational assistant text block preceding `tool_use`**: In PR #36's fixture, the assistant emitted only `tool_use` blocks before the user results. In the live run, the assistant emitted a preliminary text block (`"I'll create the file and run the command."`, Frame 2) sharing the message ID of the subsequent tool calls.
3. **CLI Version pinning**: The live run was executed with `claude 2.1.263`, whereas `lib/shoestring/harness/claude_headless.ex:50` and the PR #36 fixtures pin `@adapter_version "2.1.261"`.
4. **Float cost representation**: `total_cost_usd` was emitted as `0.07169049999999999` (standard IEEE 754 precision).
5. **Absence of reasoning blocks**: Confirmed that `thinking_tokens: 0` and no thinking or reasoning blocks were emitted by `claude-opus-5` in this headless mode.

## 5. Artifact Inventory & Redaction Record

Committed artifacts in this PR:
1. `plans/evidence/04-single-elf/fixtures/claude/stream-json-smoke-live.jsonl`: 10 captured stream frames (8,080 bytes).
2. `plans/evidence/04-single-elf/fixtures/claude/stream-json-smoke-live.stderr.txt`: 0 bytes (retained empty stderr).
3. `plans/evidence/04-single-elf/claude-smoke.md`: this evidence document.

### Redaction Map (per `plans/evidence/04-single-elf/README.md`)

- **Format-valid synthetic UUIDs**:
  - `session_id`: `20b55137-e744-4018-a961-39b7104ac994` -> `aaaaaaaa-0000-4000-a000-000000000003` (UUIDv4 version 4, variant a preserved).
  - Frame `uuid`: 10 observed UUIDv4 values -> `bbbbbbbb-0000-4000-8000-000000000016` through `...0025`.
- **Prefixed identifiers (1:1 shape-preserving substitution)**:
  - `msg_011CemrCWfHcaHNzkLDu6h1m` -> `msg_000000000000000000000003`
  - `msg_011CemrCkzzYmvBG4euh3oJg` -> `msg_000000000000000000000004`
  - `req_011CemrCVnhQmf2aQsyKnnUq` -> `req_000000000000000000000003`
  - `req_011CemrCkG648aGTS1s5ctNw` -> `req_000000000000000000000004`
  - `toolu_0157vShYPDDJYNVsjCTshVjZ` -> `toolu_000000000000000000000003`
  - `toolu_01VqBciu3qGnG8DhGjkXqTby` -> `toolu_000000000000000000000004`
- **Paths**:
  - `/private/tmp/shoestring-claude-smoke-IWes0c` -> `/tmp/claude-smoke-repo` in `cwd`, tool commands, assistant response text, and result text.
  - Zero home directory paths (`/Users/...`) remain in committed artifacts.
- **Machine-local inventory sanitized in `init` frame**:
  - `mcp_servers: []`, `slash_commands: []`, `terminal_slash_commands: []`, `agents: []`, `skills: []`, `plugins: []`, `memory_paths: {}`, `messaging_socket_path: "REDACTED"`.
- **Integrity**:
  - Timestamps, utilization numbers, cost, token counts, and tool outputs were preserved byte-identically.

## 6. Spend Accounting

- Runs consumed: 1 authorized tiny run.
- Model turns: 3.
- Cost: `$0.0716905` (`total_cost_usd` in final `result` frame).
- Tokens: 4 input tokens, 306 output tokens, 8,727 cache read, 5,867 cache creation.
- No further inference was consumed.
