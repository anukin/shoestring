# Adapter Contract Suite

`Shoestring.Harness.ContractSuite` is the shared, reusable test suite every
production harness adapter must pass. Adopting it is a one-`use` operation in
your adapter's test module.

## Quick start

```elixir
defmodule MyAdapter.ContractTest do
  use Shoestring.Harness.ContractSuite,
    adapter: MyAdapter,
    config: %{}
end
```

Running `mix test` on this module generates and executes the seven contract
tests described below.

## What the adapter must implement

Your module must satisfy `Shoestring.Harness.Adapter` behaviour:

| Callback | Arity | Required? |
|---|---|---|
| `identity/0` | 0 | always |
| `capabilities/0` | 0 | always |
| `probe/1` | 1 | always |
| `start/2` | 2 | always |
| `status/2` | 2 | always |
| `stream/2` | 2 | always |
| `cancel/2` | 2 | only when `:cancel` declared |
| `resume/3` | 3 | only when `:resume` declared |
| `send/3` | 3 | only when `:send` declared |

`identity/0` must return `%Shoestring.Harness.Identity{}` with all required
fields. `capabilities/0` must return a `MapSet` containing only atoms from
`[:resume, :send, :cancel, :interactive]`.

### Simulate mode for test scenarios

The suite drives scenario coverage through the `opts` map passed to each
callback. Your adapter should honour these keys when present:

| `opts[:simulate]` | Meaning |
|---|---|
| `:quota_refused` | `probe/1` returns `{:error, %Error{category: :quota_refused}}` |
| `:missing_config` | `probe/1` returns an error or unknown/degraded snapshot |
| `:incompatible` | `probe/1` returns a snapshot with `:degraded` or `:incompatible` compatibility |
| `:failure` | `start/2` returns `{:error, %Error{}}` |
| `:already_cancelled` | `cancel/2` still returns `{:ok, :cancelled}` (idempotency) |

Production adapters may map these keys to fixture branches rather than live
calls.

## Capability declaration and test skipping

The suite reads `adapter.capabilities()` at **macro expansion time**. Any test
for a capability that is not in the adapter's declared set is tagged
`skip: "<reason>"` — it appears in the test output as skipped, never as a
silent pass.

```elixir
# If :resume is absent from capabilities(), this test is automatically skipped:
test "capability-appropriate resume behavior" do ...
```

An adapter that supports a capability but omits it from `capabilities/0` will
skip the test and potentially silently violate the contract in production.
Declare every capability you implement.

## The seven contract areas

| # | Test name | What it checks |
|---|---|---|
| 1 | `identity and compatibility reporting` | `identity/0` returns `%Identity{}` with valid fields; `capabilities/0` returns `MapSet` of recognized atoms |
| 2 | `normalized start, stream, completion, failure, and cancellation` | `start/2` → `{:ok, %RunIdentity{}}`; stream emits `%HarnessEvent{}` in ordinal order; result event present; failure returns typed `%Error{}`; `cancel/2` returns `{:ok, :cancelled}` when declared |
| 3 | `capability-appropriate resume behavior` | `resume/3` → `{:ok, %RunIdentity{}}` when `:resume` declared; **explicitly skipped** otherwise |
| 4 | `quota refusal classification` | `probe/1` with `:quota_refused` simulation → `{:error, %Error{category: :quota_refused}}` |
| 5 | `missing/malformed capacity behavior` | `probe/1` with `:missing_config` or `:incompatible` → error or snapshot with `:degraded`/`:incompatible` compatibility; never `:compatible` for an incompatible version |
| 6 | `secret-free persistence and diagnostics` | No secret patterns in `Identity`, `RunIdentity`, or `HarnessEvent.extensions` fields |
| 7 | `terminal idempotency and cleanup` | Calling `cancel/2` a second time returns `{:ok, :cancelled}` or `{:error, %Error{}}`; never raises |

## Using assertion functions directly

Every `assert_*` function is public and callable from ad-hoc test blocks.
This lets you prove a **non-conforming** adapter fails the suite:

```elixir
test "non-conforming adapter fails identity contract" do
  assert_raise ExUnit.AssertionError, fn ->
    Shoestring.Harness.ContractSuite.assert_identity(BrokenAdapter)
  end
end
```

## Vendor adapter compatibility policy

Per the project policy, adapters must:

- Validate required semantic fields at the adapter boundary.
- Treat additive unknown fields as permitted.
- Mark a missing or incompatible required field as `:schema_incompatible`.
- Never emit `compatibility_state: :compatible` or `capacity_state: :known`
  for an untested or incompatible vendor version — use `:degraded`,
  `:incompatible`, or `:unknown`.

## Transport-specific tests

The contract suite covers the normalized, vendor-neutral surface. Each
production adapter is expected to add transport-specific tests (fixture
parsing, CLI flag handling, real provider event shapes) alongside the suite.
The suite and transport tests together constitute the full acceptance
requirement.
