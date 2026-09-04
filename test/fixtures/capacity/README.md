# Tracked Capacity Test Fixtures

> Authoritative lifecycle, regeneration, secret-review, and live-smoke policy:
> `docs/capacity-fixtures.md`. This README is an inventory supplement.

This directory contains sanitized, redacted provider capacity fixtures ported from
the authoritative Gate 0A feasibility study (`plans/evidence/00a-capacity-feasibility/fixtures`).

The original captures in `plans/evidence/00a-capacity-feasibility/fixtures` remain
permanently preserved as unmutated evidence. The copies here are tracked for
deterministic ExUnit test suite execution without requiring live provider CLIs or
network access.

## Tracked Fixture Inventory

### Claude (`test/fixtures/capacity/claude/`)
* `normal-official-shape.json` - Documented status-line rate-limit shape with five-hour and seven-day windows.
* `partial-official-shape.json` - Single-window shape (five-hour present, seven-day absent).
* `status-line-single-live.json` - Live authenticated post-response statusLine callback.
* `status-line-refresh-live.json` - Live repeated refresh callback (`refreshInterval=1`).
* `status-line-restart-live.json` - Pre/post-restart verification sequence.
* `status-line-concurrent-live.json` - Concurrent interactive session callback sample.
* `status-line-tools-live.json` - StatusLine callback during tool execution attempt.
* `missing-before-response.json` - Callback before first assistant response (rate limits absent).
* `stale-replay.json` - Simulated observation with age exceeding freshness window (> 300s).
* `malformed-replay.json` - Invalid window data structures.
* `refusal-unverified.json` - Structured quota refusal indicator shape.
* `auth-preflight-live.json` - Preflight authentication status and headless probe evidence.

### Codex (`test/fixtures/capacity/codex/`)
* `normal-read.json` - Live `account/rateLimits/read` response with primary and secondary rolling windows.
* `sparse-update-live.json` - Live `account/rateLimits/updated` notification with sparse fields.
* `partial-missing-secondary.json` - Primary window present, secondary window omitted.
* `restart-read-live.json` - Post-restart rate-limit read sample.
* `concurrent-read-live.json` - Concurrent process rate-limit read sample.
* `disconnect-unverified.json` - Simulated transport disconnect before response.
* `stale-replay.json` - Stale observation replay (> 300s).
* `malformed-replay.json` - Malformed window values (e.g. non-numeric percentages).
* `refusal-unverified.json` - `rateLimitReachedType` refusal response.

## Sanitization and Redaction Rules

Every committed fixture must adhere to strict redaction constraints:

1. **Strict Allowlisting:**
   * Only retain provider version, platform, protocol result structure, safe plan class (`plus`),
     window percentages, durations, reset timestamps, and bounded diagnostics.
2. **Forbidden Sensitive Content:**
   * Never commit authentication credentials, access tokens, Bearer tokens, cookies, API keys, or passwords.
   * Never commit user filesystem paths (`/Users/...`, `/home/...`).
   * Never commit raw transcripts, prompt messages, assistant completions, tool stdout/stderr,
     or model inference content.
   * Never commit raw session IDs, thread IDs, turn IDs, or opaque reset-credit tokens.
3. **Payload Bounding:**
   * Diagnostic reasons and text strings must not exceed 300 characters.
   * Large arrays or unbounded collections must be truncated or projected to counts.

## Regeneration and Capture Procedure

When capturing new evidence or updating fixtures, follow
`docs/capacity-fixtures.md` (regenerate → secret review → sync → scan).
The short form:

1. Optional live pre-check (version only, never touches fixtures):
   ```bash
   mix shoestring.capacity.fixtures --live-smoke
   ```
2. Run the safe provider probe tool using allowlist projections:
   ```bash
   node tools/gate_0a/provider_probe.js codex
   node tools/gate_0a/provider_probe.js claude
   ```
2. Inspect the raw capture against redaction rules:
   ```bash
   rg -n '(sk-|Bearer |token|cookie|session_id|threadId|turnId|codexHome|/Users/|/home/)' <path_to_fixture>
   ```
3. Run the automated fixture secret scanner:
   ```bash
   mix shoestring.capacity.fixtures --scan
   ```
4. Verify all tests pass offline:
   ```bash
   mix test test/shoestring/harness/capacity/
   ```
