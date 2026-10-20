# Linux acceptance-gate sandbox: deferred

VERIFIED (human decision, 2026-10-19): the user explicitly deferred Linux
sandbox implementation and asked to record the decision before proceeding.
This work is not required for iteration 8 acceptance. Iteration 8's real
acceptance gates remain macOS-only.

## Deferred scope

Implement and verify a Linux backend for Shoestring's acceptance-gate
confinement. Bubblewrap is a candidate mechanism, not an implemented or
approved configuration. The implementation choice remains open.

REPO-INSPECTION: `Shoestring.Cobbler.GateSandbox` currently requires macOS
and `sandbox-exec`. Linux reports `no_sandbox_mechanism`, making the gate
unavailable. There is no unsandboxed fallback. This deferral does not relax
that behavior or establish Linux verification.

## When to resume

Resume when Linux deployment is requested or the user explicitly prioritizes
Linux support. No delivery date or later milestone is assigned.

The future implementation must be verified on Linux for:

- Toolchain reads and writes inside the worktree and temporary directory.
- Denied writes to the source checkout, protected Git storage and other host
  paths; denied reads of private home-directory files.
- Denied outbound network connections and a restricted gate environment.
- Timeout, output cap and owned process-group termination behavior.
- Fail-closed handling when the sandbox is absent or cannot enforce policy.
- Recorded backend/profile identity and real passing and refused commands.

UNVERIFIED: the Linux backend and these checks have not been implemented
or run. Other iteration 8 acceptance limits retain their existing status.
