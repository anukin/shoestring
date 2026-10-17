# Iteration 8: deterministic verification and cross-review — evidence

Milestone: `plans/milestones/08-verification-cross-review.md` (local plan; not
yet committed). Iteration 7 and 7A were accepted by the user on 2026-10-16.

## Work package 0: sandboxed checks

Date: 2026-10-16. Branch `iter8/sandboxed-checks` from `09ea714`, whose `lib`,
`test`, `config`, `mix.exs` and `mix.lock` are identical to `b94f477`
(VERIFIED: `git diff --stat b94f477 09ea714 -- lib test config mix.exs mix.lock`
printed nothing). Platform: macOS 15.7.7, Elixir 1.19.5, OTP 28, Python 3.12.

### What was built

- `Shoestring.Cobbler.GateSandbox`: wraps a trusted gate argv as
  `sandbox-exec -p <profile> env -i <allowlist> <argv>`. The profile is
  generated from Shoestring's own paths (`GitSandbox.policy/3` roots, the gate's
  temporary directory, the home directory), never from plan or model text:
  - reads: the home directory is denied except the worktree, its private Git
    storage and the gate's temporary directory; file metadata under home stays
    readable; everything outside home (the toolchain) is readable;
  - writes: only the worktree (not its `.git` link file), the temporary
    directory and the standard `/dev` sinks;
  - network: all outbound denied, including localhost; bind and inbound on
    localhost are allowed because Mix's cross-process compile lock and pubsub
    listen there;
  - environment: `PATH`, `LANG`/`LC_ALL`/`LC_CTYPE` when set, `HOME` and
    `TMPDIR` set to the gate's temporary directory, and the home-free Git
    variables Elves use; nothing else from the service.
- Fail closed: no mechanism (any platform but macOS, or no
  `/usr/bin/sandbox-exec`), a worktree that is not a registered private run
  worktree, an invalid binding, an executable installed under the home
  directory, or a path the profile cannot quote safely all return
  `{:error, {:gate_unavailable, %{reason: reason}}}`. The command never runs.
- `PlanGateRunner` runs every real gate through it and adds
  `sandbox: "macos_seatbelt:v1:sha256:<profile digest>"` to evidence; stored
  accepted evidence carries it as `"sandbox"`. Injected test runners carry
  `nil`.
- The executor records an unavailable gate as `cobbler.plan.task.gate_failed`
  with `retry_state` `needs_user` and the `gate_unavailable` reason, so it never
  spends another Elf attempt. `follow` prints "checks could not run in a
  sandbox (<gate>: <reason>); needs your decision", not "checks failed".
- `PlanWorkspace` passes the worktree root to the gate runner for task,
  global and integration gates.
- Timeout, output limit and process-group kill are unchanged: `sandbox-exec`
  and `env` exec in place, so the gate stays the owned group leader.

### Required evals (hermetic, `test/shoestring/cobbler/gate_sandbox_test.exs`)

Real `sandbox-exec` and `python3` gates over a registered private run worktree
that lives under a scratch home directory (itself under the real home
directory), with a localhost listener and a synthetic token owned by the test.

| Eval | Result on the branch | Against `b94f477` (VERIFIED, same test file) |
| --- | --- | --- |
| Read outside the worktree | pass: secret read and home listing denied, worktree file read | fails: the secret was read (`read_outside` = the secret) |
| Write outside the worktree | pass: outside file and `.git` link denied; worktree (ignored path) and temporary directory written | fails: `write_outside` = `written` |
| Network | pass: connect to the test's localhost listener denied; listener accepted nothing | fails: `connect` = `connected` |
| Environment | pass: synthetic token absent; `PATH` present; `HOME` = `TMPDIR` | fails: the token was visible |
| No mechanism | pass: unavailable, probe never ran | fails: the gate ran (`{:ok, ...}`) |
| Not a private run worktree | pass: unavailable, probe never ran | fails: the gate ran |
| Toolchain under home | pass: unavailable (`toolchain_under_home`) | fails: the gate ran (exit 99) |
| Sandbox identity | pass | fails on a missing `:sandbox` key: documents the new field, not a regression lock |
| Lifecycle: timeout | pass: `gate_timeout`, gate was its group leader, group (including a TERM-ignoring descendant) only zombies afterwards | passes (unchanged behaviour, as required) |
| Lifecycle: oversized output | pass: `gate_output_oversized` | passes |

Executor: `plan_executor_test.exs` "a gate that cannot be sandboxed stops for
the user instead of retrying" passes on the branch and fails against
`b94f477` with `retry_state` `"retry"`. `follow_test.exs` covers both the
unavailable line and the ordinary failed-checks line.

`plan_python_gate_test.exs` now runs its real Python reference gates in a
registered private worktree (a plain repository is refused by design) and
asserts the sandbox identity; its gate assertions are unchanged.

Linux: not implemented. CI is macOS-only (`macos-14`) and the support claim is
macOS, so no test is excluded; on another platform every real gate is
unavailable (fail closed). `bwrap` was not available to test here.

### Gate

VERIFIED: `mix precommit` exited 0: **4 doctests, 2221 tests, 0 failures,
1 skipped (6 excluded)**, seed 613961, 458.8 s. JavaScript **52/52** and
**8/8**.

### Full-loop rehearsal (no provider call)

VERIFIED: `tools/live_eval/iter7a_work_loop.exs` with `ITER7A_MODE=rehearsal`
and a new evaluation root under the home directory passed **1 of 1**: plan
approved, held task confirmed, Fake Elf run, task accepted, all checks passed,
result printed; fixture source unchanged; the printed merge in a clone passed
its tests; 68.2 s, 1 run, 1 planner attempt. The exported domain events
carry two sandbox identities, one for the task gate and one for the final
goal gate (`macos_seatbelt:v1:sha256:3d72fe8b…` and `…:ae6e8165…`).

### Manual probes (scratch, before the module was written)

VERIFIED, with a hand-written profile using the same rules:

- `python3 -B -m unittest` and `mix test` (a dependency-free Mix project, cold
  `_build`) pass under the profile with `HOME`/`TMPDIR` in a temporary
  directory.
- With all network denied, `mix test` fails at start: `Mix.Sync.PubSub`
  "failed to open a TCP socket ... reason: :eperm". Allowing only localhost
  bind and inbound fixes it; `MIX_OS_CONCURRENCY_LOCK` is not needed.
- Under those rules a process can listen on localhost but cannot connect to
  its own listener (`Operation not permitted`), while the same connection
  succeeds unsandboxed.
- Seatbelt matches resolved paths: a temporary directory given as
  `/var/folders/...` is refused for writes until resolved to `/private/var/...`.

### Limits

- macOS only; other platforms cannot run real gates at all.
- Gates whose tests need the network, a localhost service, or a client
  connection to a server they start themselves fail (recorded as failed, with
  their output).
- A toolchain installed under the home directory makes `mix`/`python3` gates
  unavailable; only the gate's own executable is checked, not what it loads
  (for example `elixir`/`erl` found by `mix`).
- File metadata (existence, size, times) under the home directory remains
  readable; contents and directory listings are not.
- Mach/XPC services are not restricted by the profile (UNVERIFIED what a gate
  could reach through them, for example Keychain items without access
  control).
- The gate's temporary directory under the system temporary directory is not
  removed after the gate; the OS purges it.
- Shoestring's own `git` checks around the gate (`rev-parse`, `status`) run
  unsandboxed, as before. REPO-INSPECTION: they read Git configuration from
  the private store, which neither the Elf nor the gate can write.
- "Unavailable" is a reason inside the existing `gate_failed` event with
  `needs_user`, not a separate event type; work package A owns the versioned
  gate result shape.
- Not done in this package: manual `/runs/new` runs remain unsandboxed, and
  sandboxed Claude Elves still inherit the service environment.
- The optional live probe (an Elf asked to read home and reach a public host)
  was not run; it needs separate authorization and a budget.
