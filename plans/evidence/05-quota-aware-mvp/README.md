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
- `cobbler-foundation.md`: Architectural contract and verification evidence for durable Cobbler commands, caller-supplied goal-scoped IDs, idempotent replay, lifecycle state machine (`needs_user` recovery vs terminal states), SQLite-enforced exclusive global MVP task claim, admission reference validation, and authoritative trajectory replay.
