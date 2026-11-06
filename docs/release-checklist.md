# Release checklist

For maintainers. A release is published only after every box below is
checked on a **clean, supported Mac** (Apple silicon, the macOS major recorded
in the manifest, no Elixir, Erlang, Rust or previous Shoestring installed) and
the results are recorded in the release's evidence. Until then, documentation
must keep saying that no release is published.

Build and packaging commands are described in [releases](releases.md).

## 1. Prepare

- [ ] `main` is green in CI (`mix precommit` and the production release build).
- [ ] Version bumped in `mix.exs`; `CHANGELOG.md` has a section for it, moved
      from **Unreleased**, with the date.
- [ ] [Support](support.md) and [limitations](limitations.md) match what ships.
- [ ] Tested agent CLI versions in `lib/shoestring/harness/capacity/registry.ex`
      are current, or known gaps are listed in the release notes.

## 2. Build and seal (on the build Mac)

- [ ] Clean, committed tree: `git status` shows nothing.
- [ ] `MIX_ENV=prod mix release --path tmp/rc-VERSION` succeeds.
- [ ] `LICENSE` and `THIRD_PARTY_NOTICES.md` are at the release root; skim the
      notices table for anything unexpected.
- [ ] `python3 tools/release/package.py tmp/rc-VERSION tmp/pkg-VERSION`
      succeeds **without** `--allow-dirty`.
- [ ] `python3 tools/release/smoke.py tmp/rc-VERSION tmp/smoke-state-VERSION`
      passes.

## 3. Verify on a clean Mac

Copy only the archive, `SHA256SUMS` and the formula to the clean machine.

Install and first run:

- [ ] `shasum -a 256 -c SHA256SUMS` passes.
- [ ] Homebrew install from the formula (local tap) succeeds and pulls
      `openssl@3`, `git` and Python.
- [ ] `shoestring version` prints the expected version.
- [ ] `shoestring doctor` reports `needs_init`, then after `shoestring init`
      reports healthy state, helper and SQLite.
- [ ] Gatekeeper behaviour on first launch is noted (the build is not
      notarized) and the release notes say what users will see.
- [ ] `shoestring setup` detects installed agent CLIs and saves an agent.
- [ ] `shoestring start` serves the UI on `127.0.0.1:4000` and `/health`
      answers `ready: true`; every navigation page renders.
- [ ] One complete `shoestring do` task in a scratch repository (live provider
      run — needs an explicit run budget) ends with a verified commit that
      merges cleanly.
- [ ] `shoestring chat` opens the chat screen and starts a session after the
      grant is confirmed.

Upgrade (install the previous release first, create a goal, then upgrade):

- [ ] Stopping the old service, installing the new one and running `init`
      writes a pre-migration backup under `backups/` and migrates.
- [ ] History created before the upgrade is visible afterwards.
- [ ] The rollback procedure in [releases](releases.md#upgrade-backup-and-rollback)
      restores the old version against a copied state directory.

Uninstall:

- [ ] `brew uninstall shoestring` removes the program.
- [ ] The state directory is still present and untouched.

## 4. Publish

- [ ] Tag `vVERSION` on the exact source revision in the manifest.
- [ ] Create the GitHub release from
      [`.github/release-notes-template.md`](../.github/release-notes-template.md);
      attach the archive and `SHA256SUMS`.
- [ ] Publish the formula to the tap; `brew install` from the tap on the clean
      Mac succeeds.
- [ ] Update [install](install.md), the README status note and
      [support](support.md) to describe the published path.
