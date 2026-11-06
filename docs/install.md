# Installing, upgrading and uninstalling

## Current status

**Install from source.** No release archive or Homebrew formula has been
published: the project's GitHub releases page is empty. The repository can
build and seal a release archive and generate a Homebrew formula for it
([release tooling](releases.md)), but that path has not yet been verified on
a clean Mac. Until it is, and a release is published, the commands under
[From a release](#from-a-release-not-yet-published) describe the intended
procedure, not something you can download today.

Supported platform: macOS on Apple silicon. See [support](support.md).

## From source

Follow [getting started](getting-started.md), steps 2–5. In short:

```sh
git clone https://github.com/anukin/shoestring.git
cd shoestring
mix setup
mix chat_client.check
```

Put `bin/shoestring` on your `PATH`, run `shoestring setup`, and start the
service with `mix phx.server`.

State lives under `.shoestring/dev` in the checkout unless you set
`SHOESTRING_STATE_DIR`. `shoestring do` refuses to queue work unless the
service it reaches uses the same database, so give the CLI and the service the
same `SHOESTRING_STATE_DIR`.

### Updating a source checkout

```sh
# stop the service first (Ctrl-C), then:
git pull
mix deps.get
mix ecto.migrate
mix chat_client.check
mix phx.server
```

Read [CHANGELOG.md](../CHANGELOG.md) first. Migrations run forward only;
copy `.shoestring/dev` (or your `SHOESTRING_STATE_DIR`) before migrating if
you may want to go back.

### Removing a source checkout

Stop the service, remove the `shoestring` link or `PATH` entry, and delete
the checkout. That also deletes `.shoestring/dev` and everything Shoestring
recorded, unless you used another `SHOESTRING_STATE_DIR`.

## From a release (not yet published)

A release is a self-contained archive for macOS arm64: it bundles the Erlang
runtime, Shoestring, its static assets, the terminal helper and the chat
screen, plus `LICENSE` and `THIRD_PARTY_NOTICES.md`. It needs Git, Python 3
and Homebrew's `openssl@3` at runtime.

The intended Homebrew install, once a formula is published:

```sh
brew install <tap>/shoestring
shoestring doctor
shoestring init
shoestring setup
shoestring start                 # foreground; opens the UI; Ctrl-C stops it
```

Or, from a verified archive extracted to a new directory:

```sh
shasum -a 256 -c SHA256SUMS
bin/shoestringctl doctor
bin/shoestringctl init
bin/shoestringctl setup
bin/shoestringctl start
```

`init` creates the private state directory (by default
`~/Library/Application Support/Shoestring`), a mode-0600 endpoint secret and
the database. `doctor` is passive; `doctor --probe-providers` also asks each
agent CLI for its version and sign-in status without sending a prompt.
Details: [releases](releases.md#first-run-and-doctor).

### Upgrading a release

1. Finish or cancel running work, then stop the service.
2. Keep the old installation. Install the new version alongside it.
3. Run the new `init` or `start` against the same state directory. If the
   database needs migrating, Shoestring first writes a consistent SQLite
   backup under `backups/` in the state directory, and refuses to migrate if
   it cannot.
4. Run `doctor` and check history in the UI before starting new work.

Rollback is manual and never overwrites current state; see
[upgrade, backup and rollback](releases.md#upgrade-backup-and-rollback).

### Uninstalling a release

```sh
brew uninstall shoestring        # or delete the extracted directory
```

Uninstalling removes the program only. Your database, endpoint secret,
artifacts, worktrees, logs and backups stay in the state directory until you
delete it yourself:

```sh
rm -rf ~/Library/Application\ Support/Shoestring   # only when you are sure
```

## Where Shoestring keeps data

A state directory contains:

```text
<state root>/
  shoestring.db      goals, plans, runs, checks, reviews, grants, lessons
  artifacts/         check output and other recorded files (content-addressed)
  worktrees/         private Git worktrees and storage for each run
  chat/              per-session chat tokens (0700 / 0600)
  backups/           pre-migration database backups
  logs/  run/
```

| Environment | Default |
| --- | --- |
| Source checkout (development) | `<checkout>/.shoestring/dev` |
| Release on macOS | `~/Library/Application Support/Shoestring` |
| Release on other Unix | `$XDG_STATE_HOME/shoestring` or `~/.local/state/shoestring` |

`SHOESTRING_STATE_DIR` overrides both. Shoestring never stores provider
credentials; the agent CLIs keep their own sign-in.

## Settings you may need

| Variable | Default | Meaning |
| --- | --- | --- |
| `SHOESTRING_STATE_DIR` | see above | where state lives |
| `PORT` | `4000` | the UI and local API port |
| `SHOESTRING_BIND` | loopback | bind address. Do not change it: there is no authentication (see [SECURITY.md](../SECURITY.md)) |
| `SHOESTRING_AUTOMATION` | on | `off` stops a release's background reconcilers, usage monitors and daily model refresh |
| `SECRET_KEY_BASE` | generated | a release generates and keeps its own; set only if you manage secrets yourself |
