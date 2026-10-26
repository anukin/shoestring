# opencode as a task worker

An agent's Worker role can run plan tasks through the locally installed
[`opencode`](https://opencode.ai) CLI, the same way Claude and Codex workers
run them: in the task's own worktree, with normalized events, cancellation
that reaps every process it started, and the plan's checks deciding
acceptance. `shoestring do` plans with a Claude Coordinator, and review runs
on Claude or Codex.

## Setup

```sh
shoestring models refresh opencode                # record the models opencode offers
shoestring models show opencode                   # identifiers you can use
shoestring models enable opencode opencode/glm-5.3-flash-free
shoestring agents create builder --coordinator claude:opus \
  --worker opencode:opencode/glm-5.3-flash-free --default
```

- A model is `provider/model`, exactly as opencode reports it. Refreshing
  records every model opencode offers (150 on 2026-10-25) but enables none:
  opencode can reach providers that charge per token, so you choose. An
  opencode role always names a model, never a default. `models add` still
  names one opencode did not report.
- An agent may have an opencode Coordinator, but `shoestring do` drafts
  plans only with a Claude one (`--coordinator claude:MODEL`). A Reviewer role
  cannot be opencode yet: opencode has no review path.
- Cross-review compares model vendors, not harnesses: an `openai/…` worker is
  OpenAI, so a Codex reviewer of it is refused and a Claude one is used. A
  model whose vendor cannot be told (for example `opencode/big-pickle`) waits
  for you instead of being reviewed.
- A role cannot pin an effort for opencode: the levels it offers differ per
  model.
- opencode keeps its own login (`opencode auth login`). Shoestring never signs
  in, stores or reads it. An expired login fails the task as
  `authentication_required` before any model call.

## Capacity

opencode reports no remaining allowance without inference, so its capacity is
always unknown and every opencode task asks for the usual confirmation
(`follow` prompts for it). opencode runs never become calibration examples.

An `openai/…` model uses the same ChatGPT subscription as Codex, and Shoestring
cannot see that use. While a Codex collection window is open, an opencode task
on an `openai/…` model waits; it starts once the window is closed. The Usage
page says this on the opencode card.

## Isolation

opencode has no sandbox of its own, so every opencode task runs under macOS
`sandbox-exec`:

- writes: the task worktree and its private Git storage, opencode's own data,
  state and cache directories (its session database lives there), and a
  temporary directory for the run, removed once the run's processes have been
  stopped;
- reads under your home directory: only those, opencode's configuration
  directory (and what symlinks at its top level point to) and its install
  directory;
- network: allowed, since opencode must reach its model provider;
- environment: `HOME` is the run's temporary directory and the XDG variables
  point at opencode's real directories. opencode otherwise reads `~/.claude`
  and `~/.agents` when a session starts.

opencode's permission requests are answered by that fixed policy: allowed once
inside the sandbox, never "always". A launch that cannot be sandboxed is
refused; there is no unsandboxed fallback.

## Readiness

`shoestring doctor --probe-providers` reads `opencode --version` only.
`opencode auth list` and `opencode models` start opencode's background server
and leave it running, so Shoestring never runs them; sign-in is not detectable
and a tested opencode reports `unknown`, never `ready`. Tested version: 2.0.31.
`shoestring models refresh opencode` instead reads the model choices from an
`opencode acp` session it creates in a temporary directory and never
prompts; that session stays in opencode's own history.

## What has been checked

With opencode 2.0.31 and a free model: a sandboxed task created a file and ran
a shell command; cancelling during a running `sleep` stopped it and ended the
turn as cancelled; a new process resumed a finished session with its earlier
turn in context; reads elsewhere in your home folder and writes outside the
worktree were refused. opencode asked no permission questions in these runs,
so the permission policy is covered by tests only. See
`plans/evidence/13-opencode-harness/README.md`.
