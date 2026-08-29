# Gate 0A decision record

Decision ID: `gate-0a-capacity-feasibility-2026-08-28`

## Decision

Adopt Codex App Server rate-limit observations as the first MVP's proactive
capacity source, with a five-minute Shoestring freshness threshold, bounded
leases, safe-boundary renewal, and fail-closed handling for unknown data. Treat
Claude headless print/stream modes as reactive-only. Treat Claude's documented
interactive status-line feed as a conditional conservative/partial observer
that requires a separately authenticated live verification before it can be
enabled.

This is a feasibility decision, not a production adapter. The executable parser
and Node probes live under `tools/gate_0a/` and are intentionally disposable.

## Evidence basis

- Codex CLI `codex-cli 0.150.1`, macOS Darwin 24.6.0 arm64, authenticated
  ChatGPT-managed `plus` session.
- Codex handshake, account discovery, rate-limit read, two normal no-tool
  turns, sparse updates, post-turn reads, and two concurrent read-only App
  Server processes were observed live.
- Codex live snapshots exposed primary 5-hour and secondary 7-day windows,
  percentages, durations, reset timestamps, reached state, and a `codex`
  multi-bucket key.
- Claude Code `2.1.251`, same macOS/arm64 environment, failed the
  non-invasive authentication check with `loggedIn=false`, `authMethod=none`.
  Claude claims are therefore limited to current official documentation and
  labeled replay fixtures.
- The official current sources are linked from
  `codex-observations.md` and `claude-observations.md`.

## Contract and fallback implications

Iteration 2 can define a provider-neutral snapshot with explicit `observed`,
`degraded`, `refused`, and `unknown` states; named windows; source event;
freshness; and confidence. Missing or malformed fields are never zero. A
notification is sparse evidence and must be merged with the latest full
snapshot.

Iteration 3 must implement the Codex handshake/read/update probe, the five-
minute freshness policy, a conservative reserve for concurrency, and a
checkpoint-and-wait/handoff path for disconnects, process restarts, schema
drift, stale snapshots, and refusals. Claude's status-line observer remains
behind live verification; otherwise only reactive recovery is supported.

## Acceptance status

The acceptance gate is **not yet satisfied** because an available provider
(Claude Code) could not be authenticated on this machine. The safe evidence
work is complete, but no completion record is filled and the milestone remains
`in_progress`. The only requested follow-up is for the user to authenticate
Claude Code through its official login flow; no credentials need to be shared.

The missing live Claude evidence is not a reason to promote the documented
shape to a proactive product claim. Once authentication is available, rerun the
minimal Claude observer and update the matrix only with observed results.
