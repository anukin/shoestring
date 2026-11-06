# Getting started

This guide takes one path from a Mac with nothing installed to a verified
change merged into one of your repositories. It builds Shoestring from source,
because no packaged release has been published yet (see
[installation](install.md)).

Budget about 30 minutes, most of it compiling.

## 1. Check that your machine is supported

Shoestring currently supports **macOS on Apple silicon (arm64)** only. Worker
and check sandboxing use macOS `sandbox-exec`; on other platforms the service
starts, but checks refuse to run. See [support](support.md).

## 2. Install the prerequisites

| Tool | Version | Why | How |
| --- | --- | --- | --- |
| Xcode Command Line Tools | current | Git and the C compiler SQLite's driver needs | `xcode-select --install` |
| Erlang/OTP | 28 | runtime | `brew install elixir` installs both |
| Elixir | 1.19 | runtime and build | (as above) |
| Rust | 1.88 or newer, with `rustfmt` and `clippy` | builds the terminal helper and the chat screen | [rustup](https://rustup.rs), then `rustup component add rustfmt clippy` |
| Python | 3 | launches each worker in its own process group | ships with the Command Line Tools |
| Claude Code | a [tested version](support.md#agent-clis) | plans `shoestring do` requests; default coordinator | install it and sign in (`claude`) |
| Codex, opencode | optional | more worker and reviewer choices | install and sign in if you want them |

Prefer Homebrew (or another install outside your home folder) for Elixir and
Python: Shoestring's check sandbox cannot run a `mix` or `python3` installed
under your home directory, as version managers such as `asdf` or `mise` do.

Shoestring never asks for an API key. It uses the CLIs' own sign-in and their
subscriptions.

## 3. Build Shoestring

```sh
git clone https://github.com/anukin/shoestring.git
cd shoestring
mix setup
mix chat_client.check
```

`mix setup` fetches dependencies and creates the development database under
`.shoestring/dev` in the checkout. `mix chat_client.check` builds and tests the
terminal chat screen used by `shoestring chat`.

Put the `shoestring` command on your `PATH`. Either link it:

```sh
ln -s "$PWD/bin/shoestring" /opt/homebrew/bin/shoestring
```

or add the checkout's `bin/` directory to `PATH` in your shell profile. The
wrapper runs the same commands as an installed release, with this checkout's
code and state.

## 4. Choose your agents

```sh
shoestring setup
```

`setup` checks which agent CLIs are installed and signed in, asks each one
for its models (no prompt is sent, nothing is charged), suggests a
Coordinator, Worker and Reviewer — the reviewer from another vendor than the
worker — and asks before saving them as your default agent. You can change
them later on the **Teams** and **Agents** pages.

## 5. Start the service

In a terminal you leave open:

```sh
mix phx.server
```

Open <http://localhost:4000>. The **Usage** page fills in as providers report
their allowances. `http://127.0.0.1:4000/health` answers `ready: true` when
everything is up. The service listens on loopback only.

## 6. Run your first task

Pick a Git repository with a clean working tree and at least one test file.
In a new terminal:

```sh
cd ~/code/my-project
shoestring do "make add() return the sum of its arguments" --test test/test_calc.py
```

What happens:

1. **Plan.** Claude drafts a plan from your request and the list of tracked
   file names (never their contents). It is printed.
2. **Approve.** Answer `y` to approve exactly that plan, `n` to stop, or `e`
   to edit it. Nothing runs before you approve.
3. **Run.** The service runs each task as a sandboxed worker in a private
   copy of your repository at `HEAD`, then runs the checks (`--test`, or ones
   it detects) on the worker's commit.
4. **Wait for you, if needed.** If a provider's remaining usage cannot be
   confirmed, or a worker asks to run a command outside its sandbox, you are
   asked. Nothing is answered for you on a timer.

Ctrl-C only detaches; the work continues. Reattach with
`shoestring follow GOAL`.

## 7. Inspect and merge the result

```sh
shoestring result GOAL          # final commit, checks, reviews, diff stat
shoestring checks GOAL          # every check run and its result
```

`result` ends with the commands to take the change:

```sh
cd ~/code/my-project
git fetch <run worktree> <commit>
git merge FETCH_HEAD
```

Review the diff before you merge, as you would any contribution.

## 8. Next: work with a coordinator

When a change is bigger than one request, let an agent split it up:

```sh
cd ~/code/my-project
shoestring chat
```

`chat` first shows the **grant** it proposes — which models it may use, how
many tasks, how long, how many may run at once — and starts only after you
confirm. In the chat screen you talk to the coordinator; it reads your
repository (read-only) and sends EXPLORE, IMPLEMENT and REVIEW dispatches to
Shoestring. Follow them on the **Sessions** page or with
`shoestring runs list`. `/help` lists the keys; leaving the screen leaves the
work running, and `shoestring chat --session ID` reattaches.

Read [working with a coordinator](coordinator.md) before your first long
session.

## Where to go from here

- [Documentation index](README.md)
- [The CLI work loop](cli-work-loop.md): checks, cross-review and limits of
  `shoestring do`
- [Known limitations](limitations.md)
- Something wrong? [Troubleshooting](releases.md#troubleshooting) and
  [diagnostics](diagnostics.md), then
  [open an issue](https://github.com/anukin/shoestring/issues/new/choose).
