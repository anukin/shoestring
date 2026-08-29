# Gate 0A support matrix

Decision date: 2026-08-28 local. Live probe timestamps are UTC on
2026-08-29. Tiers use the milestone definitions in
`plans/milestones/00a-capacity-feasibility.md`.

| Provider and invocation mode | Evidence state | Tier | Safe product use | Main limitation and fallback |
| --- | --- | --- | --- | --- |
| Codex App Server over stdio: initialize, `account/read`, and `account/rateLimits/read` before a response | Live, authenticated | **proactive** | Preflight and safe-boundary lease renewal from a fresh structured snapshot | A read is an observation, not a reservation. If the read fails, times out, or the schema drifts, mark capacity unknown, do not admit, checkpoint, and use the reactive provider-error path. |
| Codex App Server over stdio: `account/rateLimits/updated` during two normal no-tool turns plus post-turn reads | Live, authenticated | **proactive** with bounded freshness | Refresh at response/tool boundaries and renew only after a fresh-enough read | Updates are sparse and may omit nullable fields. Merge them into the latest snapshot; never clear known fields from an omission. |
| Codex: two concurrent App Server processes reading the same account | Live, authenticated, one point-in-time sample at `2026-08-29T05:35:03.082Z`; both 26% primary/18% secondary | **proactive** with concurrency reserve | The sample supports account-level use for this session, with a configured reserve | Identical readings do not prove synchronized enforcement across all sessions or future versions. Keep leases bounded and reserve capacity for another session. |
| Codex: stop one App Server process, start a new one, and re-read the account | Live, authenticated, one point-in-time sample | **proactive** with restart revalidation | Re-run handshake and rate-limit read after process restart before renewing a lease | Identical snapshots in one restart sample do not prove all provider state survives every restart. A failed or malformed re-read disables admission. |
| Claude interactive status line receiving documented JSON | Authentication live-verified; callback not observed | **conservative/partial** (conditional) | Optional observer after an authenticated interactive session supplies the official `rate_limits` object | Values appear only after the first API response; each window may be absent; no request-refresh API or live concurrency result was verified. Absent/drifted input becomes unknown and disables proactive admission. |
| Claude `-p --output-format json` | Live authenticated probe completed at `2026-08-29T06:22:56.629Z`; rate-limit signal absent | **unsupported pending live refusal evidence** | None for capacity admission; preserve a checkpoint and require manual/provider confirmation | The structured result completed without the status-line `rate_limits` object or a reliable quota-refusal shape. Do not claim reactive recovery from this result. |
| Claude `-p --output-format stream-json` | Live authenticated probe exited with `process_error` (status 1); no structured messages | **unsupported pending live refusal evidence** | None for capacity admission; preserve a checkpoint and require manual/provider confirmation | No rate-limit signal or refusal shape was captured. A process error is not a quota refusal. Do not scrape terminal text. |
| Claude colored terminal output or terminal scraping | Explicitly excluded | **unsupported** | None for MVP capacity admission | Scraping is not a structured provider contract. Preserve a checkpoint on a refusal and require a fresh official observer or manual confirmation. |

## MVP decision

Shoestring may make a proactive, bounded admission decision from the Codex App
Server surface, provided the snapshot is no older than five minutes, has the
required windows, and is renewed at a safe harness boundary. This five-minute
threshold is a Shoestring freshness policy, not a Codex guarantee.

Claude headless print and stream modes remain unsupported pending live refusal
evidence. The authenticated JSON probe completed without a capacity signal, and
the stream probe produced only a process error. The documented interactive
status-line surface is a conditional conservative/partial extension, not a
claim that this worktree currently observes it. The product claim remains
useful because Codex is proactively observable: Claude work can be checkpointed
when a future verified refusal occurs or handed to Codex.
Unknown, stale, missing, or malformed capacity never means unlimited
availability.

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
timestamp is freshness `unknown` (this policy accepts no clock-skew grace) and
fails closed to `state=unknown`, `availability=unknown`, and
`confidence=none`. Complete, fresh
structured windows are `high` confidence; partial fresh windows are `medium`;
stale observations are `low`; malformed, disconnected, absent, or
timestamp-unknown observations are `none`. Valid windows without a valid
`captured_at` normalize to `state=unknown`, `availability=unknown`, and
`confidence=none`; they never become fresh just because the values are
well-formed. A refusal with an unknown timestamp remains `refused` for the
explicit provider signal but has `confidence=none`; it does not authorize a
fresh-capacity claim. A structured refusal can be `refused`, but the live
refusal case was not induced in this gate.

## Iteration 3 production probes and fallbacks

1. Start one Codex App Server stdio connection, complete the handshake, read
   account/rate limits, and subscribe to sparse updates.
2. Merge sparse Codex updates, preserve omitted nullable fields, and refetch at
   every safe response/tool boundary before lease renewal.
3. Add a per-provider freshness timer and bounded lease; never interrupt an
   in-flight request solely because freshness expires.
4. Treat process exit, disconnect, malformed JSON, invalid fields, missing
   required buckets, and stale observations as degraded/unknown; stop admission,
   checkpoint, and wait or hand off.
5. For Claude, add an explicitly invoked official interactive status-line
   observer only after authenticated live verification. Keep print/stream
   modes unsupported until a live, reliable quota-refusal shape is evidenced;
   classify generic provider errors as unknown.
6. Keep terminal scraping unsupported and surface the reduced confidence in the
   UI.
