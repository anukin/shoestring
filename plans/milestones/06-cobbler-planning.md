# Iteration 6: cobbler planning — single-chain lifecycle coverage (planned)

**Status:** proposed — planning only. This document adds **required planned work**;
it implements nothing. The test described below does **not** exist yet.

**Hard dependencies:** iteration 5 closeout merged by the human (see
`plans/milestones/05-quota-aware-mvp.md`, final-decision addendum 2026-09-29 UTC:
iteration 6 unlocks when the closeout PR passes independent review and is merged).

**Planning scope:** this file plans iteration-6 work. It changes no iteration-5
closure prose, which lives in `plans/milestones/05-quota-aware-mvp.md` and its
evidence records, and is left exactly as written.

> **File note:** this file is new in this change. No A–E packages existed in it
> to edit, so there is nothing here to preserve or reorder; the package below
> is lettered to avoid collision with any A–E packages defined elsewhere for
> this iteration.

## Why this package exists (carried coverage work)

The latest validation finding: existing lifecycle suites cover overlapping
pieces (admission, lease decline, checkpoint, wake, handoff, terminal
projection), but **no single test exercises the complete application flow**.
This package is **carried coverage work** — a known gap recorded now so
iteration 6 completes it. It is **not a new iteration-5 blocker**, it reopens
nothing in the iteration-5 closure, and **no claim is made that existing tests
already prove the whole chain**.

## Required outcomes (addition)

- Existing iteration-6 outcomes, if any, are unchanged.
- **Added:** one hermetic single-chain lifecycle end-to-end regression/coverage
  test that exercises the full flow below in one run (work package L1).

## Work package L1: single-chain lifecycle end-to-end test (PLANNED — not implemented)

A bounded hermetic regression/coverage test for the complete lifecycle of one
goal. Future-test acceptance — the test must do all of the following in a
single chain:

1. Enter through the product path: UI `/runs/new` or goal submission →
   durable admission/claim/dispatch worker → `ElfEffect` → a real supervised
   Elf leg A using `Shoestring.Harness.Fake` and trivial local commands.
2. Hit a scripted quota refusal at a safe boundary → deterministic
   checkpoint/suspension.
3. Restart the owning supervision tree (a real restart — **not** merely calling
   a reconciler twice) → persisted wake with a fresh capacity check.
4. Continue via the same-provider resume **or** the production handoff branch →
   supervised Elf leg B to a terminal outcome.
5. Assert persisted lease/run/goal rows and the LiveView outcome **without**
   test-side manual projection and **without** synthetic lifecycle/terminal
   event appends.
6. Require no duplicate wake, dispatch, or Elf, and projection-only handoff
   privacy when the handoff branch is exercised.
7. Tools must not be interrupted by lease expiry; normally completed work
   remains completed with no wake and no duplicate work (add a twin case as
   necessary — do **not** force the completed path into suspension to reuse it).

## Required evals (addition)

- Existing required evals, if any, are unchanged.
- **Added eval row:** `Lifecycle single-chain` — full flow above, hermetic;
  required result is terminal leg B with persisted rows matching the LiveView
  outcome and zero duplicates.

## Acceptance gate (addition)

- Existing gate items are unchanged.
- **Added:** the L1 chain passes hermetically, synchronized without sleeps,
  under the full gate (`mix precommit`), with precise limits and committed
  evidence. No product-advantage result from any ablation is required for this
  package.

## Limits (binding on the future implementation)

- Hermetic only: `Shoestring.Harness.Fake` and trivial local commands. Never a
  provider CLI, never the network.
- Synchronized without sleeps.
- `mix precommit` gate with exact counts; precise limits/evidence per the
  repository contract.
- No unrelated sandbox/CI fix is required by this docs change.
