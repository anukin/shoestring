<!--
Release notes template. Copy into the GitHub release form and fill in every
section; delete a section only if it is genuinely empty. See
docs/release-checklist.md before publishing.
-->

# Shoestring VERSION

One or two sentences: what this release is for.

## Highlights

- 

## Supported platform

macOS on Apple silicon, macOS MAJOR (the version this release was built and
tested on; the launcher refuses other majors). Requires Git, Python 3 and
Homebrew `openssl@3`. Tested agent CLI versions: Claude Code …, Codex …,
opencode ….

## Install

```sh
brew install TAP/shoestring
```

Or download `shoestring-VERSION-aarch64-apple-darwin.tar.gz` and
`SHA256SUMS`, then `shasum -a 256 -c SHA256SUMS`. This build is not signed or
notarized; describe what macOS shows on first launch and how to proceed.

## Upgrading from PREVIOUS

- Stop the service before upgrading. `init`/`start` back up the database
  before migrating.
- Breaking changes (commands, configuration, stored data):
  - 
- Rollback: see docs/releases.md (Upgrade, backup and rollback).

## Changes

Copied from CHANGELOG.md for this version: Added / Changed / Fixed / Removed.

## Known limitations

Link docs/limitations.md and list anything new or specific to this release.

## Verification

Summarise docs/release-checklist.md results: clean-machine install, first
run, one live task, upgrade, uninstall — with dates and any exceptions.

## Checksums

```text
SHA256  shoestring-VERSION-aarch64-apple-darwin.tar.gz
```
