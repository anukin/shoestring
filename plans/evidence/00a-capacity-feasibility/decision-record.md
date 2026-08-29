# Gate 0A decision record

Decision ID: `gate-0a-capacity-feasibility-2026-08-28`

## Decision

Adopt Codex App Server rate-limit observations as the first MVP's proactive
capacity source, with a five-minute Shoestring freshness threshold, bounded
leases, safe-boundary renewal, and fail-closed handling for unknown data. Treat
Claude headless print/stream modes as unsupported pending live refusal
evidence. Treat Claude's documented
interactive status-line feed as a conditional conservative/partial observer
that requires a separately authenticated live verification before it can be
enabled.

This is a feasibility decision, not a production adapter. The executable parser
and Node probes live under `tools/gate_0a/` and are intentionally disposable.

## Evidence basis

- Codex CLI `codex-cli 0.150.1`, macOS Darwin 24.6.0 arm64, authenticated
  ChatGPT-managed `plus` session.
- Codex handshake, account discovery, rate-limit read, two normal no-tool
  turns, sparse updates, post-turn reads, two concurrent read-only App Server
  processes, and a stop/start process-restart read were observed live.
- Codex live snapshots exposed primary 5-hour and secondary 7-day windows,
  percentages, durations, reset timestamps, reached state, and a `codex`
  multi-bucket key.
- The latest live concurrent-read rerun was captured at
  `2026-08-29T05:35:03.082Z`; both sanitized observations were 26% primary and
  18% secondary and compared identical. An intermediate draft had paired a
  `05:22:15.986Z` timestamp with 12%/16%; it was corrected from the actual
  rerun rather than edited to preserve that mismatch. The original
  `04:31:30.873Z` 12%/16% capture and the correction are recoverable from Git
  history.
- The live stop/start sample at `2026-08-29T05:22:15.906Z` returned identical
  sanitized 22%/18% primary/secondary windows before and after restarting the
  App Server process. This supports restart revalidation, not a provider-wide
  persistence guarantee.
- Claude Code `2.1.251`, same macOS/arm64 environment, was authenticated by the
  user through the official browser flow. The bounded live run at
  `2026-08-29T06:22:56.629Z` completed JSON mode without a rate-limit signal;
  stream-json exited with a process error and no structured messages. No
  status-line callback or structured refusal was captured, so headless modes
  remain unsupported pending refusal evidence and the interactive surface
  remains conditional conservative/partial.
- The official current sources are linked from
  `codex-observations.md` and `claude-observations.md`.

## Contract and fallback implications

Iteration 2 can define a provider-neutral snapshot with explicit `observed`,
`degraded`, `refused`, and `unknown` states; named windows; source event;
freshness; and confidence. Missing or malformed fields are never zero. A
notification is sparse evidence and must be merged with the latest full
snapshot.

Iteration 3 must implement the Codex handshake/read/update/restart probe, the five-
minute freshness policy, a conservative reserve for concurrency, and a
checkpoint-and-wait/handoff path for disconnects, process restarts, schema
drift, stale snapshots, and refusals. Claude's status-line observer remains
behind live verification; headless print/stream modes remain unsupported until
a reliable live refusal shape is captured.

## Acceptance status

The acceptance gate is **not yet satisfied**: the authenticated headless run
produced no capacity signal, the interactive status-line and structured
refusal behaviors remain unverified, and no remote/PR is available for review.
No completion record is filled and the milestone remains `in_progress`. The
minimal evidence follow-up is an authenticated interactive status-line or
structured refusal capture if the product needs either capability; no
credentials need to be shared.

The live headless result is not a reason to promote the documented shape to a
proactive or reactive product claim. Keep the current fallback until a
structured Claude capacity or refusal signal is actually observed.
