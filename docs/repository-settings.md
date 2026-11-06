# Repository settings

GitHub repository settings are not stored in the repository, so they cannot
be changed by a pull request. These are the recommended values; a maintainer
applies them in **Settings** on GitHub. None of them had been checked when
this page was written.

## About

- **Description:** Local supervisor for coding agents: sandboxed Claude Code,
  Codex and opencode workers, usage-aware, with verified commits you merge.
- **Website:** leave empty until there is a project site, or link
  `docs/getting-started.md`.
- **Topics:** `ai-agents`, `coding-agents`, `claude-code`, `codex`,
  `opencode`, `elixir`, `phoenix-liveview`, `macos`, `developer-tools`,
  `sandbox`, `local-first`.
- Show **Releases**; hide **Packages** and **Deployments** until used.

## Social preview

Upload a 1280×640 image (Settings → General → Social preview). A crop of
`docs/images/session.png` with the project name works; it shows synthetic
data only.

## Security

- Enable **Private vulnerability reporting** (Settings → Security). `SECURITY.md`
  and the issue chooser point reporters to it.
- Enable **Dependabot alerts** and **secret scanning**. `mix deps.get` already
  reports Hex packages with security advisories.

## Issues and pull requests

- Issue forms are in `.github/ISSUE_TEMPLATE/`; blank issues are disabled.
- Create the labels the forms use: `bug`, `enhancement`.
- Protect `main`: require the `CI / checks` status check and a review before
  merging.

## Before announcing the project

- [ ] Description, topics and social preview set.
- [ ] Private vulnerability reporting enabled.
- [ ] README status note, [install](install.md) and [support](support.md)
      describe the real installation path (source today; a release only after
      the [release checklist](release-checklist.md) passes).
