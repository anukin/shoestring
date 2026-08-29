# Gate 0A: subscription-capacity feasibility

**Status:** in_progress
**Hard dependencies:** none
**Unlocks:** iteration 3 production capacity observatory

## Mission

Determine what Shoestring can reliably know about Claude Code and Codex
subscription windows. This gate converts the project's largest external
assumption into an evidence-backed support matrix before production routing is
built around it.

This is a feasibility investigation, not the production adapter. Small probe
programs are allowed. Do not establish permanent abstractions merely to make
the spike look production-ready.

## Required outcomes

- A support-tier decision for every tested provider and invocation mode:
  proactive, conservative/partial, reactive-only, or unsupported.
- Reproducible observation procedures with versions and environment recorded.
- Redacted representative fixtures and failure samples.
- A freshness/confidence model that iteration 2 can express and iteration 3
  can implement.
- A written fallback when each structured surface is absent or changes.

## Preflight

- Confirm the user has authenticated official Claude Code and Codex
  installations. Do not inspect or copy their credentials.
- Record OS, architecture, CLI/App Server versions, subscription plan class when
  the user is comfortable recording it, and invocation mode.
- Read the current official protocol/status documentation at execution time;
  vendor interfaces may have changed since this plan was written.
- Create a redaction checklist before capturing any payload.
- Avoid deliberately burning an entire allowance. Hard-limit behavior may be
  observed naturally or reproduced from a sanitized known sample.

## Work package A: Codex observation surface

Investigate the official App Server interface.

- Establish and record the handshake and version discovery procedure.
- Exercise the structured rate-limit read operation.
- Observe update notifications across several normal model responses.
- Identify all returned windows/buckets and the meaning of used percentage,
  duration, and reset timestamps.
- Test startup before any model response, missing buckets, stale data, process
  restart, malformed messages, and App Server disconnect.
- Determine whether multiple Codex sessions share and consistently report the
  same account-level windows.
- Record whether an explicit read refreshes provider state or only returns the
  most recently known observation.

## Work package B: Claude observation surface

Investigate the documented status-line `rate_limits` input and any official
structured headless surface available at execution time.

- Capture five-hour and seven-day fields after an ordinary response.
- Test which fields are absent before the first response and for different
  subscription/window states.
- Determine whether status-line input is emitted or can be observed in normal
  interactive, print, and stream/headless execution.
- Measure when values update: after assistant messages, tool sequences,
  compaction, refresh callbacks, or only specific UI events.
- Test process restart and two concurrent sessions on one account.
- Record the structured form of quota refusal or limit errors when available.
- Distinguish an unavailable headless signal from an unsupported subscription
  or temporarily absent window.

Do not scrape colored terminal output as a successful structured result. A
terminal-only fallback may be documented as future research but is not a basis
for proactive MVP admission.

## Work package C: freshness and support classification

For each provider/mode, answer:

- What event produced the observation?
- Is it an account-wide value or session-local approximation?
- Can Shoestring request a fresh read?
- How old can the value become during a long in-flight turn?
- What happens when another session consumes capacity?
- What fields may legally be absent?
- How can a parser distinguish format drift from zero usage?
- What is the safe behavior after probe failure?

Use this classification:

```text
proactive
  Structured and sufficiently fresh for preflight and safe-boundary renewal.

conservative/partial
  Structured but missing a window, mode, freshness guarantee, or concurrent
  session visibility. Admission needs larger reserves or manual confirmation.

reactive-only
  Reliable refusal/error detection exists, but remaining capacity cannot be
  observed well enough to admit automatically.

unsupported
  Neither a safe observation nor a reliable refusal signal exists in this mode.
```

## Artifacts

Create a redacted evidence directory for this gate containing:

- `support-matrix.md`;
- `codex-observations.md` and `claude-observations.md`;
- sanitized JSON fixtures for normal, partial, stale, malformed, and refusal
  cases that were actually observed;
- `redaction-notes.md` describing removed fields;
- minimal probe source and reproducible commands;
- a decision record selecting MVP support tiers and fallback behavior.

Raw credentials, authentication paths, full user prompts, and unrelated account
data must never enter these artifacts.

## Required evals

- Parse every captured fixture into an explicit normalized state.
- Prove missing and malformed values do not become zero usage.
- Compare concurrent-session observations and document divergence.
- Demonstrate the maximum observed update delay without calling it a universal
  guarantee.
- Simulate the chosen fallback using a captured malformed/disconnect/refusal
  fixture.

## Demo

Run the minimal probe for each available provider and show:

1. installed version and invocation mode;
2. a redacted normalized observation with timestamp;
3. the raw fixture after redaction;
4. a missing or malformed case becoming unknown/degraded;
5. the selected support tier and fallback.

If live access is unavailable, replay captured fixtures and mark the live result
unverified rather than fabricating evidence.

## Acceptance gate

- Every available provider/mode has a reproducible result and support tier.
- Freshness, concurrency, and absence semantics are explicitly documented.
- The selected product claim remains useful when one provider is reactive-only.
- Iteration 2 has enough concrete shapes to define normalized contracts.
- Iteration 3 has an explicit list of production probes and fallbacks.
- No secret or unredacted authentication material was retained.

## Out of scope

- Production Elixir adapters or supervision.
- Automatic routing and forecasting.
- Terminal scraping as a supported proactive capacity source.
- Exhausting allowances merely to manufacture a test case.
- Reverse engineering credentials or undocumented private APIs.

## Likely blockers and response

- **Headless Claude does not expose status-line data:** classify that mode as
  reactive-only or design a separately invoked, official interactive observer;
  do not pretend print JSON contains the value.
- **Updates are session-local:** document concurrency risk and require a larger
  reserve or single active provider session in the MVP.
- **Vendor version changes during the gate:** capture both versions and treat
  the drift as a compatibility-policy input.
- **No natural hard-limit sample:** leave the live refusal case unverified and
  use a clearly labeled sanitized fixture if one is available.

## Completion record

- **Final status:**
- **Completed on:**
- **Environments and versions tested:**
- **Support-tier decisions:**
- **Evidence files:**
- **Commands and results:**
- **Redaction review:**
- **Deviations:**
- **Remaining risks:**
- **Instructions for iteration 2:**
- **Instructions for iteration 3:**
