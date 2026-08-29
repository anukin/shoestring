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
- The live stop/start sample at `2026-08-29T05:22:15.906Z` returned identical
  sanitized 22%/18% primary/secondary windows before and after restarting the
  App Server process. This supports restart revalidation, not a provider-wide
  persistence guarantee.
- Claude Code `2.1.251`, same macOS/arm64 environment, failed this worktree's
  non-invasive authentication check with `loggedIn=false`, `authMethod=none`.
  A separate verification report supplied to this work item reported
  `loggedIn=true`, `authMethod=claude.ai`, but no sanitized model/status-line
  capture was supplied. Claude claims in this commit therefore remain limited
  to current official documentation and labeled replay fixtures.
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

The acceptance gate is **not yet satisfied** because this worktree could not
run the authenticated Claude probes. The safe evidence work is complete, but
no completion record is filled and the milestone remains `in_progress`. The
minimal follow-up is to make the already-authenticated Claude CLI session
available to this worktree and rerun `node tools/gate_0a/provider_probe.js
claude`; no credentials need to be shared.

The missing live Claude evidence is not a reason to promote the documented
shape to a proactive product claim. Once authentication is available, rerun the
minimal Claude observer and update the matrix only with observed results.
