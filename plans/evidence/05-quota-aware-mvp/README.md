# Milestone 05: Quota-Aware MVP Evidence and Conventions

This directory houses the evidence writeups, deterministic admission specifications, and architectural evaluations for Milestone 05 (Quota-Aware MVP).

---

## Fixture and Redaction Conventions

Consistent with repository and global standing agent contracts (`~/.config/agents/AGENTS.md` and repository `AGENTS.md`):

1. **Format-Valid Synthetic Identifiers**:
   - RFC 9562 UUIDv7 synthetic format: `01950000-0000-7000-8000-000000000001`
   - Preserves variant nibble (`8`, `9`, `a`, `b`) and version nibble (`7` for v7, `4` for v4).
2. **Zero Credentials or Secrets**:
   - No API keys, session tokens, or credentials are committed.
3. **Zero Real Machine Paths**:
   - Generic root placeholders (`$WORKSPACE` or relative paths) are used exclusively.
4. **No Hidden Model Reasoning**:
   - Reasoning tokens and private scratchpads are never persisted.
5. **Factual Claim Labels**:
   - `VERIFIED`: Proven by committed code, test suite execution, or exact command outputs.
   - `REPO-INSPECTION`: Derived from direct inspection of committed repository files.
   - `SCHEMA-ONLY`: Derived from contract schemas without runtime integration.
   - `UNVERIFIED`: Not verified in this slice.

---

## Directory Inventory

- `admission-policy.md`: Architectural specification and evaluation contract for deterministic versioned admission decisions (`admission.decided` v1), operational reserve thresholds, manual confirmation boundaries, delayed recheck policy, and SQLite concurrency guarantees.
- `cobbler-commands.md`: Durable goal-scoped command ids with identical-replay / conflicting-reuse semantics, validated command state machine with recoverable `needs_user`, atomic intent/transition/result persistence, trajectory rebuild, SQLite-enforced exclusive global MVP task claim, and the honest limitations of this slice (execution disabled; direct run paths unprotected).
- `response-attribution.md`: Strict command-response attribution follow-up — fail-closed `confirmed_by` on every new response, the `system:` prefix convention, digest-covered persistence to row + `cobbler.command.resolved` v1 (additive), no-backfill rationale, and the fail-closed matrix.
- `execution-entry.md`: Loop-closure I1 — claim+grant dispatches only through the durable dispatch pipeline (`enqueue_for_run`: dispatch record + Oban job, never direct `start_run`), `/runs/new` as a Cobbler command submitter with a logged expert/test hatch, the production entrypoint inventory, and the lock-vs-documentation ledger.
- `terminal-checkpoint.md`: Loop-closure I3 — terminal-path recovery checkpoints with real repository evidence (new collector module + pre-commit hook in the Elf terminal region), the P1–P5 ledger with deviations, collection inventory, and the lock-vs-documentation ledger.
- `worker-effect.md`: Loop-closure W2 — production dispatch-worker effect (`Shoestring.Harness.Dispatch.ElfEffect` + prod wiring in `config/runtime.exs`): worker delivery starts the Elf with the exact start/outcome mapping, the P1–P5 ledger with deviations, and the lock-vs-documentation ledger.
- `wakeup-continuation.md`: Second-round finding 3 — admitted wakes dispatch leased same-provider continuations (projected or fallback-written recovery context, run-provider identity, per-run lease grant, claim gate, retry convergence), with the fail-on-base ledger.
