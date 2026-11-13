# Changelog

All notable changes to Shoestring are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) — before 1.0, a minor version may
change commands, configuration or stored data.

No version has been published yet. The application version in `mix.exs` is
0.2.0; everything below is unreleased. Development history before this file
is summarised by iteration in [docs/history.md](docs/history.md).

## [Unreleased]

### Added

- EXTERNAL dispatches: work done outside Shoestring (a desktop app, a
  signed-in browser) in a private worktree Shoestring makes, accepted only
  by its checks. Always held for the person's start; only a person completes
  (`shoestring external complete`) or abandons it. Grants may carry named
  units (`shoestring grant --units NAME=CAP/RESERVE`), reserved per EXTERNAL
  and settled from the reported actual. The person's checkout is recorded
  before and after, and a change is reported.
- Every plan worker is told to write files with literal-path commands and to
  retry a refused command more simply (Claude Code's don't-ask sandbox
  refuses some compound writes).
- Decision points: a plan task can declare a `decision` and write N
  candidates under `.shoestring/decisions/<id>/`. After its gates pass,
  the plan waits for a person (`human:` only, first answer wins, no
  timer) before the task's dependents run, and gives them the chosen
  candidate as an input. A built-in "none of these" needs a note and stops
  the task for a person. See [the plan contract](docs/plan-contract.md#decision-points-iteration-19).

- Documentation for first-time users: a rewritten README, a
  [getting-started guide](docs/getting-started.md), [installation](docs/install.md),
  [concepts](docs/concepts.md), [supported platforms and feature status](docs/support.md),
  [known limitations](docs/limitations.md), a [documentation index](docs/README.md)
  and [project history](docs/history.md).
- Screenshots of the Usage, Teams, Agents, Sessions and Lessons pages, with
  reproducible, provider-free tooling in `tools/screenshots/`.
- `CONTRIBUTING.md`, `SECURITY.md`, issue and pull request templates, a
  [release checklist](docs/release-checklist.md) and a release-notes template.
- Release builds now carry `LICENSE` and `THIRD_PARTY_NOTICES.md` at the
  release root, naming every bundled Hex package, Erlang/OTP and Elixir
  application, Rust crate and vendored browser asset with its license text.
  A release whose components' license texts cannot be found is refused, and
  the packager refuses a release without these files.
- `license` and `repository` metadata in both Rust manifests.

### Changed

- `PRODUCT.md` and the iteration-14 milestone status reflect the current
  product (Teams, Sessions and Lessons pages; implemented coordinator work).

### Features in this version (summary)

For reference until a first release is cut, 0.2.0 contains:

- `shoestring do`: plan with Claude, approve, run sandboxed workers on Claude,
  Codex or opencode, sandboxed checks, optional cross-vendor review, verified
  result.
- `shoestring chat`: a coordinator (Claude Code, Codex or opencode) in a
  native terminal chat screen, with grants, EXPLORE / IMPLEMENT / REVIEW
  dispatches, chained and batched dispatches, worker asks and lessons.
- A local web UI: Usage, Teams, Agents, Sessions, Lessons and Settings.
- Usage-aware admission with reserves, durable SQLite trajectory, release
  tooling with `doctor`, `init`, `setup`, `start`, backups before migration
  and previewed diagnostics.

[Unreleased]: https://github.com/anukin/shoestring/commits/main
