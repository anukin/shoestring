# Claude observations

## Environment and authentication preflight

| Field | Value |
| --- | --- |
| OS | macOS Darwin 24.6.0 |
| Architecture | arm64 |
| Claude Code CLI | `2.1.251 (Claude Code)` |
| Authentication status | `loggedIn=false`, `authMethod=none` |
| Subscription plan class | Not recorded; unavailable without authentication |
| Live provider response | Not attempted after failed authentication preflight |

The official Claude Code installation is present, but the existing CLI session
is not authenticated. No token, account file, account path, or login flow was
inspected or copied. The exact blocker is therefore: **Claude Code cannot make
an authenticated subscription request on this machine until the user signs in
through the official CLI.** The minimal human action is to run the normal
official `claude auth login` flow and tell the next probe run when
`claude auth status --json` reports an authenticated session. No token should be
sent to Shoestring or to this agent.

The reproducible non-invasive probe is:

```text
node tools/gate_0a/provider_probe.js claude
```

Its redacted live result is represented by
`fixtures/claude/auth-preflight-live.json`. The probe exits after authentication
status discovery and does not attempt a model request when the session is not
authenticated.

The live preflight observation was recorded at `2026-08-29T04:44:02.941Z`.

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
| Interactive session with official `statusLine` command | Not live-verified; no authentication | Conservative/partial, conditional | The documented JSON shape is parseable after a first response, but the observer has no provider refresh request and either window may be absent. |
| `claude -p --output-format json` | Not live-verified; no authentication | Reactive-only | Anthropic documents a structured result envelope and JSON output, but does not document the status-line `rate_limits` object as part of this headless output. Use only explicit CLI error/refusal handling. |
| `claude -p --output-format stream-json` | Not live-verified; no authentication | Reactive-only | The CLI reference documents streaming JSON, but no live capacity fields or update cadence were available. Do not infer capacity from assistant text or terminal output. |
| Colored interactive terminal output / scraping | Not attempted | Unsupported | Explicitly outside the Gate 0A contract and not a proactive source. |

`fixtures/claude/normal-official-shape.json` contains the public documented
five-hour and seven-day example shape, not a response from this account. The
partial fixture models the documented independent absence rule. The missing
fixture models the documented before-first-response condition. All are marked
so they cannot be mistaken for live evidence.

## Unverified behaviors

Because the authentication prerequisite failed, this gate could not honestly
measure:

- whether status-line input is emitted in a normal interactive session on this
  installation;
- whether print or stream/headless execution exposes the same object;
- update timing after assistant messages, tool sequences, compaction, or a
  refresh callback;
- whether values are account-wide or session-local across two sessions;
- process restart behavior; or
- the structured shape of a real subscription refusal.

The parser exercises a clearly labeled synthetic refusal fixture with an
`is_error=true`, `subtype=rate_limit` result solely to prove the reactive
fallback. It does not claim that this subtype is an official Claude contract.
If the live probe later receives an error with another shape, the safe default
is `unknown` until that shape is explicitly classified.

## Safe fallback

If the status-line object is absent, stale, malformed, or changes shape,
Shoestring must not admit proactively. It should label capacity unknown or
degraded, preserve the trajectory checkpoint, and wait for reset/manual
confirmation or hand off to a provider with a structured fresh read. Headless
print/stream modes may report a bounded provider refusal reactively, but a
generic error must not be confused with a quota refusal. Terminal scraping is
unsupported.
