# Codex observations

## Environment and preflight

| Field | Value |
| --- | --- |
| OS | macOS Darwin 24.6.0 |
| Architecture | arm64 |
| Codex CLI | `codex-cli 0.150.1` |
| Node runtime for disposable probe | `v26.5.0` |
| Authenticated mode | ChatGPT-managed Codex session; `codex login status` exited 0 |
| Account plan class exposed by App Server | `plus` |
| App Server transport | `codex app-server --stdio` |
| Local plan class | Codex `plus` was recorded; no credential material or account identifier was recorded |

The installed App Server is an official Codex CLI surface. The probe did not
inspect or copy the Codex authentication store. The official protocol reference
used at execution time was the [Codex App Server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md),
including its handshake and account rate-limit sections.

## Reproducible procedure

From the repository root:

```text
node tools/gate_0a/provider_probe.js codex
node tools/gate_0a/concurrent_codex_read.js
node tools/gate_0a/codex_restart_read.js
mix test test/gate_0a_capacity_parser_test.exs
```

The probe sends `initialize`, `initialized`, `account/read` with
`refreshToken=false`, and `account/rateLimits/read` before any model response.
It starts one ephemeral thread, sends two fixed no-tool turns requesting an
exact short response, waits for `turn/completed`, and reads rate limits after
each turn. It never deliberately approaches a hard limit.

## Handshake and account discovery

The handshake completed. The redacted initialize result contained the keys
`codexHome`, `platformFamily`, `platformOs`, and `userAgent`; the path-bearing
value and user-agent value were discarded. The safe platform result was
`platform_family=unix`, `platform_os=macos`.

`account/read` returned a ChatGPT account, `plan_type=plus`, and
`requires_openai_auth=true`. No email or account identifier was retained.

## Live rate-limit snapshot

The latest two-turn run started at `2026-08-29T04:38:15.702Z`. The initial read
at `2026-08-29T04:38:16.163Z` returned:

| Bucket | Used | Duration | Reset |
| --- | ---: | ---: | --- |
| primary | 13% | 300 minutes | `2026-08-29T09:09:01Z` (`1787994541`) |
| secondary | 16% | 10080 minutes | `2026-09-04T04:08:49Z` (`1788494929`) |

The snapshot also returned `rateLimitReachedType=null`,
`spendControlReached=false`, `planType=plus`, one available reset credit, and
the multi-bucket key `codex`. Reset-credit detail rows were present but their
opaque IDs and descriptions were redacted.

Both normal turns completed. Their elapsed times were 2865 ms and 1123 ms.
The post-turn reads at `04:38:19.418Z` and `04:38:20.911Z` returned the same
13%/16% values and reset timestamps. The primary percentage had changed from
12% to 13% between an earlier probe at `04:30:38.350Z` and this later run;
this demonstrates that the provider value can change between observations,
not that every turn changes it.

## Update notifications and freshness

Two `account/rateLimits/updated` notifications were received during the two
turns, at `04:38:19.099Z` and `04:38:20.540Z`. Their primary and secondary
windows matched the subsequent explicit reads. Both notifications were sparse:
they omitted `spendControlReached`, reset-credit details, and the multi-bucket
map. The probe emits omitted nullable fields as absent. A future production
merge layer must preserve the last known value when applying such sparse
updates; the Gate 0A parser normalizes one captured payload and does not
perform that merge. Omission must never become false, zero, or an empty bucket.

In this client-receipt sample each notification arrived approximately 1 ms
before the corresponding `turn/completed` event; no notification arriving after
completion was seen. The maximum observed notification-to-completion receipt
gap was therefore 1 ms in this two-turn run. This is only local event ordering,
not a measurement of provider-side generation or a universal freshness
guarantee. The safe production boundary remains the completed response/tool
operation followed by an explicit read.

The explicit reads returned the most recently observable snapshot. Because the
values did not differ from the notifications, this probe cannot establish
whether `account/rateLimits/read` forces a backend refresh or merely returns the
last known provider observation. Iteration 3 must treat the call as a fresh-read
request with an evidence timestamp, not as synchronized metering.

## Startup, restart, concurrency, and failures

- Startup-before-response was verified: the initial `account/rateLimits/read`
  happened before either turn.
- Process restart was verified live at `2026-08-29T05:22:15.906Z`: one App
  Server process was stopped after a read, a new process completed the same
  handshake and read, and both sanitized snapshots reported 22% primary, 18%
  secondary, the same durations/resets, `plan_type=plus`, and no refusal. The
  re-read was approximately 1,134 ms after the first observation. This is one
  consistency sample, not proof that all provider state survives every future
  restart.
- A second probe launched two fresh App Server processes concurrently at
  `05:22:15.986Z`; both returned identical 22% primary and 18% secondary
  snapshots, including durations, resets, plan class, and no refusal. This is
  evidence that the two connections observed the same account-level value at
  that instant. It is one sample and does not prove cross-session enforcement or
  update synchronization.
- A missing secondary bucket, stale observation, malformed value, and stdio
  disconnect are represented by replay fixtures. They are parser safety cases,
  not claims that those exact failures occurred in the live run.
- A hard-limit refusal was not deliberately induced. The refusal fixture is a
  clearly labeled sanitized shape based on the official `rateLimitReachedType`
  schema and is used only to evaluate the fallback.

The parser produces `degraded` for a fresh partial snapshot, `degraded/low`
confidence for stale data, `unknown/none` for malformed or disconnected data,
and `refused` only for an explicit structured reached type. None of those cases
is treated as zero usage or unlimited capacity.

## Evidence files

- `fixtures/codex/normal-read.json` is a redacted live explicit-read result.
- `fixtures/codex/sparse-update-live.json` is a redacted live sparse update.
- `fixtures/codex/concurrent-read-live.json` is the redacted two-process sample.
- `fixtures/codex/restart-read-live.json` is the redacted process-restart and
  re-read sample; its `payload` is the parser-consumable first read and its
  `observations` retain only the two normalized comparisons.
- `fixtures/codex/partial-missing-secondary.json` is a labeled documentation
  shape for an absent optional bucket.
- `fixtures/codex/stale-replay.json`, `malformed-replay.json`,
  `disconnect-unverified.json`, and `refusal-unverified.json` drive the safe
  fallback evaluations; their labels identify synthetic or derived evidence.
