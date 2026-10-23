# Fresh-machine install — 2026-10-23

Status: VERIFIED on two clean macOS 15.7.7 arm64 virtual machines. The user
approved using Tart VMs for this check and granted the terminal Local Network
access so the host could reach them. Not covered: signing, notarization, a
published release URL, or a physical second Mac.

## Environment

VERIFIED: Tart 2.41.1 (Cirrus Labs Developer ID, notarized; the Homebrew tap
formula failed on Homebrew 7 with a `depends_on :macos` error, so the signed
GitHub release was used). Image `ghcr.io/cirruslabs/macos-sequoia-vanilla`,
4 CPUs, 8 GiB. Each VM booted with macOS 15.7.7 (24G720), arm64, PATH
`/usr/bin:/bin:/usr/sbin:/sbin`, no Homebrew, Elixir, Erlang, Mix, Rust, Cargo
or Node. Apple command-line tools provide Git and Python 3; `openssl` is the
system LibreSSL. Commands ran over SSH with a `perl` alarm bound (macOS has
no `timeout`).

## First VM: archive built from `c34a862`

Archive SHA-256 `043ad168dc8390497150a5818b2ca8352a196cad52441f4873146d61fd05b9f5`
verified inside the VM.

- Extracted archive, no Homebrew: `version` printed `shoestring 0.2.0`;
  `doctor` crashed with an Erlang `UndefinedFunctionError` stack trace because
  the bundled crypto NIF links `/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib`.
  **Defect**: a declared dependency missing produced a crash, not a message.
- Homebrew 7.0.10 installed non-interactively; the generated formula, with
  only its `url` pointed at the local file (same `sha256`), installed from a
  local tap. Dependencies pulled: openssl@3, git, python@3.14 and their
  libraries; no language toolchain.
- `doctor` before init: database `needs_init`, helper `compatible`, Git and
  Python present, port available. `init` migrated (logging every migration at
  info); a second `init` reported "Migrations already up". `doctor` after:
  database `ok`, endpoint secret `private`. State directory 0700, secret 0600.
- `start`: health 200 after 3 s, all checks `ok`; UI 200. A second `start`
  refused: "State is owned by a running Shoestring process…". SIGTERM stopped
  it in 3 s, exit 0.
- `brew test` passed. `brew uninstall` removed the binary; the database was
  byte-identical (SHA-256 prefix `534cc17c865bcc62` before and after) and the
  reinstall's doctor reported the database and secret intact.

## Fix: `04ca7d9`

The release manifest records the OpenSSL library the crypto NIF links
(`openssl_library`, read with `otool -L` at build time), and the launcher
refuses before starting the runtime when that file is absent:
"OpenSSL 3 is a required runtime dependency and was not found at … Install it
with Homebrew: brew install openssl@3". Manifests without the field behave as
before.

VERIFIED: `test/shoestring/release/launcher_test.exs` runs the real launcher
against a synthetic release with a stub runtime: 2 tests, 0 failures. On a
worktree of `c34a862` the missing-library test fails with exit 0 instead of
1 (the old launcher ran the runtime). Full gate: `timeout 590 mix precommit
< /dev/null`, exit 0; ExUnit 4 doctests, 2453 tests, 0 failures, 1 skipped,
6 excluded, seed 714615; Rust 4 + 5; Node 52/52 and 14/14.

## Second VM: archive built from `04ca7d9`

Clean build (`source_dirty: false`), archive SHA-256
`be25b1f12931cfbc90ce10a561cdcda5ce3cd0076c6d53f3ef948abb567adbec`, verified
inside a newly cloned VM.

- No Homebrew: `doctor` and `version` each exit 1 with the OpenSSL message.
- Homebrew install as above, then: no toolchain on PATH; `version` 0.2.0;
  doctor before/after init as on the first VM; health 200 after 3 s with all
  checks `ok`; UI 200; second start refused; SIGTERM stop in 3 s, exit 0;
  `brew test` exit 0; `brew uninstall` removed the binary and kept
  `.endpoint-secret`, `.service-lock` and a byte-identical `shoestring.db`.

Observed, not defects: Homebrew labels the local-tap install "Tier 2"; the
health `instance` value is a fingerprint of the database path, so both VMs
(same default path) reported the same one.

## Still open

Signing/notarization (no Developer ID) and publishing the archive at the
formula's release URL. Linux remains deferred.
