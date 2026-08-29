# Claude observations

## Environment and authentication preflight

| Field | Value |
| --- | --- |
| OS | macOS Darwin 24.6.0 |
| Architecture | arm64 |
| Claude Code CLI | `2.1.251 (Claude Code)` |
| Authentication status from this worktree's probe | `loggedIn=true`, `authMethod=claude.ai` |
| Subscription plan class | Not exposed by the bounded probe |
| Live provider response from this worktree | JSON completed without a rate-limit signal; stream-json exited with a process error and no structured messages |

The official Claude Code installation is present. An earlier preflight at
`2026-08-29T05:41:04.562Z` reported no login; the user then completed the
official browser login flow from this shell. The successful sanitized preflight
and bounded headless results were captured at `2026-08-29T06:22:56.629Z`.
No token, account file, account path, or raw login response was inspected or
copied.

The reproducible non-invasive probe is:

```text
node tools/gate_0a/provider_probe.js claude
```

Its redacted live result is represented by
`fixtures/claude/auth-preflight-live.json`. The probe attempts bounded JSON and
stream probes only when the preflight is authenticated. It emits only mode,
exit/outcome, aggregate message types, and allowlisted rate-limit presence; it
never emits provider text, identifiers, or raw payloads.

The successful live preflight observation was recorded at
`2026-08-29T06:22:56.629Z`.

## Current official surfaces

The status-line contract was read at execution time from Anthropic's [Claude
Code status-line documentation](https://code.claude.com/docs/en/statusline).
The CLI mode flags were checked against the [official CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-usage).

The status-line command receives JSON on stdin. The documented `rate_limits`
object contains:

- `five_hour.used_percentage` and `five_hour.resets_at`;
- `seven_day.used_percentage` and `seven_day.resets_at`; and
- an optional `spend_limit` pair behind a Claude apps gateway with spend
  limits.

The documentation says `rate_limits` is present only for Claude.ai Pro and Max
subscribers (or an applicable apps gateway) and only after the session's first
API response. Each window may be independently absent, and a window is dropped
after its reset time. These absence rules make an omitted field different from
zero usage.

## Modes and evidence

| Mode | Live result | Tier | Finding |
| --- | --- | --- | --- |
| Interactive session with official `statusLine` command | Authentication live-verified; status-line callback not observed | Conservative/partial, conditional | The documented JSON shape is parseable after a first response, but this probe did not create an interactive status-line callback or establish a provider refresh request; either window may be absent. |
| `claude -p --output-format json` | Live authenticated probe completed at `2026-08-29T06:22:56.629Z`; rate-limit signal absent | Unsupported pending live refusal evidence | The result envelope completed but exposed no structured `rate_limits` object or reliable quota-refusal shape. Do not use this mode for capacity admission or claim reactive recovery. |
| `claude -p --output-format stream-json` | Live authenticated probe exited with `process_error` (status 1); no structured messages | Unsupported pending live refusal evidence | No rate-limit signal or refusal shape was captured. The process error is not evidence of a quota refusal; do not infer capacity from assistant text or terminal output. |
| Colored interactive terminal output / scraping | Not attempted | Unsupported | Explicitly outside the Gate 0A contract and not a proactive source. |

`fixtures/claude/normal-official-shape.json` contains the public documented
five-hour and seven-day example shape, not a response from this account. The
partial fixture models the documented independent absence rule. The missing
fixture models the documented before-first-response condition. All are marked
so they cannot be mistaken for live evidence.

## Unverified behaviors

Authentication succeeded for the bounded headless probes, but this gate could
not honestly measure:

- whether status-line input is emitted in a normal interactive session on this
  installation;
- whether either headless mode exposes the documented `rate_limits` object (the
  JSON result did not, and stream-json produced no structured messages);
- update timing after assistant messages, tool sequences, compaction, or a
  refresh callback;
- whether values are account-wide or session-local across two sessions;
- process restart behavior; or
- the structured shape of a real subscription refusal.

The parser exercises a clearly labeled synthetic refusal fixture with an
`is_error=true`, `subtype=rate_limit` result solely to prove refusal parsing.
The live headless run did not produce a refusal, so it does not claim that this
subtype is an official Claude contract or that headless refusal recovery is
currently supported.
If the live probe later receives an error with another shape, the safe default
is `unknown` until that shape is explicitly classified.

## Safe fallback

If the status-line object is absent, stale, malformed, or changes shape,
Shoestring must not admit proactively. It should label capacity unknown or
degraded, preserve the trajectory checkpoint, and wait for reset/manual
confirmation or hand off to a provider with a structured fresh read. Headless
print/stream modes are unsupported for this gate until a live, reliable quota
refusal shape is evidenced. A generic provider error must not be confused with
a quota refusal. Terminal scraping is unsupported.
