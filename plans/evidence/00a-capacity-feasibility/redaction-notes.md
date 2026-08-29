# Gate 0A redaction notes

Review date: 2026-08-28 local (probe timestamps are UTC on 2026-08-29)

The redaction checklist was created before the first provider payload was
captured:

- Do not read, copy, print, or persist credential files, tokens, cookies,
  account emails, or authentication paths.
- Do not retain full prompts, assistant text, tool output, working-directory
  paths, session/thread/turn IDs, opaque reset-credit IDs, or unrelated account
  data.
- Allowlist only the provider version, platform, protocol method/result shape,
  plan class when exposed by the provider and safe to record, window percentages,
  durations, reset timestamps, refusal category, and aggregate counts.
- Mark documentation examples, derived replays, and synthetic fallback cases
  separately from live observations.
- Treat an omitted or malformed value as unknown; never replace it with zero.

## What was actually retained

The Codex fixtures retain only redacted JSON-RPC shapes. They include the two
rolling window percentages, window durations, reset timestamps, null refusal
state, safe plan class (`plus`), sparse-notification shape, and the count/state
of reset-credit details. `codexHome`, `userAgent`, all opaque IDs, and credit
descriptions were discarded. The concurrent fixture retains only two labels and
their safe window snapshots.

The Claude fixtures retain the documented `rate_limits` field shape and safe
numeric values from Anthropic's public example. The live preflight fixture
retains only `loggedIn`, `authMethod`, mode outcomes, exit statuses, aggregate
message types, and rate-limit presence; it does not retain a live account,
prompt, response, or provider payload. The model display name in the
documentation-shaped fixture is a placeholder, not an account value.

## Probe behavior

`tools/gate_0a/provider_probe.js`,
`tools/gate_0a/concurrent_codex_read.js`, and
`tools/gate_0a/codex_restart_read.js` keep provider messages in memory only
and project them through an allowlist before writing stdout. They ignore raw
stderr and never write a raw capture. The Codex turn prompt is fixed and
non-sensitive; its text and the response text are not included in output.

Claude authentication was checked with the CLI's JSON status command, then
reduced to the two non-sensitive fields above. After the user completed the
browser login, the probe ran one small JSON and one stream request. Their
outputs were reduced to safe aggregate results; no Claude login token, account
path, prompt, response text, or raw payload was retained. The earlier
unauthenticated preflight remains recoverable in Git history.

## Review checks

Before commit, run:

```text
rg -n '(sk-|Bearer |token|cookie|session_id|threadId|turnId|codexHome|/Users/|/home/)' plans/evidence/00a-capacity-feasibility tools/gate_0a test/gate_0a_capacity_parser_test.exs
git diff --check
```

Any expected protocol words in the first command must be reviewed manually;
the check is not treated as a substitute for human redaction review.
