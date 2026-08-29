# Claude observations

## Environment and authentication preflight

| Field | Value |
| --- | --- |
| OS | macOS Darwin 24.6.0 |
| Architecture | arm64 |
| Claude Code CLI | `2.1.251 (Claude Code)` |
| Node runtime for disposable probes | `v26.5.0` |
| expect runtime | `5.45` |
| Authentication status | `loggedIn=true`, `authMethod=claude.ai` |
| Subscription plan class | Not exposed by the bounded probe |

Authentication was checked without reading or copying credentials:

```text
zsh -lc 'claude auth status --json | jq "{loggedIn, authMethod}"'
{"loggedIn":true,"authMethod":"claude.ai"}
```

The earlier unauthenticated preflight and the later authenticated headless
preflight remain separate evidence. The authenticated headless run at
`2026-08-29T06:22:56.629Z` completed JSON without a rate-limit signal; its
stream-json invocation exited with a process error and no structured messages.
Those results do not imply either an unsupported subscription or a refusal.

## Official surface and disposable observer

The status-line contract was read at execution time from Anthropic's [Claude
Code status-line documentation](https://code.claude.com/docs/en/statusline).
The CLI settings and output flags were checked against the [official CLI
reference](https://docs.anthropic.com/en/docs/claude-code/cli-usage). The
documented status-line command receives JSON on stdin and runs locally. Its
`rate_limits` object contains the optional `five_hour` and `seven_day` windows,
each with `used_percentage` and `resets_at`; `spend_limit` is optional.
Anthropic documents that the rate-limit object becomes available after the
session's first API response, windows may be independently absent, and a
window is dropped after reset.

The disposable observer is `tools/gate_0a/claude_statusline_observer.js`. It
uses an inline session-only `--settings` override to install the documented
`statusLine.type=command` callback; it does not edit user settings. It reads
only the allowlisted version, window percentages, reset epochs, callback
receipt timestamp, and a probe label. It never retains session IDs, prompts,
responses, paths, tool output, or the raw callback input. A malformed callback
produces a sanitized error snapshot and never a stack trace.

The runner is `tools/gate_0a/claude_statusline_probe.js`. It uses a fixed,
non-sensitive one-line interaction in a disposable TTY with
`--permission-mode dontAsk`, `--ax-screen-reader`, and `--tools {}`. The
`tools` mode permits only the requested read-only `Bash(printf *)` command;
the sanitized capture does not assert that the tool actually executed. The
reproducible commands, run from the repository root, were:

```text
node tools/gate_0a/claude_statusline_probe.js single
node tools/gate_0a/claude_statusline_probe.js restart
node tools/gate_0a/claude_statusline_probe.js concurrent
node tools/gate_0a/claude_statusline_probe.js refresh
node tools/gate_0a/claude_statusline_probe.js tools
```

Every process completed with exit status 0. The callback timestamp is local
process receipt time, not provider-side generation time.

## Live status-line results

The first callback of each ordinary session had no `rate_limits` object. A
callback after the first response did. This directly distinguishes the
documented before-first-response absence from an authenticated session that
can emit the fields.

| Mode | Sanitized result | Timing/evidence |
| --- | --- | --- |
| Normal response | 5-hour 25%, 7-day 94%; resets `1787994000` and `1788033600` | startup callback absent at `07:34:17.851Z`; post-response callback observed at `07:34:19.504Z` |
| Process restart | Before restart 25%/94%; after restart 26%/94% | startup callbacks absent; observed callbacks at `07:35:36.745Z` and `07:35:45.437Z`; comparison `divergent` because the normal interaction changed the five-hour value |
| Two concurrent sessions | Both post-response snapshots 26%/94% | observed at `07:36:15.268Z` and `07:36:15.332Z`; comparison `identical` |
| Refresh callback | Repeated 26%/94% callbacks | with `refreshInterval=1`, observed at `07:37:31.480Z`, `07:37:32.487Z`, `07:37:33.484Z`, and `07:37:37.860Z` |
| Tool-mode attempt | Post-response callbacks 27%/94% | observed at `07:37:45.283Z` and `07:37:50.851Z`; tool execution is `not_asserted_by_sanitized_capture` |

The restart sample shows that a newly started process can obtain a current
status-line snapshot, but the one-sample difference does not establish a
provider persistence or synchronization guarantee. The concurrent sample is
one account-level consistency sample, not proof of cross-session enforcement.
The refresh run demonstrates repeated local callback delivery, not a provider
refresh API or a universal interval guarantee. The 7-day value was already
94%, so no further allowance-consuming interaction was used to manufacture
more cases.

No compaction operation was run: invoking it would have consumed additional
live allowance without being necessary to establish the documented callback
surface, and the account's sanitized seven-day observation was already 94%.
Consequently, compaction-specific timing remains unverified. No natural
Claude refusal or limit error occurred, and no refusal was induced. The
sanitized refusal fixture is parser-only evidence and is not an observed
Claude response.

## Modes and support tiers

| Mode | Live result | Tier | Finding and fallback |
| --- | --- | --- | --- |
| Interactive session with official status-line command | Live authenticated callbacks after ordinary responses | **conservative/partial** | Use only as an explicitly invoked observer with a five-minute freshness limit and larger concurrency reserve. Missing, stale, future, malformed, or independently absent windows become unknown/degraded and stop admission. |
| `claude -p --output-format json` | Authenticated run completed; no rate-limit signal | **unsupported** | The headless envelope does not expose the status-line object. Do not infer capacity or reactive refusal recovery from it. |
| `claude -p --output-format stream-json` | Process error, status 1; no structured messages | **unsupported** | This is a generic process/provider failure, not a quota refusal. Preserve a checkpoint and treat the observation as unknown. |
| Colored interactive terminal output / scraping | Explicitly excluded | **unsupported** | Terminal scraping is not a structured provider contract. |

The status-line callback is not classified as reactive-only: a reliable refusal
shape was not evidenced, but a structured capacity snapshot was observed. The
headless rows are unsupported, not reactive-only, because neither mode produced
a reliable refusal signal. An absent callback before the first response is
distinct from headless unsupported behavior and from an unsupported
subscription/window state; the bounded probe cannot distinguish subscription
classes when the provider omits the object.

## Normalized behavior and evidence limits

The parser normalizes a valid, fresh callback to `observed/available/high`; a
fresh callback with one absent window is `degraded/available/medium`; stale is
`degraded/available/low`; malformed, future, missing-timestamp, and absent
capacity are `unknown/unknown/none`. A refusal remains `refused/refused`, but
an unknown timestamp forces confidence `none`. Future timestamps fail closed;
they are never clamped to age zero. A generic provider error is `unknown` with
reason `provider_error`, while absent `rate_limits` is recorded as
`rate_limits_absent_before_first_response_or_unsupported_subscription`.

The following are still unverified: account-wide enforcement beyond the one
concurrent sample, provider-side refresh semantics, compaction timing, a
natural refusal shape, and whether the requested tool command actually ran.
No claim is made about subscription/window states not represented by the live
callbacks. `fixtures/claude/stale-replay.json`, malformed, missing, and refusal
fixtures are explicit replay/parser cases rather than live claims.

## Evidence files

- `fixtures/claude/status-line-single-live.json`: normal authenticated
  status-line startup and post-response callbacks.
- `fixtures/claude/status-line-restart-live.json`: sanitized process-restart
  comparison.
- `fixtures/claude/status-line-concurrent-live.json`: sanitized concurrent
  session comparison.
- `fixtures/claude/status-line-refresh-live.json`: repeated callback timing
  with a one-second refresh interval.
- `fixtures/claude/status-line-tools-live.json`: safe tool-mode attempt with
  tool execution deliberately left unasserted.
- `fixtures/claude/auth-preflight-live.json`: authenticated headless preflight.
- `fixtures/claude/normal-official-shape.json` and
  `partial-official-shape.json`: clearly labeled documentation-shaped parser
  fixtures, not account captures.
- `fixtures/claude/stale-replay.json`, `malformed-replay.json`,
  `missing-before-response.json`, and `refusal-unverified.json`: explicit
  fallback and parser safety cases.

The observer's executable normalization is covered by
`test/gate_0a_statusline_observer.test.js`; fixture normalization and
fail-closed freshness are covered by
`test/gate_0a_capacity_parser_test.exs`.
