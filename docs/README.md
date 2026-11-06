# Shoestring documentation

Organised by what you are trying to do. New here? Read the
[project README](../README.md), then [getting started](getting-started.md).

## Start

- [Getting started](getting-started.md) — from a fresh Mac to a merged result
- [Installing, upgrading and uninstalling](install.md) — source installs
  today; the release path; where data lives
- [Supported platforms and feature status](support.md)
- [Known limitations](limitations.md)
- [Concepts](concepts.md) — goals, Elves, grants, dispatches, the trajectory

## Do work

- [The CLI work loop](cli-work-loop.md) — `shoestring do`: checks,
  cross-review, results
- [Working with a coordinator](coordinator.md) — `shoestring chat`, grants,
  dispatches, teams, asks, lessons, the Sessions page
- [The chat channel](chat-channel.md) — how the chat screen talks to the
  service, handoff
- [opencode as a worker](opencode-worker.md)
- [Plan review, step by step](cli-plan-review.md) — `shoestring plans`
- [Execution, step by step](cli-execution.md) — `shoestring execution`
- [Reservations](cli-reservations.md) — `shoestring reservations`

## Configure

- [Worker instructions](worker-instructions.md)
- [Text adapters](text-adapters.md) — optional local and API text calls
- [API spend](api-spend.md)

## Operate and troubleshoot

- [Releases, first run, doctor, upgrades](releases.md)
- [Diagnostics](diagnostics.md) — previewed, sanitized diagnostic bundles
- [Run measurements](measurements.md) and
  [shadow forecasts](shadow-forecasts.md)
- [CLI output contract](cli-output.md) — stdout/stderr, `--json`, exit
  statuses

## Reference: internals and contracts

For contributors and anyone changing an adapter.

- [Plan contract](plan-contract.md) and [planner boundary](planner-boundary.md)
- [Planner evaluation](planner-evaluation.md)
- [Adapter contract suite](adapter-contract-suite.md)
- [Capacity observatory boundary](capacity-observatory-boundary.md),
  [ownership and ingestion](observatory-ownership-and-ingestion.md)
- [Claude capacity monitor](claude-capacity-monitor.md),
  [Codex capacity monitor](codex-capacity-monitor.md),
  [capacity fixtures](capacity-fixtures.md)

## Project

- [Contributing](../CONTRIBUTING.md) and [security policy](../SECURITY.md)
- [Changelog](../CHANGELOG.md) and [release checklist](release-checklist.md)
- [Project history](history.md) — iterations, milestone plans and evidence
- [Repository settings](repository-settings.md) — description, topics,
  social preview
- Product and design records: [PRODUCT.md](../PRODUCT.md),
  [DESIGN.md](../DESIGN.md)

Pages that mention an iteration number describe when a feature arrived; the
behaviour they describe is current unless [limitations](limitations.md) or
[support](support.md) say otherwise.
