# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately**, not in a public issue or pull
request.

1. Use GitHub's private vulnerability reporting: on
   <https://github.com/anukin/shoestring>, open **Security → Report a
   vulnerability**.
2. If that option is not available, open a public issue titled "Security
   contact request" **with no details**, and a maintainer will arrange a
   private channel.

Include what you need for us to reproduce it: the Shoestring version or
commit, macOS version, which agent CLIs and versions were involved, the
steps, and what an attacker gains. Do not include real credentials, tokens or
private repository contents; redact them, as Shoestring's
[diagnostic bundles](docs/diagnostics.md) do.

We aim to acknowledge a report within 7 days and to agree on a disclosure
date with you once a fix is understood. This is a small project without a
bug bounty.

## Supported versions

Shoestring has no published release yet. Security fixes land on the default
branch (`main`); once releases exist, only the latest release will receive
fixes.

| Version | Supported |
| --- | --- |
| `main` | yes |
| 0.2.x (unpublished) | via `main` |

## What Shoestring is designed to protect against

Shoestring is built for **one person on their own Mac**. Its trust boundary is
that local user account. Everything below follows from that.

### Inside the boundary (trusted)

- **You, and any program running as your user.** Such a program can already
  read your files, your state directory and your agent CLIs' credentials.
  Shoestring does not try to defend against it.
- **The state directory** (`~/Library/Application Support/Shoestring` for a
  release, `.shoestring/dev` in a checkout). It holds the database, artifacts,
  worktrees, the endpoint secret and per-session chat tokens, created private
  (0700 directories, 0600 secrets). Do not share it, back it up to shared
  storage, or attach it to an issue.

### What Shoestring does enforce

- **Loopback only, no login.** The web UI, health endpoint, MCP tool endpoint
  and chat channel listen on `127.0.0.1` by default. There is **no
  authentication** on the web UI. Never set `SHOESTRING_BIND` to a
  non-loopback address, put it behind a reverse proxy, or forward its port to
  other users or machines. Multi-user or remote use is not supported.
- **Local-request checks.** The MCP endpoint and chat channel refuse requests
  that are not from a loopback address, that name a non-local `Host` (DNS
  rebinding), or that carry a foreign `Origin` (a web page on another site),
  and require a bearer or per-session token.
- **Your checkout is never modified** by Shoestring or its workers. Workers
  write only to private worktrees outside it.
- **Workers are sandboxed** on macOS: they write only their own worktree and
  private Git storage, cannot read the rest of your home folder, and have no
  network unless an agent's settings allow specific hosts (Claude) or all
  hosts (Codex). opencode workers run with a fixed profile.
- **Checks are sandboxed** separately: no outbound connections, writes only to
  the worktree and a temporary directory, a minimal environment.
- **Grants bound coordinators.** A coordinator can dispatch only the models,
  purposes and amounts its grant allows, cannot grant or widen its own
  allowance, and cannot answer a worker's ask for you.
- **Redaction.** Secret-looking values in briefs, reports, check output and
  diagnostic bundles are replaced with `[REDACTED]`. Redaction is a safeguard,
  not a guarantee: do not put secrets in requests.
- **No credentials stored.** Shoestring never stores provider credentials or
  API keys; agent CLIs keep their own sign-in. Release builds disable Erlang
  distribution.

### Limits you should know

- **A session id is not a secret.** Any program running as you that knows a
  session id can dispatch within that session's grant. The grant's repository,
  models and limits are what bound it.
- **Allowing an ask is real access.** Allowing a worker's ask runs that one
  command outside the sandbox with your full file access; a Claude command
  also runs with the network. "Allow for this agent" lets the exact same
  command run again without asking.
- **Extra permissions widen the sandbox.** Folders and hosts you add to an
  agent apply to every session started afterwards. Codex network access is
  all-or-nothing.
- **`--external` coordinators are outside the sandbox.** With
  `shoestring chat --external`, the coordinator is your own CLI session under
  its own permission prompts; Shoestring does not sandbox it.
- **Provider status probes can refresh credentials.**
  `doctor --probe-providers` and `setup` run the CLIs' own version and
  sign-in status commands, which may refresh tokens. Plain `doctor` does not.
- **Platform.** Sandboxing depends on macOS `sandbox-exec`. On other
  platforms checks refuse to run; do not rely on Shoestring for isolation
  there.
- **Not signed or notarized.** Verify release archives against the published
  `SHA256SUMS` before running them.

## Out of scope

- Attacks that require already running code as the same local user.
- Vulnerabilities in the agent CLIs (Claude Code, Codex, opencode) or the
  model providers themselves; report those to their vendors.
- Exposing the service beyond loopback contrary to this policy.
- Model output quality, including a reviewer approving a bad change.
