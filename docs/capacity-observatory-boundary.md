# Capacity Observatory Public Boundary Contract

This document specifies the public API contract exposed by `Shoestring.Harness.Capacity`
for downstream monitor implementations (`CodexMonitor` in Work Package B and
`ClaudeMonitor` in Work Package C).

Downstream monitors must call this boundary exclusively for compatibility checks,
version discovery, payload normalization, and failure handling. Neither monitor
should implement custom compatibility logic or ad-hoc JSON parsing.

## Downstream Monitor Lifecycle

Each provider monitor process follows a 4-phase lifecycle:

```mermaid
flowchart TD
    A["Monitor Boot"] --> B["1. Version Discovery"]
    B --> C["2. Compatibility Evaluation"]
    C -->|Compatible / Degraded| D["3. Supervised Connection / Session"]
    C -->|Incompatible| E["Halt or Offline Idle State"]
    D --> F["4. Normalize Received Observation"]
    F -->|Parse / Protocol Failure| G["Preserve Last Known Observation"]
```

### Phase 1: CLI Version Discovery

On startup, the monitor discovers the installed CLI version via the injectable command runner:

```elixir
case Shoestring.Harness.Capacity.discover_version(:codex, timeout: 5_000) do
  {:ok, %{raw: raw_version, version: semver}} ->
    # e.g. %{raw: "codex-cli 0.150.1", version: "0.150.1"}
    ...

  {:error, :not_found} ->
    # Executable not found on PATH
    ...

  {:error, {:command_failed, status, snippet}} ->
    # Exit status non-zero; snippet is bounded to 200 chars and redacted of any credentials
    ...

  {:error, :timeout} ->
    # Command execution exceeded bounded timeout
    ...

  {:error, :invalid_runner} ->
    # Injected runner module, function, or map was malformed
    ...

  {:error, :unsupported_provider} ->
    # Provider is not supported
    ...
end
```

In unit tests, an injected runner must be passed via `opts[:runner]` (e.g. a mock module,
1/2/3-arity function, or string/tuple map) so that tests run completely offline without
installed CLIs or network access. CLI failure diagnostics are automatically sanitized
using `Shoestring.Harness.Security.redact/1`, stripping tokens, passwords, API keys,
and user filesystem paths before returning.

### Phase 2: Compatibility Evaluation

Before establishing transport or subscribing to updates, evaluate the compatibility
of the provider, observation mode, and discovered version against the authoritative
Gate 0A support matrix:

```elixir
compat = Shoestring.Harness.Capacity.compatibility(:codex, :app_server_stdio, version)
```

The resulting map contains:
* `:provider` - `:codex` or `:claude`
* `:invocation_mode` - `:app_server_stdio`, `:interactive_status_line`, etc.
* `:support_tier` - `:proactive`, `:conservative_partial`, or `:unsupported`
* `:compatibility_state` - `:compatible`, `:degraded`, or `:incompatible`
* `:version` - normalized semver string or `nil`
* `:reason` - bounded explanation string if degraded or incompatible (`nil` when compatible)

Non-string version inputs (e.g. integers, maps, lists, atoms) fail closed as untested/unknown
with degraded state and bounded reason without crashing.

#### Compatibility Policy Rules:
1. **Tested version match** (`0.150.1` for Codex, `2.1.251` for Claude):
   * Codex: `:proactive` tier, `:compatible` outcome.
   * Claude: `:conservative_partial` tier, `:compatible` outcome.
2. **Untested version drift** (e.g. `0.151.0` or `3.0.0`):
   * Outcome degrades to `:degraded` with reason `"untested_cli_version: <version>"`.
   * Future automatic admission policies will safely fail closed on degraded compatibility.
3. **Unsupported modes** (Claude headless `-p --output-format json`, `stream-json`, terminal scraping):
   * Outcome is `:incompatible`, tier is `:unsupported`.

### Phase 3: Observation Normalization

When a monitor receives a structured provider message (such as a JSON-RPC read response,
an `account/rateLimits/updated` notification, or a Claude `statusLine` callback), it
normalizes the raw payload into a versioned `Shoestring.Harness.CapacitySnapshot`:

```elixir
case Shoestring.Harness.Capacity.normalize(
  :codex,
  :app_server_stdio,
  raw_payload,
  version: discovered_version,
  captured_at: DateTime.utc_now(),
  source_event: :explicit_read, # or :update_notification / :status_line_input
  scope: "subscription",
  last_known_snapshot: state.last_known_snapshot
) do
  {:ok, %Shoestring.Harness.CapacitySnapshot{} = snapshot} ->
    ...

  {:error, :contains_secrets_or_forbidden_content} ->
    # Payload contains credential keys (token, api_key, password, etc.), secret patterns, or paths
    ...

  {:error, :payload_too_large} ->
    # Map size exceeds 64 keys or list exceeds 128 elements
    ...

  {:error, :payload_too_deep} ->
    # JSON nesting depth exceeds 10 levels
    ...
end
```

#### Normalization Semantics:
* **Security & Secret Scanning:** All observations are checked for quoted/unquoted
  credential keys (`token`, `api_key`, `access_token`, `refresh_token`, `password`, `secret`,
  `cookie`, `authorization`, `account_id`, `session_id`, `thread_id`, `turn_id`), prompts,
  transcripts, and user paths (`/Users/`, `/home/`) regardless of value shape.
* **Truthful Bounds Outcomes:** Benign size and depth limits return truthful `:payload_too_large`
  and `:payload_too_deep` errors rather than secret violations.
* **Additive unknown fields:** Tolerated without error within documented bounds.
* **Nested non-map payload resilience:** Observations containing non-map payload values fail
  closed returning `:unknown` with reason `"malformed_payload"` (or preserve last known snapshot),
  never raising `BadMapError`.
* **Binary malformed JSON:** Unparseable JSON strings fail closed returning `:unknown` with
  reason `"malformed_json"` (or preserve last known snapshot).
* **Missing required fields:** Missing rate-limit containers or windows degrade or reject
  with bounded reasons (`"no_valid_windows"`, `"missing_window: secondary"`).
* **Malformed values:** Invalid numbers, negative percentages, or bad types become
  `:unknown` or `:degraded` with explicit reasons; they **never** fabricate zero usage.
* **Refusal indicators:** Vendor rate-limit reached indicators yield `:refused` state
  with `:low` confidence. Claude interactive refusals preserve `:status_line_input` provenance.
* **Freshness & Stale windows:** Observations older than 300 seconds automatically degrade
  to `:stale_observation` with `:low` confidence. Future timestamps fail closed as `:unknown`.
* **Simultaneous Reason Joining:** Simultaneous version-drift, staleness, and partiality reasons
  are preserved and joined with `"; "` within a 300-character bound (e.g. `"untested_cli_version: 0.151.0; stale_observation; missing_window: secondary"`).

### Phase 4: Preserving Last-Known Observations on Protocol Failure

If a transport disconnects, a socket closes, or a raw payload cannot be parsed, the monitor
must **never** overwrite last-known capacity with fabricated zero usage. Instead, it must
call `preserve_last_known/3`:

```elixir
{:ok, degraded_snapshot} =
  Shoestring.Harness.Capacity.preserve_last_known(
    state.last_known_snapshot,
    "stdio_connection_closed",
    now: DateTime.utc_now()
  )
```

This preserves the previous observation's windows and original `observed_at` timestamp
while updating the state to `:degraded` with `:low` confidence and an explicit diagnostic reason.
