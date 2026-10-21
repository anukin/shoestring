# Iteration 9: interactive terminal evidence

Implementation passes automated and fixture verification. Authenticated Claude
and Codex smoke responses were verified in Firefox on 2026-10-20; iteration 9
acceptance is complete on the supported macOS arm64 target.

## Scope and instructions

- VERIFIED: the user authorized implementation directly on `main`, overriding
  the standing worktree/source-checkout restriction. The baseline is `195e9ee`.
- VERIFIED: the user authorized two vendor smoke sessions: one Claude and one
  Codex, one initial tool-free prompt each, 120 seconds each, no retries. Both
  launch allowances were used. This is a session budget, not evidence of billed
  inference counts.
- REPO-INSPECTION: the iteration 9 terminal brief supersedes the older
  configuration-only product scope for this run subview. Existing navigation,
  DESIGN.md and its sidecar are preserved.
- Fixture identifiers are generated UUIDs belonging to synthetic local runs.
  Raw local logs, screenshots, state paths and provider output remain outside
  this committed evidence. No captured provider identifiers are substituted or
  published. The checked-in fixture contains no provider data.

## Support and build

VERIFIED: tested on macOS arm64 with rustc 1.98.0, cargo 1.98.0, Elixir 1.19.5
and OTP 28.3.1. The helper deliberately refuses other targets. Linux support
and the separate Linux gate sandbox remain deferred; there is no unsandboxed
fallback. Other architectures are UNVERIFIED and unsupported.

REPO-INSPECTION: `portable-pty` is locked to 0.9.0. Maintained-library evaluation
used its [official API/source](https://docs.rs/portable-pty/0.9.0/portable_pty/)
and [upstream PTY implementation](https://github.com/wezterm/wezterm/tree/main/pty).
`mix terminal.check` runs Rust formatting, Clippy with warnings denied, and
unit/integration tests, then installs a development helper.
`mix terminal.build` builds and packages the release helper; `assets.deploy`
includes that step. Rust is required at build time, not for running a packaged
helper. There is no implicit helper compilation during a run.

REPO-INSPECTION: xterm.js 6.0.0 and addon-fit 0.11.0 are vendored locally with
MIT licenses, npm SHA-512 integrity and per-file SHA-256 provenance. No CDN or
image/clipboard addons are loaded. Terminal rendering follows the
[xterm security guidance](https://xtermjs.org/docs/guides/security/).

## Protocol and process ownership

REPO-INSPECTION: protocol v1, helper 0.1.1, is a four-byte big-endian length
followed by JSON. Terminal bytes are base64 and remain binary end to end.
Hello/version negotiation precedes one spawn. Dispatch/request correlation is
separate from the canonical run ID. Unknown versions, wrong sessions, invalid
order, invalid sizes and malformed frames fail closed. Incompatible helper
versions produce an explicit terminal outcome.

| Boundary | Bound/behavior |
| --- | --- |
| Protocol JSON body | 65,536 bytes; reject oversized headers before body allocation |
| Helper queues | 262,144 bytes; stop PTY reads under output backpressure |
| Input | 8,192 raw bytes per message; reject the entire oversized input |
| Output frame | 4,096 raw bytes |
| Dimensions | 1–500 rows/columns |
| Browser attachment | 65,536 unacknowledged bytes, 128 pending records |
| Session | At most 8 attachments; 65,536-byte recent-output ring |
| xterm scrollback | 1,000 lines |
| Optional retained log | 1 MiB; overflow fails explicitly |

REPO-INSPECTION: the helper owns a PTY session/process group. A startup barrier
prevents execution of the approved target until a guardian is installed. The
guardian kills only that owned group if the helper dies. Explicit cancellation,
control closure and parent death terminate the owned group. There is no stale
PID sweep, reaper for unrelated processes, or automatic provider replacement.
The tested guarantee is the owned process group; deliberately escaping that
group is not a general containment guarantee.

VERIFIED: Rust tests exercise all 256 byte values, Unicode/bracketed paste,
resize, Ctrl-C, normal exit, helper SIGKILL, control EOF, output flood and slow
consumer behavior. A forked child that ignores TERM/HUP is removed with its
owned group. Kernel process-exit notifications are used instead of sleeps.

## Canonical state, retention and ownership

REPO-INSPECTION: a temporary supervised Elixir Session owns each Port. It is not
automatically restarted. The existing Elf records terminal checkpoints and
run outcomes. A normal TUI exit is `interrupted`, never task acceptance.
Helper loss is a transport failure. Startup recovery completes before durable
dispatch starts, preserves any existing exit fact, records an interrupted
ownership fact and failed checkpoint, and never resumes the provider.

REPO-INSPECTION: canonical events are `terminal.session.started`,
`terminal.ownership.changed` and `terminal.session.exited`. They contain bounded
lifecycle fields and a hashed browser owner reference, never terminal prose.
Terminal output is not capacity, completion, review or safe-boundary evidence.

REPO-INSPECTION: input ownership is serialized by the Session. Agent sends
fence human input; takeover requested during an agent batch waits for an
explicit trusted controller boundary. Both send paths are fenced while pending.
A quiet screen or terminal text cannot create that boundary. This governs
input injection, not the provider's internal model/tool activity. Detach retains
human ownership. The owning browser explicitly reclaims and releases it; other
attachments cannot type, signal or resize it. Termination is independent of
input ownership.

REPO-INSPECTION: retention defaults to disabled. Configure
`config :shoestring, :terminal_log_retention, :redacted` to retain a bounded
diagnostic artifact, redacted after collection to avoid chunk-boundary leaks.
Invalid UTF-8 is withheld. Artifact failure and overflow are explicit errors;
bytes are not silently discarded as a successful retained log. Arbitrary
terminal bytes make perfect redaction impossible. Vendor CLI persistence is
separate from Shoestring retention; interactive Claude does not support the
print-only `--no-session-persistence` flag. Export/deletion controls remain a
later feature.

## Browser boundary and manual launch

REPO-INSPECTION: loopback browser sessions receive a random cookie identity.
Signed, expiring socket and run-scoped capabilities bind that identity to an
existing interactive run. Socket CSRF/origin and loopback checks remain active.
Joining cannot spawn a process. Messages cannot supply executables, arguments,
directories or environment. Input/control messages are size/rate bounded;
output credit is acknowledged after xterm consumes it. Slow consumers detach.
Channel/socket failure and request timeout expose read-only reattachment;
unconfirmed actions are never retried automatically. This is a local operator
boundary, not remote or enterprise multi-user authorization.

REPO-INSPECTION: `/runs/new` offers interactive Claude, Codex and a fixture.
All three use private per-run Git storage and the existing manual admission,
claim, lease and dispatch path. Browser attachment alone cannot start one.
Claude retains its private-root sandbox and customization restrictions, using
interactive permission prompts. Codex uses workspace-write/on-request.
Headless providers and Fake keep their existing launch paths.

## Verification record

VERIFIED: focused terminal/Channel/LiveView/recovery/manual-run suite:
30 tests, 0 failures, seed 430282. A later focused selection including helper
compatibility and launch-profile checks: 29 tests, 0 failures, seed 39143.
Selections differ; these are not full-gate counts. UI reviewer verification:
`node --test test/ui_terminal.test.js < /dev/null`: 6 tests, 6 passed, 0 failed.

VERIFIED: the two-VM restart probe first halts its own running fixture VM with
exit 37, without application shutdown. The second VM opens that same fresh
test state and exits 0 after verifying failed status, exactly one checkpoint,
interrupted retained human ownership and no phantom session. Driver:
`tools/terminal_restart_probe.exs`, stages `crash` and `recover`, sharing a fresh
`SHOESTRING_TEST_STATE_DIR`, each bounded to 60 seconds. No provider calls.

VERIFIED in Firefox with the real fixture TUI: color/alternate-screen rendering,
Unicode paste (`hello λ 世界`), Ctrl-C response, non-terminating detach,
reattach/reclaim/release, resize from 30×125 to 24×39 at a 390×844 viewport,
and explicit termination. Desktop/mobile controls fit the incumbent shell.
The fixture echoes raw carriage returns, so its text can overwrite earlier
characters; it is not a line-oriented shell.

VERIFIED: independent read-only UI review found a Channel-only closure recovery
bug and confusing detach copy. Both were corrected and the reviewer scored
both findings resolved. Scope was those findings, not a new whole-surface
approval. The documentation comparison preserved the global design files.
Detector returned four nonblocking advisories for terminal-local radius and
accent colors. Assistive technology was not tested with a human screen reader.

VERIFIED: Claude Code 2.1.304 rendered and accepted the specifically approved
fixture trust action, then displayed the exact smoke prompt and `Login expired`.
The session was explicitly terminated without retry. Codex 0.163.0 rendered its
folder-trust screen, then reached its 120-second session bound while approval
was pending. No trust bypass or retry was attempted. Vendor model responses
were UNVERIFIED at that point; neither original attempt produced `TERMINAL_OK`.
The successful final continuation is recorded below.

UNVERIFIED: vendor-specific tools, commits or permission workflows beyond the
fixture trust/startup and tool-free response checks. Do not treat fixture
coverage or a tool-free response as proof of those broader paths. Further live
attempts require a new named budget.

VERIFIED: the first completed `timeout 590 mix precommit < /dev/null` was red:
4 doctests, 2330 tests, 1 failure, 1 skipped, 6 excluded, seed 913840; 549.9
seconds. Its failure was the exact browser script list, which was updated to
the new dependency contract without relaxing its equality assertion. Rust
passed 4 unit and 4 integration tests; JavaScript passed 52/52 and 14/14.
An earlier gate stopped at formatting before running tests.

VERIFIED: final `timeout 590 mix precommit < /dev/null` exited 0:
4 doctests, 2330 tests, 0 failures, 1 skipped, 6 excluded, seed 314001; 544.9
seconds (12.3 async, 532.6 sync). Rust formatting/Clippy passed, with 4 unit and
4 integration tests passing. JavaScript passed 52/52 and 14/14, 0 failures.
This run includes the final startup ordering and exact asset-contract changes.
`MIX_ENV=test timeout 120 mix terminal.build < /dev/null` also exited 0 and
installed the optimized helper. A complete distributable release was not built.
VERIFIED: `timeout 120 cargo build --release --locked --manifest-path
native/terminal_helper/Cargo.toml < /dev/null` completed successfully in 5.13
seconds. A bounded Python protocol smoke against that optimized binary verified
v1 negotiation, `/usr/bin/true` launch in a fresh fixture directory, exactly one
exit-0 outcome, helper exit 0 and empty stderr.
Earlier failures were real implementation/test-contract failures, not claimed
intermittency: missing helper flush, incorrect dispatch/run identity, fixture
input before raw-mode readiness, and the browser asset list predating xterm.
The new feature tests were not verified as regression locks against `195e9ee`;
that commit lacks the feature. No missing-module failure is claimed as proof.

## Local demo

Run `mix terminal.check`, then:

```sh
MIX_ENV=test timeout 900 mix run --no-start tools/terminal_fixture_demo.exs < /dev/null
```

The driver prints a loopback URL and records local fixture metadata under
`tmp/`. It retains scratch repositories/state. The internal fixture ceiling is
14 minutes; explicit Terminate run ends it earlier. Vendor mode additionally
requires explicit user authorization and its named session budget; its driver
ceiling is 120 seconds. Never invoke vendor mode from automated tests.

The local demo and automated fixtures are supplemented by the authenticated
vendor verification in the final acceptance continuation below.

## Authentication continuation

VERIFIED: after the user refreshed Claude sign-in and explicitly authorized a
read-only diagnostic, unrestricted `claude auth status` recognized the login,
but the terminal's environment allowlist did not. Adding only `USER` restored
login recognition. Tested `LOGNAME`, `SECURITYSESSIONID` and
`__CF_USER_TEXT_ENCODING` individually did not. Only variable names, exit codes
and login booleans were displayed; credential values and account details were
not printed or saved. No inference calls were made by this diagnostic.

UNVERIFIED: optional `auth status --json` probes through the real PTY exited 0
but their TTY output did not parse as an authentication JSON object. Raw account
output was withheld, and these probes are not evidence of successful TUI
authentication. The positive login-recognition result above is from the plain
CLI status diagnostic, not a vendor model response.

The earlier logged-out conclusion from a filesystem-sandboxed status command
was too strong. The original TUI did display `Login expired`, but actual prior
credential expiry remains UNVERIFIED. The verified implementation defect was
the missing `USER` environment key.

REPO-INSPECTION: launch profiles and the Rust helper now allow `USER`; credential
environment variables remain excluded. Helper 0.1.1 is required so an old 0.1.0
binary is visibly rejected before spawn. Protocol version remains 1. Rebuild
development binaries with `mix terminal.check` and packaged binaries with
`mix terminal.build`.

VERIFIED against unchanged implementation files at `22d3d08`: the new launch
test failed with `profile.env["USER"] == nil` (2 tests, 1 failure, seed 698058).
The new Rust integration test failed with `invalid_spawn` instead of `spawned`
when passing `USER` (1 test, 1 failure, 4 filtered). These are behavioral
regression failures, not missing-module or signature failures. After the fix,
Rust formatting/Clippy and all 4 unit + 5 integration tests passed; the focused
launch/compatibility suite passed 4 tests, 0 failures, seed 342616. The tests
also assert unrelated inherited values stay absent while user identity remains
available, across Claude, Codex and fixture profiles.

VERIFIED: the user authorized a fresh ceiling of one Claude session and one
Codex session, one exact tool-free `TERMINAL_OK` prompt each, at most five
minutes per session including trust prompts, no retries. The Claude attempt
reached its folder-trust prompt and hit its bound while action-time confirmation
was pending. It produced no model response and was not retried. The Codex
attempt also rendered its folder-trust prompt and hit its five-minute bound
while action-time confirmation was pending. No model response was verified and
no retry was made. Both new session allowances are consumed. The original
fixture-specific trust approval did not apply to these newly allocated paths.
VERIFIED: `timeout 590 mix precommit < /dev/null` exited 0 for this fix:
4 doctests, 2332 tests, 0 failures, 1 skipped, 6 excluded, seed 738591;
549.1 seconds (11.8 async, 537.2 sync). Rust formatting/Clippy passed with
4 unit + 5 integration tests, 0 failures. JavaScript passed 52/52 and 14/14.
The earlier 2330-test result belongs to `22d3d08`, not this fix.

VERIFIED: the optimized 0.1.1 helper negotiated protocol v1, accepted a
synthetic `USER`, spawned `/usr/bin/true`, reported exactly one exit 0, then
exited 0 with empty stderr. `MIX_ENV=test timeout 120 mix terminal.build
< /dev/null` exited 0 and packaged that helper. At this stage, authenticated
vendor response acceptance remained open; the fix did not convert the bounded trust-prompt
attempts into successful model verification.

## Final acceptance continuation — 2026-10-20

VERIFIED: the user explicitly requested rerunning both sessions and confirmed
the remaining actions. This renewed the same named ceiling: one Claude session
and one Codex session, one exact tool-free prompt each, five minutes per
session, no retries. No planner or reviewer calls were authorized or used.
The initial restricted launch failed before application startup because Mix
could not open its local PubSub socket; it launched no provider. The two actual
sessions then ran with the required local-socket permission.

VERIFIED in Firefox: Claude Code 2.1.304 and Codex 0.163.0 each rendered the
synthetic fixture trust prompt. The user-confirmed trust actions applied only
to their respective fresh fixture repositories, containing a harmless README.
Both then displayed the submitted prompt and a separate assistant response
`TERMINAL_OK`. Claude displayed completion after 1 second; Codex after 3 seconds.
These are displayed response durations, not measured end-to-end session times.
No tool request or execution was visible in either session. Sandbox and
customization restrictions were unchanged; Shoestring terminal-log retention
remained disabled. Raw vendor output, local paths and generated identifiers
are not published in this evidence.

VERIFIED: each session was explicitly ended using Terminate run after its
response. Firefox showed Session ended; each driver reported a cancelled
terminal outcome and exited 0, before its five-minute bound. Both allowances
are consumed, with no retries. A displayed response verifies authenticated TUI
operation, not a billed inference count or broader vendor tool workflows.

VERIFIED: the vendor smoke requirement is now satisfied alongside the automated
and fixture checks above. Iteration 9 is accepted for macOS arm64. Linux and
other architectures remain unsupported/deferred; full distribution packaging
belongs to iteration 10. Human screen-reader testing and broader vendor tool/
commit workflows remain UNVERIFIED, without being promoted by these smokes.

VERIFIED: final acceptance gate `timeout 590 mix precommit < /dev/null` exited
0: 4 doctests, 2332 tests, 0 failures, 1 skipped, 6 excluded; seed 538665.
ExUnit completed in 560.9 seconds (12.2 async, 548.7 sync). Rust formatting and
Clippy passed, with 4 unit and 5 integration tests passing. JavaScript passed
52/52 and 14/14, with 0 failures. SQLite connection warnings appeared, but the
completed test run had no failures. There was one full-gate run in this
continuation, with no retry. This continuation changes evidence only.
