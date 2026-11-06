# Contributing to Shoestring

Thanks for helping. This page covers reporting problems, setting up a
development checkout, the rules the test suite follows, and how changes are
reviewed. For what Shoestring is and how to use it, start with the
[README](README.md) and [concepts](docs/concepts.md).

## Reporting bugs and asking for features

- **Security problems:** do not open a public issue. Follow
  [SECURITY.md](SECURITY.md).
- **Bugs:** [open an issue](https://github.com/anukin/shoestring/issues/new/choose)
  with the bug template. The most useful reports include:
  - the Shoestring commit (`git rev-parse HEAD`) or release version;
  - macOS version and chip;
  - `shoestring doctor --json` output (it contains no credentials);
  - agent CLI names and versions;
  - the commands you ran and what you expected;
  - for work that went wrong, the goal or dispatch id and the relevant
    `shoestring follow` / `runs log` lines.

  A [diagnostic bundle](docs/diagnostics.md) can help, but read its preview
  first and attach only what you are comfortable sharing. Never paste tokens,
  credentials, state-directory files or private repository contents.
- **Features:** use the feature template and describe the problem before the
  solution. Check [support](docs/support.md) and
  [limitations](docs/limitations.md) first; many gaps are known.

## Prerequisites

Development is supported on **macOS on Apple silicon**, the platform CI and
releases use. The suite may run elsewhere, but sandboxed checks only work on
macOS.

| Tool | Version | Used for |
| --- | --- | --- |
| Erlang/OTP | 28 (CI: 28.3.1) | runtime |
| Elixir | 1.19 (CI: 1.19.5) | everything |
| Rust | 1.88 or newer, with `rustfmt` and `clippy` | `native/terminal_helper` (PTY helper) and `native/chat_client` (chat screen); both are built and checked by the gate |
| Python | 3 | the worker process-group launcher (`Shoestring.Elves.PortRunner`), release tooling and some tests |
| Node.js | 18 or newer | `node --test` UI and Gate 0A tests in the gate (not needed at runtime) |
| Git, C compiler | Xcode Command Line Tools | SQLite driver build, worktrees |

```sh
xcode-select --install
brew install elixir node              # Elixir pulls in Erlang/OTP
curl https://sh.rustup.rs -sSf | sh   # then:
rustup component add rustfmt clippy
```

Install Elixir and Python outside your home directory (Homebrew is fine):
Shoestring's check sandbox refuses a `mix` or `python3` under `$HOME`, which
affects tests that run real checks.

You do **not** need Claude Code, Codex or opencode, provider accounts or
network access to develop or run the tests.

## Build and run

```sh
mix setup                # deps, state directory, development database
mix chat_client.check    # builds/tests the chat screen, installs priv/bin/shoestring-chat
mix terminal.build       # builds the PTY helper into priv/bin
mix phx.server           # UI at http://localhost:4000
```

Development state lives in `.shoestring/dev`. Use `bin/shoestring` to run CLI
commands against it, or the matching Mix task (`mix shoestring.goals list`).

## The gate

Before you open or update a pull request, run:

```sh
mix precommit
```

It runs, in order: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix terminal.check` and
`mix chat_client.check` (`cargo fmt --check`, `clippy -D warnings`,
`cargo test` for each native program), `mix test.partitioned` (the ExUnit
suite as 16 partitions, 8 at a time), and the Node tests
(`mix gate_0a.node_test`, `mix ui.node_test`). CI runs the same gate on
`macos-14`, then builds a production release.

While iterating, run only what you touched:

```sh
mix test test/path/to/file_test.exs
mix test --failed
```

In a pull request, quote the exact gate command you ran and its counts (for
example the summed test and failure counts `mix test.partitioned` prints).
If something fails for a reason unrelated to your change, say so with the
output; do not skip or disable the test.

## Testing rules

The suite must stay **hermetic**:

- **No provider CLIs, accounts or network.** Use `Shoestring.Harness.Fake`,
  the scripted transports and the stand-ins in `test/support/`, or trivial
  local commands. A test whose code path could launch a provider CLI
  installs `Shoestring.Test.ProviderCliGuard`, which shims `claude` and
  `codex` and fails the test if one is spawned. "It fails because no CLI is
  installed here" is not hermetic: on a machine with the CLI, the same test
  would launch it.
- **Isolated state.** Tests use a unique temporary state root
  (`SHOESTRING_TEST_STATE_DIR`); never point a test at real state.
- **Processes:** start them with `start_supervised!/1`; wait with
  `Process.monitor/1` and `assert_receive`, not `Process.sleep/1`.
- **LiveView tests** assert on element ids with `has_element?/2`, not raw
  HTML.
- **A bug fix comes with a regression test** that fails on the commit before
  the fix.
- **Fixtures are redacted.** Recorded provider output used as a fixture must
  have identifiers, paths and anything secret-looking removed; follow the
  conventions in the relevant `plans/evidence/<iteration>/README.md`.

Live runs against real providers (evaluations under `tools/live_eval/`) spend
real usage. They are never part of the gate and need the maintainer's
explicit go-ahead, including a run budget.

## Design rules

[AGENTS.md](AGENTS.md) lists project conventions and the decisions that are
locked. The ones most likely to matter in a change:

- The user's source checkout is never modified; worktrees live outside it.
- No timer, quiet heartbeat or missing response may by itself interrupt,
  replace or duplicate a worker that may still be useful. Staleness is
  evidence, not a trigger.
- Cancelling a run terminates its whole process group.
- Raw provider output is diagnostic evidence, never canonical state.
- Oversized output fails the run; it is never silently truncated.
- Use `Req` for HTTP. Use the existing Phoenix 1.8 / LiveView conventions in
  AGENTS.md for UI code.

The [architecture map](docs/concepts.md#architecture-map) shows where things
live.

## Documentation

- User-facing behaviour changes need a docs change in the same pull request:
  the relevant page under `docs/`, plus [support](docs/support.md) or
  [limitations](docs/limitations.md) if the status of a feature changes.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
- UI changes: regenerate the affected screenshots with
  [`tools/screenshots`](tools/screenshots/README.md).
- Keep milestone plans and evidence records (`plans/`) as historical records;
  do not rewrite their past claims.

## Pull requests

1. Branch from `main`, keep the change focused, and write commit messages
   that say what changed and why.
2. Run `mix precommit` and fill in the pull request template, including the
   gate result and anything you could not verify.
3. A maintainer reviews every change. Expect questions about tests and about
   anything that widens what workers or coordinators may do.

By contributing you agree that your contribution is licensed under the
project's [MIT License](LICENSE).
