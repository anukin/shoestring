# The Cobbler planner boundary

**Status:** implemented for iteration 6, work package B. The approval UI
(package C), the sequential executor (package D), and amendment/replan
orchestration (package E) are **not** in this slice.

Model-assisted decomposition proposes plans; deterministic Cobbler code
retains authority over lifecycle, quotas, dependencies, worktrees, and
dispatch. Every planning inference is admitted through the existing
admission evaluation before it is invoked, bounded to at most two
invocations per request, validated through the package-A plan contract
before anything persists, and recorded as durable attributable trajectory
facts. The planner cannot dispatch, change reserves, approve itself,
select destructive integration, or bypass worktree policy.

## Modules

| Module | Role |
| --- | --- |
| `Shoestring.Cobbler.Planner` | the boundary: claim, admit, invoke (at most twice), validate, settle, replay, rebuild |
| `Shoestring.Cobbler.PlannerAdapter` | the behaviour every planner adapter implements |
| `Shoestring.Cobbler.PlannerFixture` | the deterministic fixture planner (default; offline, scripted) |
| `Shoestring.Cobbler.PlannerHttp` | the configured OpenAI-compatible production adapter boundary |
| `Shoestring.Cobbler.PlannerPrompt` | bounded prompt/projection built from the durable goal contract |
| `Shoestring.Cobbler.PlannerSafety` | rejection of unsafe directives before contract validation |
| `Shoestring.Cobbler.PlannerRequestRecord` | the durable row: idempotency token plus attempt budget |
| `Shoestring.Cobbler` | the facade: `request_plan/3`, `cancel_plan_request/4`, `planner_request/3`, `list_planner_requests/2`, `rebuild_planner/2` |

Every one of these is reachable without a LiveView. The eventual approval
UI is a view over this domain, not the place the domain lives.

## Request lifecycle

1. **Validate.** Request inputs (a `human:` initiator, goal statement,
   resolved base revision, bounded constraints, trusted acceptance gates,
   explicit context references) are validated before anything is claimed.
   Planner attribution comes from the configured adapter, never from the
   caller, so a request cannot spoof which planner answered it.
2. **Claim.** The request row is inserted (`in_progress`) with a
   `cobbler.planner.requested` event in one immediate write transaction.
   The `(goal_id, request_id)` unique index is the idempotency token: the
   same id with the same input digest replays the stored outcome with zero
   new invocations; the same id with a different digest is a conflict.
   Fresh ids that would silently branch existing revision history are
   refused by the lineage check before any claim, admission, or
   invocation.
3. **Admit every invocation.** Each of the at-most-two invocations is
   evaluated through `AdmissionEvaluation` under the `plan_decomposition`
   capability against the planner candidate and an explicit capacity
   snapshot, and each evaluation persists an `admission.decided` event.
   Only `:admit` invokes. A blocked planner settles to the queue/manual
   path with zero invocations — reserves are never bypassed.
4. **Invoke, at most twice.** One initial attempt plus at most one
   bounded repair after invalid schema/contract output. Transport
   failures, refusals, and unsafe proposals are terminal: never repaired,
   never retried. Repair errors travel back to the model as bounded
   field-level summaries, never as raw output.
5. **Validate before persisting.** Output passes `PlannerSafety` (no
   reserve, lifecycle, dispatch, approval, destructive-integration,
   worktree-override, or command-bypass directives) and then the full
   `PlanContract` validation, including planner-attribution echo. Only a
   valid contract reaches `Plans.propose/3`, authored by the human
   requester. Invalid output never creates a revision, and every persisted
   proposal stays `proposed`: the planner cannot approve.
6. **Settle.** Success, failure, repair exhaustion, quota blocking, and
   explicit cancellation each settle the row and append a
   `cobbler.planner.resolved` event with a closed outcome/reason pair.
   Terminal rows never move; retry, replay, restart, and concurrent
   duplicates converge on the stored outcome instead of duplicating
   invocations or resetting the attempt budget.

## Configuration

Application config supplies the defaults; per-call opts override them:

```
config :shoestring, :planner,
  adapter: Shoestring.Cobbler.PlannerFixture,  # default: offline, spends nothing
  model: "fixture-1",
  provider_id: "planner",
  candidate: %{scope: "account:planner", ...},
  policy: nil                                  # nil selects the default admission policy
```

The production adapter reads its own keys (`:endpoint`, `:model`,
`:api_key` or `:api_key_env`, `:timeout_ms`, `:max_body`) from the same
namespace or per-call opts. A missing endpoint or credential resolves to
`:planner_not_configured` before any admission, so an unconfigured
planner consumes no quota. Select the production adapter explicitly:

```
config :shoestring, :planner,
  adapter: Shoestring.Cobbler.PlannerHttp,
  endpoint: "https://planner.example.invalid/v1/chat/completions",
  model: "planner-small",
  api_key_env: "SHOESTRING_PLANNER_API_KEY"
```

The credential travels in the request header only. It is never logged,
never persisted, and never echoed in an error.

## Accounting path

Planner inference is admitted work, accounted in existing quota units:
one `admission.decided` event per evaluation plus the durable two-attempt
budget on the request row. Execution leases are deliberately not used —
leases bound Elf runs, and planning never runs an Elf. The admission gate
plus the invocation budget is the reservation; the settled row plus the
resolved event is the release. Cancellation settles the accounting; a
late settlement converges on the cancelled row rather than overwriting
it, and an in-flight invocation is never interrupted merely for
staleness.

## Structured outcomes

Valid output returns `{:ok, %{request:, revision:, outcome:, events:}}`
with `outcome` `:recorded` or `:replayed`. Anything else is a structured
error the approval UI can render:

| Error | Meaning |
| --- | --- |
| `{:invalid_planner_request, field, message}` | request inputs refused before claim |
| `{:non_human_identity, detail}` | initiator or confirmer is not a `human:` identity |
| `:planner_not_configured` | no usable planner; nothing admitted |
| `{:planner_request_conflict, detail}` | same id, different content |
| `{:planner_request_in_progress, detail}` | same id mid-flight |
| `{:planner_quota_blocked, detail}` | no planning capacity; queue/manual path, zero invocations |
| `{:planner_confirmation_required, detail}` | degraded capacity; needs an attributable human confirmation |
| `{:planner_manual_required, detail}` | repair exhausted; carries validation errors for user edit |
| `{:planner_transport_error, detail}` | the planner was never reached; terminal |
| `{:planner_refused, detail}` | the model declined; terminal and distinct from transport |
| `{:planner_unsafe_proposal, detail}` | unsafe directive; terminal, no repair, no revision |

Terminal request states are `proposed`, `manual_required`, `failed`,
and `cancelled`; every one of them is a durable attributable fact with
its settlement evidence, replayable after restart via `rebuild_planner/2`.

## Limitations

- The production transport uses OTP's built-in `:httpc`, not `Req`: no
  new dependency was authorized for this slice, and `Req` is not in the
  dependency set. The repository prefers `Req` where available; this
  boundary documents the stdlib choice rather than adding a dependency.
- The live transport path is implemented but unvalidated against a real
  endpoint — validating it would spend provider quota, which this slice
  forbids. Its pure surface (`configured/1`, `request_body/2`,
  `decode_response/1`) is covered hermetically; the wire path is covered
  by construction (bounded timeout, capped body, secret-free errors).
- Repair carries bounded field-level error summaries; deeply nested
  contract failures may need a human edit after the single repair.
- Dispatch, approval UI, and amendment orchestration remain later
  packages: proposals are inert until a human approves, and nothing here
  executes.
