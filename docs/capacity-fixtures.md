# Capacity Fixture Lifecycle, Regeneration & Live Smoke

This document is the authoritative procedure for the capacity test-fixture
lifecycle: where fixtures come from, how to regenerate them from live
providers, how to perform the secret review before committing, and how the
opt-in live smoke layer relates to deterministic fixtures.

Related code:

* `Shoestring.Harness.Capacity.Fixtures` — fixture root, loading, scanning
* `Shoestring.Harness.Security` — the single redaction/validation surface
  (`redact/1`, `scan_term/1`, `scan_json/1`, `validate_observation/1`)
* `Mix.Tasks.Shoestring.Capacity.Fixtures` — executable commands below
* `Shoestring.Test.CapacityLiveSmoke` — shared live-smoke helpers
* `test/shoestring/harness/capacity/fixture_lifecycle_test.exs` — deterministic
  lifecycle guards (run in the ordinary suite)
* `test/shoestring/harness/capacity/{codex,claude}_live_smoke_test.exs` —
  opt-in live smoke tests (excluded by default)

## 1. Lifecycle

There is exactly ONE canonical fixture set, stored in two places:

```
live providers (codex / claude CLIs on your machine)
  │  capture via allowlist-projecting probes (in memory, §2)
  ▼
plans/evidence/00a-capacity-feasibility/fixtures/   ← immutable evidence originals
  │  manual redaction review + --scan (§3), then --sync
  ▼
test/fixtures/capacity/                            ← tracked, deterministic ExUnit inputs
  │  exercised by fixtures_test, capacity_test, monitor tests, lifecycle guards
  ▼
Capacity.normalize/4 → CapacitySnapshot (required states only)
```

Rules:

* Evidence originals are never mutated. New captures are added as new files or
  go through an explicit, reviewed replacement.
* Tracked fixtures mirror the evidence set 1:1 (same relative paths).
  `fixture_lifecycle_test.exs` fails if the sets drift — there is never a
  second parallel set.
* A live failure (smoke test or `--live-smoke`) reports an
  environment/version mismatch and MUST NOT auto-update, rewrite, or delete
  any fixture. Fixture updates are always a separate, human-reviewed change
  that re-runs the full secret review.

## 2. Regenerating fixtures from live providers

Regeneration is a deliberate, multi-step procedure. Each step is runnable;
nothing in the chain writes a fixture automatically from live output.

### Step 0 — live pre-check (read-only, safe)

```bash
mix shoestring.capacity.fixtures --live-smoke
```

This runs `<cli> --version` only — no sessions, no prompts, no inference —
and compares the result against the tested registry versions
(Codex `0.150.1`, Claude `2.1.251`). Exit `0` means the local providers match
what the fixtures were captured against (or a provider is absent and skipped).
Non-zero means environment/version mismatch: investigate before capturing.

### Step 1 — capture with the allowlist-projecting probes

```bash
node tools/gate_0a/provider_probe.js codex > /tmp/codex-capture.json
node tools/gate_0a/provider_probe.js claude > /tmp/claude-capture.json
```

The probes keep provider messages in memory and project them through an
allowlist before writing stdout: provider version, platform, protocol
method/result shape, safe plan class (`plus`), window percentages/durations,
reset timestamps, refusal category, and aggregate counts. They never persist a
raw capture, raw stderr, prompts, completions, tool output, working-directory
paths, session/thread/turn IDs, or opaque credit tokens. The Codex turn prompt
is fixed and non-sensitive; its text and the response text are excluded.

### Step 2 — redact into a candidate fixture

Create the candidate OUTSIDE the repo (e.g. `/tmp/candidate.json`), keeping
only the allowlisted shape above. Then run the secret review (§3) against the
candidate before it touches `plans/evidence/` or `test/fixtures/`.

### Step 3 — promote to evidence, then sync to tracked fixtures

```bash
# 1. Copy the reviewed candidate into evidence (explicit filename, reviewed separately):
cp /tmp/candidate.json plans/evidence/00a-capacity-feasibility/fixtures/<provider>/<name>.json

# 2. Sync evidence → tracked fixtures (preserves evidence originals):
mix shoestring.capacity.fixtures --sync

# 3. Re-run the secret review gate (§3). It must pass before commit:
mix shoestring.capacity.fixtures --scan

# 4. Prove the deterministic suite is still green offline:
MIX_ENV=test mix test test/shoestring/harness/capacity/
```

## 3. Secret review (required before any regenerated fixture is committed)

Executable gate:

```bash
mix shoestring.capacity.fixtures --scan
```

It runs every tracked fixture through `Shoestring.Harness.Security.scan_json/1`
(raw text + credential-key detection + decoded-term scan) and fails the commit
if any fixture matches. The single review surface covers:

* `sk-*` tokens, `Bearer`/`Basic` credentials, bare `token=` assignments and
  credential markers (`api_key=`, `password:`, `secret=`, …), including
  absent/empty values
* AWS access key IDs (`AKIA`/`ASIA`/`AKIB` + 16 chars)
* GitHub tokens (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`/`github_pat_` prefixes)
* XML/tag-wrapped secrets (`<secret>…</secret>`)
* Compound assignments (`aws_secret_access_key=`, `custom_key:`, …)
* User filesystem paths (`/Users/…`, `/home/…`)
* Forbidden keys (`account_id`, `session_id`, `thread_id`, `turn_id`,
  `prompt`, `transcript`, `stdout`, …) — with word-level tokenization so
  benign keys (`prompt_tokens`, `transcription`, `secretary`) do not trip it

Manual review checklist (in addition to `--scan`):

```bash
rg -n '(sk-|Bearer |token|cookie|session_id|threadId|turnId|codexHome|/Users/|/home/)' test/fixtures/capacity/<provider>/<name>.json
git diff --check
```

Every match must be manually dispositioned; the scan is not a substitute for
human redaction review. Diagnostics from `Security.redact/1` are bounded
(200 chars) and never echo the matched secret.

## 4. Shared contract + provider parser tests

Fixture tests cover all required states; live smoke tests are optional:

* Shared contract: `test/shoestring/harness/contracts_test.exs`
  (`CapacitySnapshot` v2 states, freshness, fail-closed boundaries),
  `test/shoestring/harness/contract_suite_test.exs` (adapter contract),
  `test/shoestring/harness/capacity_test.exs` (`Capacity.normalize/4`
  across modes, drift, staleness, bounds).
* Provider parsers, every tracked fixture: `fixtures_test.exs` (all 21
  fixtures normalize deterministically), `claude_monitor_test.exs`,
  `codex_monitor_test.exs`, plus the Gate 0A parser suite in
  `test/gate_0a_capacity_parser_test.exs`.
* Lifecycle guards: `fixture_lifecycle_test.exs` (evidence mirror, envelope +
  secret-free, every fixture normalizes to a required state, per-provider
  state coverage: Codex `observed`/`degraded`/`unknown`/`refused`, Claude
  `degraded`/`unknown`/`refused`).

## 5. Opt-in live smoke tests

Live smoke tests are optional; fixture tests cover all required states.

* Tagged `@tag :live` (`@moduletag :live` per file) and excluded by default in
  `test/test_helper.exs` (`ExUnit.start(exclude: [:live])`), so a plain
  `mix test` — and ordinary CI (`.github/workflows/ci.yml` runs `mix test`) —
  never executes them.
* Individually selectable per provider and per test:

```bash
# all live smoke tests
mix test --only live
# one provider
mix test test/shoestring/harness/capacity/codex_live_smoke_test.exs --include live
mix test test/shoestring/harness/capacity/claude_live_smoke_test.exs --include live
# a single test
mix test test/shoestring/harness/capacity/codex_live_smoke_test.exs:32 --include live
```

* Low-consumption: the only provider process ever invoked is `<cli> --version`
  (see `Shoestring.Test.CapacityLiveSmoke.version_only/2`). No coding session
  is started, no prompt is sent, no model inference is consumed.
* Safe to skip: when a provider binary is absent from `PATH`, the version
  test reports `SKIP` and passes; the `mix … --live-smoke` task likewise
  reports `SKIP` and exits zero.
* Mismatch policy: an installed version outside the tested registry set (or a
  failing `--version` probe) reports `ENVIRONMENT/VERSION MISMATCH` and fails
  WITHOUT touching `test/fixtures/capacity/`. The smoke files additionally
  assert (via SHA-256 snapshots before/after the probe) that the tracked
  fixtures are byte-identical after the run. To adopt a new version, follow
  §2–§3 as a separate reviewed change.
