# Milestone 04: Execution Evidence and Fixture Conventions

This directory houses the evidence writeups, execution capture records, and architectural evaluations for Milestone 04 (`plans/milestones/04-single-elf.md`).

---

## Fixture Identifier and Redaction Conventions

To ensure consistent fixture structure across provider transport spikes (`codex exec --json`, `codex app-server --stdio`, and future execution adapters) while preventing credential leaks or schema divergence, all committed fixtures must adhere to the following repository conventions:

### 1. Format-Valid but Synthetic Identifiers (The Tech Lead Ruling)
- **Problem**: Competing spike approaches either preserved real provider UUIDs (risking leaking provider-side session tokens) or replaced them with arbitrary strings (e.g., `THREAD-1`), which breaks schema parsers and UUID format assertions.
- **Convention**: All identifiers must be **format-valid but synthetic**.
  - Where the provider protocol emits UUIDv7 strings (such as Codex `thread_id`, `turn_id`, or `session_id`), the fixture value must be a deterministic, synthetic UUIDv7-shaped string.
  - The version nibble (`7`) and variant nibble (`8`, `9`, `a`, or `b` under RFC 9562) must be strictly preserved so that `Ecto.UUID.cast/1` and UUIDv7 structural validations succeed.
  - Standard baseline pattern for synthetic UUIDv7 identifiers:
    ```text
    01950000-0000-7000-8000-000000000001
    ```
  - Sequential items and turns may increment the low sequence bits (`...0002`, `...0003`, etc.).
  - Local item identifiers (e.g., `item_0`, `item_1`) retain their natural zero-indexed ordinal naming from the stream.

### 2. Zero Secrets and Credentials
- Under no circumstances may real API keys, Bearer tokens, authorization headers, cookies, or internal session tokens appear in committed fixtures or logs.
- All JSON keys containing authentication metadata (e.g., `account/read` tokens) must be omitted or sanitized to harmless placeholders prior to commit.

### 3. Zero Real Machine Paths
- No user-specific or system-specific absolute paths (e.g., `/Users/<username>/...` or `/home/<username>/...`) may appear in fixture files, command strings, or execution logs.
- Workspace paths must use relative paths or generic root placeholders (e.g., `/tmp/iter4-spike-exec-repo` or `$WORKSPACE`).

### 4. Hidden Reasoning and Private Model Scratchpads
- Milestone 04 strictly forbids storing or displaying hidden model thoughts or private reasoning traces.
- Usage token counters (such as `reasoning_output_tokens: N`) may be preserved to verify telemetry tracking, but any raw reasoning blocks (`item.type: "reasoning"`, thinking blocks, or scratchpads) must be stripped before fixture persistence.

### 5. Deterministic Payload Bounding
- Fixtures used for ExUnit test suites must be bounded in length (< 50 KB per stream) and free of nondeterministic timestamps or network dependencies to guarantee fast, hermetic test execution.

---

## Directory Inventory

- `codex-exec-json.md`: Spike A writeup analyzing `codex exec --json` CLI invocation, event vocabulary, safe lease boundary semantics, and `Shoestring.Harness.ContractSuite` compatibility.
- Associated execution fixtures are tracked under `test/fixtures/codex/execution/`.
