# Claude observations

## Environment and authentication preflight

| Field | Value |
| --- | --- |
| OS | macOS Darwin 24.6.0 |
| Architecture | arm64 |
| Claude Code CLI | `2.1.251 (Claude Code)` |
| Authentication status from this worktree's probe | `loggedIn=false`, `authMethod=none` |
| Subscription plan class | Not recorded; unavailable without authentication |
| Live provider response from this worktree | Not attempted after failed authentication preflight |

The official Claude Code installation is present. The direct sanitized rerun in
this worktree still reports an unauthenticated session, so it did not make a
model request. A separate verification report supplied to this work item says
that another invocation returned `loggedIn=true`, `authMethod=claude.ai`; that
report is not a payload captured by this probe and cannot substitute for a live
model or status-line observation here. No token, account file, account path, or
login flow was inspected or copied. The exact blocker for this worktree is:
**the Claude process available to the probe has no authenticated session.**
The minimal human action is to make the authenticated CLI session available to
this worktree and rerun the probe. No token should be sent to Shoestring or to
this agent.

The reproducible non-invasive probe is:

```text
node tools/gate_0a/provider_probe.js claude
```

Its redacted live result is represented by
`fixtures/claude/auth-preflight-live.json`. The probe attempts bounded JSON and
stream probes only when the preflight is authenticated; otherwise it exits
after status discovery. It never emits provider text, identifiers, or raw
payloads.

The direct live preflight observation was recorded at
`2026-08-29T04:56:40.090Z`.

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
| Interactive session with official `statusLine` command | Not live-verified; direct probe authentication unavailable | Conservative/partial, conditional | The documented JSON shape is parseable after a first response, but the observer has no provider refresh request and either window may be absent. |
| `claude -p --output-format json` | Not live-verified; direct probe authentication unavailable | Reactive-only | The bounded live mode was not run because preflight was unauthenticated. Anthropic documents a structured result envelope but does not document the status-line `rate_limits` object as part of this headless output. Use only explicit CLI error/refusal handling. |
| `claude -p --output-format stream-json` | Not live-verified; direct probe authentication unavailable | Reactive-only | The bounded live mode was not run because preflight was unauthenticated. The CLI reference documents streaming JSON, but no live rate-limit fields or update cadence were available. Do not infer capacity from assistant text or terminal output. |
| Colored interactive terminal output / scraping | Not attempted | Unsupported | Explicitly outside the Gate 0A contract and not a proactive source. |

`fixtures/claude/normal-official-shape.json` contains the public documented
five-hour and seven-day example shape, not a response from this account. The
partial fixture models the documented independent absence rule. The missing
fixture models the documented before-first-response condition. All are marked
so they cannot be mistaken for live evidence.

## Unverified behaviors

Because the direct probe's authentication prerequisite still failed, this gate could not honestly
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
