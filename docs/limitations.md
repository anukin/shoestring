# Known limitations

The short list of things most likely to surprise you. Each links to the page
with the details.

## Platform and installation

- **macOS on Apple silicon only.** Sandboxing uses macOS `sandbox-exec`. See
  [support](support.md#platforms).
- **No published release.** Install from source. Release packaging exists
  but no archive or Homebrew formula has been published or verified on a
  clean machine. See [install](install.md).
- **Not signed or notarized.** A future downloaded release may be blocked by
  Gatekeeper until it is.

## Security model

- **One local user.** The web UI has no login. It listens on loopback and
  must not be exposed to other users or networks. See
  [SECURITY.md](../SECURITY.md).
- **`--external` coordinators are not sandboxed by Shoestring.** With
  `shoestring chat --external` the coordinator is your own CLI session under
  its own permission prompts. Shoestring's guarantee that your checkout is
  never changed covers Shoestring and its workers, not that CLI.
- **EXTERNAL work is not sandboxed by Shoestring.** An EXTERNAL dispatch's
  work happens outside Shoestring, done by you or a program you drive (a
  desktop app, a signed-in browser). The worktree, the checks, the clock and
  the grant's units are Shoestring's; what happens in the worktree is the
  operator's. Shoestring records your checkout's `HEAD` and status before and
  after and reports a change, but it cannot prevent one. See
  [EXTERNAL dispatches](coordinator.md#external-dispatches-iteration-20).
- **Allowing an ask grants real access.** "Allow once" runs that one command
  outside the sandbox with your full file access (a Claude command also
  gets the network). See [asks](coordinator.md#teams-and-agents-iteration-16).

## Work and results

- **Your checkout must be clean.** `shoestring do` and IMPLEMENT dispatches
  refuse while tracked files are modified; dispatches work from `HEAD`.
- **You merge results yourself.** Completing one task does not give the next
  dispatch its code unless it is chained with `--after`; integrate the commit
  first.
- **Checks have no network.** Tests that need the network, a localhost
  service, or a server they start themselves fail inside the check sandbox.
- **Tools under your home folder.** A check cannot run a `mix` or `python3`
  installed under your home directory (for example by `asdf` or `mise`).
- **Planning uses Claude.** `shoestring do` drafts plans only with Claude.
- **opencode reports no usage.** Every opencode task waits for your
  confirmation (or a grant's pre-approval).
- **Claude usage alone never admits work.** Claude's own reports can defer
  work but not admit it; you, or a grant's `--unread-usage` pre-approvals,
  confirm it.

## Reliability

- **Stopping the service stops its workers.** Runs in flight are recorded as
  failed (`supervisor_crash`) on restart, or watched until their process
  exits. Nothing is retried for you.
- **Raw provider output is evidence, not state.** If a CLI changes its output
  format, Shoestring may record a run as degraded rather than guess. Keep
  agent CLIs on [tested versions](support.md#agent-clis).
- **Reviews are a second opinion.** Cross-review has been measured on small
  seeded cases only; it is not a guarantee of correctness. Read diffs before
  merging.
