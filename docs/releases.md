# Native releases, installation and upgrades

The first release target is macOS arm64 on the macOS major recorded in the
manifest. The launcher refuses other majors before invoking the runtime.
Linux sandboxing and other targets
remain deferred. The release includes ERTS, application/NIF code, static assets,
migrations and the exact PTY helper. Elixir, system Erlang and Rust are build
dependencies, not runtime requirements. Git, Python 3 and Homebrew OpenSSL 3
remain runtime dependencies. No Developer ID signing or notarization is claimed.

## Build and seal a candidate

On the target platform, with the build dependencies installed:

```sh
MIX_ENV=prod mix release --path tmp/my-release-candidate
python3 tools/release/package.py tmp/my-release-candidate tmp/my-package
```

Use new output paths. Nothing is deleted or cleaned automatically. The release
step builds/digests assets and the Rust helper, bundles ERTS and writes
`manifest.json` with target, application/helper/protocol versions, helper hash,
source revision/dirty status, tested macOS version, dependencies and unsigned
status. Unsupported build targets are refused. The packager refuses external
symlinks, unexpected cookies, changed/added files against its sealed file hashes, existing output directories
and dirty tracked source. `--allow-dirty` is for local verification candidates
only and must not be used to publish one.

The local output contains the target archive, `SHA256SUMS`, and a Homebrew
formula bound to that archive's exact hash. The formula references the proposed
GitHub versioned release URL; it is not installable from that URL until a human
publishes the verified archive. The archive has not been published by these
commands. Distribute the checksum through the trusted release channel.

The generated formula installs under Homebrew's private libexec and exposes
`shoestring`, with OpenSSL/Git/Python dependencies. Its wrapper adds the selected
Python's major-version command directory to PATH. Binary removal through
Homebrew does not remove user state. A local relocated-release smoke is:

```sh
python3 tools/release/smoke.py tmp/my-release-candidate tmp/my-synthetic-state
```

It uses guarded system-tools-only PATH and synthetic state, starts no provider,
checks initialization, helper, SQLite, confirmed diagnostic export, HTTP health
and UI, then explicitly terminates its foreground application. This is a local
runtime/relocation test, not a claim of installation on another clean machine.
An actual fresh-machine/Homebrew install remains an external acceptance check.

## First run and doctor

After checking the archive hash, extract to a new installation directory:

```sh
bin/shoestringctl doctor
bin/shoestringctl start
```

The Homebrew command is `shoestring doctor` / `shoestring start`. `start` stays
in the foreground. Stop it explicitly with Ctrl-C or SIGTERM. There is no
automatic service installation, daemon/reaper, forced shutdown of another
instance or file cleanup.

First run creates a mode-0600 persistent endpoint secret and migrates SQLite
before starting the UI. A supplied `SECRET_KEY_BASE` of at least 64 bytes takes
precedence and is not copied into state. Invalid/public/symlinked secret files
are refused without rewriting them. An interrupted secret creation can leave
an invalid file; inspect and repair it explicitly. Never share these files.

State defaults to the macOS application-support directory. Set
`SHOESTRING_STATE_DIR` explicitly to choose another location. Use a private
directory and retain it across binary upgrades. `PORT` defaults to 4000 and
binding defaults to loopback. Initialize without starting the UI with `init`.
Normal launcher starts/initialization take a non-expiring OS advisory state
lock; concurrent launchers refuse. The persistent lock file is not deleted.
Port conflict also refuses initialization. Stop the old service before an
upgrade. Bypassing the launcher or hard-killing its controller is not a verified
upgrade procedure; do not use raw runtime commands to start competing instances.

The passive doctor checks target/manifest, helper checksum and actual hello
compatibility, Git/Python presence, endpoint-secret privacy, SQLite health and
port availability. Missing state says `needs_init`; it is not silently migrated.
Provider installation discovery is passive and authentication says `not_checked`.
To explicitly run bounded metadata commands, use `doctor --probe-providers`.
It calls only `--version`, `claude auth status`, and `codex login status`; no
model prompt is sent. Raw bounded status text is discarded. Only numeric
versions, fixture compatibility and reported authentication status survive.
Reported authentication is not proof that a future inference will succeed.
Version drift asks for fixture review rather than claiming compatibility.
Provider status commands may refresh credentials or exchange identity tokens;
use passive doctor when those effects are unwanted.

Erlang distribution/RPC is disabled. The packaged cookie is a public sentinel,
not a shared authentication secret. Remote/daemon commands from the underlying
generated runtime are unsupported. The supported entrypoint is `shoestringctl`.

## Upgrade, backup and rollback

1. Finish or explicitly cancel work, then stop the old foreground service.
2. Retain the old binary installation. Extract the new archive to another path.
3. Use the same private state directory and run the new `init` or `start`.
4. If migrations are pending for an existing database, initialization creates
   a unique consistent SQLite backup under the private `backups/` directory
   before migrating. Failure to back up refuses migration. Current schemas
   create no repeated upgrade backup. No backup is automatically deleted.
5. Run doctor and inspect the UI/history before submitting more work.

The backup uses SQLite's [VACUUM INTO](https://www.sqlite.org/lang_vacuum.html),
which copies logical database content without rewriting the source database.
The backup directory is 0700 and completed files are 0600 and synced. An
interrupted backup may be incomplete; a successful backup is a pre-migration
snapshot, not continuous replication. Retain sufficient disk space. Back up
artifacts and other state separately as well: the SQLite copy does not contain
artifact file bytes or worktree contents.

Schema rollback is not automatic and is not guaranteed compatible with older
binaries. To revert, stop the new service, preserve current state, copy the
pre-upgrade database and corresponding artifact/worktree state into a **new**
state directory, and point the retained old binary there. Verify integrity and
history before resuming. Work created after the snapshot will not be present
in that restored copy. No command here overwrites current state or deletes data.

Uninstall removes the installation/binary only. User databases, endpoint secret,
artifacts, worktrees, logs and backups remain until the user explicitly chooses
to remove them. Never treat uninstall or an age threshold as permission to
delete that state.

## Troubleshooting

Use [previewed diagnostics](diagnostics.md) with `diagnostics-preview` and
`diagnostics-export PATH SHA256` in the release. These commands open existing
state without migrations and never upload. A wrong/missing helper or changed
checksum requires the matching release artifact; do not bypass the protocol
check. A missing OpenSSL library requires the declared runtime dependency.
Unknown CLI versions require fixture/schema review. Authentication is performed
using the provider's own login workflow; do not paste credentials into a bundle.
