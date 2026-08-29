# Gate 0A decision record

Decision ID: `gate-0a-capacity-feasibility-2026-08-29`

## Decision

Adopt Codex App Server rate-limit observations as the first MVP's proactive
capacity source, with a five-minute Shoestring freshness threshold, bounded
leases, safe-boundary renewal, a concurrency reserve, and fail-closed handling
for unknown data.

Adopt Claude Code's documented interactive `statusLine` callback as a
conservative/partial capacity observer. It is explicitly invoked only in an
authenticated interactive session and may inform telemetry after an ordinary
response or refresh callback. It is not a proactive synchronized meter: the
observer does not establish provider-side freshness, reservation, or
cross-session enforcement guarantees. Claude print and stream JSON modes are
unsupported for capacity admission and are not promoted to reactive-only
because no reliable refusal signal was observed.

This is a feasibility decision, not a production adapter. The executable
parser and Node probes live under `tools/gate_0a/` and remain intentionally
disposable.

## Evidence basis

- Codex CLI `codex-cli 0.150.1`, macOS Darwin 24.6.0 arm64, authenticated
  ChatGPT-managed `plus` session. Handshake, account discovery, structured
  reads, updates, normal turns, concurrent reads, and process restart were
  captured live. The concurrent fixture is the corrected `05:35:03.082Z`
  capture with 26%/18%; the prior mismatched draft is recoverable in Git
  history, not retained as current evidence.
- Claude Code `2.1.251 (Claude Code)`, Node `v26.5.0`, expect `5.45`, macOS
  Darwin 24.6.0 arm64. The bounded authentication status was
  `loggedIn=true`, `authMethod=claude.ai`; no credential or account identifier
  was inspected or retained.
- The official session-only status-line observer captured a normal post-
  response snapshot of 25% five-hour and 94% seven-day at
  `2026-08-29T07:34:19.504Z`, with reset epochs `1787994000` and `1788033600`.
  The startup callback at `07:34:17.851Z` had no rate-limit object.
- A process restart obtained 25%/94% before and 26%/94% after at
  `07:35:36.745Z` and `07:35:45.437Z`; the changed five-hour value is recorded
  as `divergent`, not normalized away. Two concurrent sessions produced
  identical 26%/94% post-response snapshots at `07:36:15.268Z` and
  `07:36:15.332Z`.
- A one-second refresh callback run delivered 26%/94% at
  `07:37:31.480Z`, `07:37:32.487Z`, `07:37:33.484Z`, and `07:37:37.860Z`.
  A read-only tool-mode attempt produced 27%/94% callbacks, but sanitized
  evidence deliberately does not assert that the tool executed.
- No compaction was run because the live seven-day value was already 94% and
  another model interaction was not necessary to establish the official
  callback surface. No natural refusal or limit error occurred; the refusal
  fixture is parser-only and is not a live Claude claim.
- The authenticated headless JSON probe completed without a rate-limit signal
  at `2026-08-29T06:22:56.629Z`; stream-json exited with a process error and no
  structured messages. A generic process error is not a refusal.
- The official current sources are linked from `claude-observations.md` and
  `codex-observations.md`.

## Contract and fallback implications

Iteration 2 can define a provider-neutral snapshot with explicit `observed`,
`degraded`, `refused`, and `unknown` states; named windows; source event;
freshness; and confidence. Missing, malformed, future, or timestamp-unknown
values are never zero or available. A status-line startup omission is distinct
from a headless unsupported signal and from an unsupported subscription/window
state that this bounded probe cannot identify.

Iteration 3 must implement the Codex handshake/read/update/restart probe, the
five-minute freshness policy, a conservative concurrency reserve, and a
checkpoint-and-wait/handoff path for disconnects, schema drift, stale snapshots,
and refusals. Claude's interactive status-line observer should remain explicit
and conservative; headless modes and terminal scraping remain unsupported until
a reliable live refusal shape is evidenced. Future timestamps must fail closed,
and generic provider errors must remain unknown.

## Acceptance status

The Gate 0A acceptance gate is **satisfied with documented evidence limits**.
Every available provider/mode has a reproducible result and tier; live Claude
status-line capacity is observed after an ordinary response; callback timing,
restart, concurrency, and refresh behavior are recorded; absent-before-first-
response, headless-unsupported, generic-error, malformed, stale, future, and
refusal-parser outcomes are separated; and no secret or unredacted provider
material was retained. No allowance was exhausted to manufacture a refusal.

The milestone is therefore marked `complete`. This does not turn the Claude
observer into a proactive admission source, and the following remain explicit
iteration risks rather than hidden claims: compaction timing, causal proof of
tool execution, broader subscription/window variants, provider-side refresh
semantics, and a natural refusal sample. A remote and PR are not available in
this repository because no `origin` is configured; that review-transport gap
does not change the evidence decision.
