# Supported platforms and feature status

Shoestring is pre-release software (version 0.2.0). This page says what you
can rely on, what is experimental, and what is not available yet. When this
page and another document disagree, this page and
[limitations](limitations.md) are meant to be current; please
[report the difference](https://github.com/anukin/shoestring/issues/new/choose).

## Platforms

| Platform | Status |
| --- | --- |
| macOS on Apple silicon (arm64), recent major version | **Supported.** Development, CI (`macos-14`) and release builds target it. |
| macOS on Intel | Not supported. The release build refuses it. |
| Linux | Not supported. The service and test suite may run, but worker and check sandboxing rely on macOS `sandbox-exec`, so checks refuse to run. |
| Windows | Not supported. |

A release records the macOS major version it was built and tested on; its
launcher refuses other majors.

### Runtime requirements

- From source: Erlang/OTP 28, Elixir 1.19, Rust 1.88+, Python 3, Git and a C
  compiler (Xcode Command Line Tools). See
  [CONTRIBUTING.md](../CONTRIBUTING.md#prerequisites).
- From a release package (when one is published): Git, Python 3 and
  OpenSSL 3 (Homebrew `openssl@3`). Erlang, Elixir and Rust are bundled or
  build-only.

### Agent CLIs

Shoestring drives agent CLIs you install and sign in to yourself:

| CLI | Used for |
| --- | --- |
| Claude Code | planner for `shoestring do`; coordinator, worker, explorer, reviewer |
| Codex | coordinator, worker, explorer, reviewer |
| opencode | coordinator, worker (no reviewer path yet) |

Each CLI's output format changes between versions, so Shoestring records which
versions it was tested against. `shoestring doctor --probe-providers` reports
each installed CLI as `ready`, `needs_sign_in`, `version_untested` or
`binary_missing`; the tested versions are listed in
`lib/shoestring/harness/capacity/registry.ex`. An untested version may work,
but treat it as unverified.

## Feature status

**Available** features are implemented, covered by the hermetic test suite,
and have been exercised against real provider CLIs at least once.
**Experimental** features work in tests but have had little or no live use,
or are off by default. **Not yet** means not available.

| Feature | Status | Notes |
| --- | --- | --- |
| `shoestring do`: plan, approve, run, check, result | Available | Claude plans; workers on Claude, Codex or opencode. [Work loop](cli-work-loop.md) |
| Step-by-step `goals`, `plans`, `execution` commands | Available | [Plan review](cli-plan-review.md), [execution](cli-execution.md) |
| Sandboxed workers in private worktrees | Available | macOS only |
| Sandboxed checks (`--test`, `--gate`, project gates) | Available | macOS only; no network inside checks |
| Usage readings and admission reserves | Available | Claude and Codex report usage; opencode never does, so it always asks |
| `shoestring chat` with the native chat screen | Available | [Coordinator guide](coordinator.md) |
| Grants, EXPLORE / IMPLEMENT / REVIEW dispatches, `wait`, `runs` | Available | |
| Chained dispatches (`--after`) and batches (`--tasks`) | Available | |
| Worker asks and per-agent allowed commands | Available | |
| Lessons | Available | Per repository; no shared or semantic store |
| Web UI: Usage, Teams, Agents, Sessions, Lessons, Settings | Available | Loopback only, no login |
| Cross-review in `shoestring do` | Experimental | Off by default (`:plan_review`); verified live only on small fixtures |
| Parallel IMPLEMENT tasks (Settings > parallel tasks > 1) | Experimental | Default 1 (one after another) |
| `shoestring chat --external` (your own coordinator CLI) | Experimental | Interactive start not yet checked in a live session |
| Manual runs (`/runs/new`) and the browser terminal | Experimental | Diagnostic surfaces, outside the main navigation |
| Local and API text adapters | Experimental | [Text adapters](text-adapters.md) |
| Run measurements and shadow forecasts | Experimental | Reports only; they never change admission |
| Release packaging and Homebrew formula generation | Experimental | Built locally; nothing has been published. See [install](install.md) |
| Published releases / Homebrew tap | Not yet | |
| Code signing and notarization | Not yet | |
| Authentication, multiple users, non-loopback access | Not yet | See [SECURITY.md](../SECURITY.md) |
| Forecast-assisted routing | Not yet | |
| Codex or opencode as the `shoestring do` planner | Not yet | |
| opencode as a reviewer | Not yet | |
| Linux sandboxing, other platforms | Not yet | |

## Versioning

Until 1.0, minor versions may change commands, configuration and stored data.
Database migrations run forward only; take the backup described in
[upgrades](releases.md#upgrade-backup-and-rollback) seriously. Changes are
recorded in [CHANGELOG.md](../CHANGELOG.md).
