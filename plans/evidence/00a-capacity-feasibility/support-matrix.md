# Gate 0A support matrix

Decision date: 2026-08-29 local. Live probe timestamps are UTC on
2026-08-29. Tiers use the milestone definitions in
`plans/milestones/00a-capacity-feasibility.md`.

| Provider and invocation mode | Evidence state | Tier | Safe product use | Main limitation and fallback |
| --- | --- | --- | --- | --- |
| Codex App Server over stdio: initialize, `account/read`, and `account/rateLimits/read` before a response | Live, authenticated | **proactive** | Preflight and safe-boundary lease renewal from a fresh structured snapshot | A read is an observation, not a reservation. If it fails, times out, or drifts, mark capacity unknown, checkpoint, and do not admit. |
| Codex App Server over stdio: `account/rateLimits/updated` during two normal no-tool turns plus post-turn reads | Live, authenticated | **proactive** with bounded freshness | Refresh at response/tool boundaries and renew only after a fresh-enough read | Updates are sparse and may omit nullable fields. Merge them into the latest snapshot; never clear known fields from an omission. |
| Codex: two concurrent App Server processes reading the same account | Live, authenticated, one sample at `2026-08-29T05:35:03.082Z`; both 26% primary/18% secondary | **proactive** with concurrency reserve | Account-level use for this session with a configured reserve | Identical readings do not prove synchronized enforcement across all sessions or future versions. |
| Codex: stop one App Server process, start a new one, and re-read | Live, authenticated, one sample | **proactive** with restart revalidation | Re-run handshake and rate-limit read after restart before renewing a lease | One identical sample cannot prove all provider state survives every restart. |
| Claude interactive official `statusLine` command | Live, authenticated callbacks after ordinary responses; 25%/94% then 26%/94% across samples | **conservative/partial** | Explicit observer after a response, five-minute freshness policy, larger concurrency reserve | Fields are absent before the first response; no provider refresh API or universal cross-session guarantee was established. Missing, stale, future, malformed, or absent windows disable admission. |
| Claude interactive official `statusLine` refresh callback | Live, authenticated; repeated 26%/94% callbacks with `refreshInterval=1` | **conservative/partial** | Observe repeated local callbacks as supplemental telemetry | This demonstrates callback delivery, not provider-side refresh synchronization or a universal timing guarantee. Compaction was not run because the account's sanitized seven-day value was already 94%. |
| Claude interactive status-line tool-mode attempt | Live callback sequence; requested read-only tool execution not asserted by sanitized capture | **conservative/partial** | Use the capacity callback only; do not infer tool-specific consumption from this sample | No causal tool-use measurement was retained. A later implementation must instrument tool completion without retaining tool data. |
| Claude `-p --output-format json` | Authenticated run completed at `2026-08-29T06:22:56.629Z`; rate-limit signal absent | **unsupported** | None for capacity admission | The headless envelope did not expose the status-line object or a reliable refusal shape. Do not infer reactive recovery. |
| Claude `-p --output-format stream-json` | Process error, status 1; no structured messages | **unsupported** | None for capacity admission | Generic process/provider failure is not a quota refusal. Preserve a checkpoint and classify unknown. |
| Claude colored terminal output or terminal scraping | Explicitly excluded | **unsupported** | None for MVP capacity admission | Scraping is not a structured provider contract. |

## MVP decision

Shoestring may make a proactive, bounded admission decision from the Codex App
Server surface, provided the snapshot is no older than five minutes, has the
required windows, and is renewed at a safe harness boundary. This threshold is
a Shoestring freshness policy, not a provider guarantee.

The Claude interactive status-line surface is a useful conservative/partial
observer: it supplied authenticated five-hour and seven-day fields after an
ordinary response, survived a process restart, produced identical post-response
values in one concurrent sample, and delivered repeated refresh callbacks. It
is not proactive because freshness and cross-session synchronization are not
guaranteed. It is not reactive-only because no reliable refusal shape was
observed. Claude print and stream modes are unsupported, not reactive-only:
they supplied neither a capacity signal nor a reliable refusal. No refusal was
forced, and no natural refusal occurred.

The product claim remains useful because Codex is proactively observable and
Claude can be monitored conservatively through an explicitly invoked official
interactive observer. Unknown, stale, missing, future, or malformed capacity
never means unlimited availability.

## Normalized state model for iteration 2

The spike parser emits:

```text
state: observed | degraded | refused | unknown
availability: available | refused | unknown
confidence: high | medium | low | none
source_event: explicit_read | update_notification | status_line_input |
              headless_result_error | none
freshness.state: fresh | stale | unknown
freshness.max_age_seconds: 300
windows: provider-specific named windows, with absent windows represented by nil
```

`fresh` means the observation is at most 300 seconds old and is not in the
future relative to the evaluation clock. A future or materially future
timestamp is freshness `unknown` with `state=unknown`,
`availability=unknown`, and `confidence=none`; there is no clock-skew grace.
Complete, fresh structured windows are `high` confidence; partial fresh
windows are `medium`; stale observations are `low`; malformed, disconnected,
absent, or timestamp-unknown observations are `none`. Valid windows without a
valid `captured_at` never become observed/available merely because their
values are well-formed. A refusal with an unknown timestamp remains an
explicit `refused` state but has `confidence=none`; it does not authorize a
fresh-capacity claim.

The reason `no_valid_windows` is reserved for a parsed rate-limit container
whose required windows are all absent/invalid. `missing_or_invalid_observation_timestamp`
is used when at least one valid window exists but its timestamp cannot support
freshness. An absent Claude `rate_limits` object is instead recorded as
`rate_limits_absent_before_first_response_or_unsupported_subscription` because
the bounded probe cannot distinguish those provider states. A generic provider
error is `provider_error`, not an absent-before-response or quota refusal.

## Iteration 3 production probes and fallbacks

1. Start one Codex App Server stdio connection, complete the handshake, read
   account/rate limits, and subscribe to sparse updates.
2. Merge sparse Codex updates, preserve omitted nullable fields, and refetch at
   every safe response/tool boundary before lease renewal.
3. Add a per-provider freshness timer and bounded lease; never interrupt an
   in-flight request solely because freshness expires.
4. Treat process exit, disconnect, malformed JSON, invalid fields, missing
   required buckets, future timestamps, and stale observations as degraded or
   unknown; stop admission, checkpoint, and wait or hand off.
5. For Claude, invoke the official interactive status-line observer only after
   authenticated live verification. Keep print/stream unsupported until a
   reliable live quota-refusal shape is evidenced; classify generic errors as
   unknown.
6. Keep terminal scraping unsupported and surface reduced confidence in the UI.
