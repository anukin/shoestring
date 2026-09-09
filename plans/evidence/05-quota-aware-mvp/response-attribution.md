# Command-Response Attribution, Strict (Milestone 05 Follow-up)

- **Status**: Follow-up slice stacked on `ecd937b` (main: milestone 05 + elf-flake fix).
- **Scope**: Persist `confirmed_by` (+ the confirmed intent where carried) for
  every NEW command response, validated fail-closed in the domain. No
  backfill, no migration of existing data, no other web changes.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).
- **Fixture conventions**: synthetic UUIDv7 identifiers
  (`01950000-0000-7000-8000-000000000001`), zero credentials, zero real
  machine paths, no hidden reasoning, labeled claims only.

---

## 1. The Gap (`VERIFIED` by the T5 UI slice)

`plans/evidence/05-quota-aware-mvp/cobbler-ui.md` §3 records the limit
honestly: the confirm/respond form collects `confirmed_by` plus an intent
confirmation and enforces both at the UI boundary, but
`Cobbler.respond_command/4` validates only `%{"resolution" => ...}`. The
persisted command row and the `cobbler.command.resolved` event answer *what*
was decided, never *who* confirmed a `needs_user` resolution. The admission
side already persists attributable confirmation
(`AdmissionEvaluation.validate_confirmation/2`, `confirmed_by` +
`confirmed_invalid_*` reason codes); this slice closes the same gap for
command responses.

## 2. Response Path Trace (`REPO-INSPECTION` with file:line)

| Step | Location | Role |
| :--- | :--- | :--- |
| UI form | `lib/shoestring_web/live/cobbler_goal_live.html.heex:320` (`#cobbler-confirm-form-<id>`, `confirmed_by` + `intent` inputs) | Collects identity + intent; already required/non-blank at the boundary. |
| UI delegation | `lib/shoestring_web/live/cobbler_goal_live.ex:218` (`do_respond/2`) | Boundary checks (`require_attribution/1`, `require_intent_match/2`), then forwards `%{"resolution", "confirmed_by", "intent"}` to `Cobbler.respond_command/4`. |
| Facade | `lib/shoestring/cobbler.ex:104` (`respond_command/4`) | Pure delegation to `Commands.respond/4`; inherits the domain gate, adds none of its own. |
| Domain gate | `lib/shoestring/cobbler/commands.ex:368` (`respond/4`) → `validate_response/1` | **P1 enforcement point**: `confirmed_by` required non-blank BEFORE any read of command state or any write (fail-closed). |
| Persistence | `lib/shoestring/cobbler/commands.ex:424` (`record_response/7`) → `CommandRecord.response_changeset/7` (`lib/shoestring/cobbler/command_record.ex:88`) + `cobbler.command.resolved` append | Row (`response`, `response_digest`, `confirmed_by`, `confirmed_intent`) and canonical event commit in one immediate write transaction or not at all. |
| Registry | `lib/shoestring/trajectory/event_registry.ex:398` (`cobbler.command.resolved` v1) | Optional `confirmed_by` / `confirmed_intent` top-level mirrors (purely additive; version stays 1). |
| Rebuild | `lib/shoestring/cobbler/commands.ex:639` (`fold_event` resolved) + `:708` (`divergences/3`) | Rebuilds attribution (top-level preferred, response-map fallback, nil for legacy) and compares it for divergence. |
| Projector | `lib/shoestring/trajectory/projector.ex:187` (`project_event_from_storage/1`) | `cobbler.*` events pass through untouched (goal/task projection is unaffected); version stays 1 — justified in §5. |

**Writer inventory** (`REPO-INSPECTION`, grep for `respond(`/`respond_command(`/`response_changeset(` across `lib/`):
`Commands.respond/4` is the SOLE persisting writer of command responses.
`Cobbler.respond_command/4` delegates to it; `CobblerGoalLive.do_respond/2`
is the only UI caller; `Dispatcher`, `Leases`, and wakeup/reconcile paths
only read command rows. No automated/system writer exists today, so P2 is a
documented convention for future callers, not a migrated call site. All
writers fall under P1 by construction (one gate).

## 3. Pinned Decisions P1–P4 (no deviations)

- **P1 STRICT**: every new response through `Commands.respond/4` (and hence
  every writer above) MUST carry non-blank `confirmed_by`. `nil`, missing,
  `""`, and whitespace-only are rejected fail-closed as
  `{:error, {:confirmation_invalid_responder, %{"reason" => "unattributed"}}}` —
  distinct from `response_conflict`, in the existing
  `confirmation_invalid_*` code family. No exceptions for callers.
- **P2 `system:` convention**: automated resolutions pass an explicit
  `system:`-prefixed identity. Prefix registry (convention, not a domain
  allow-list — the domain accepts any non-blank identity and never silently
  defaults one):

  | Identity | Meaning |
  | :--- | :--- |
  | `"system:wakeup"` | Wakeup-path automated resolution (no writer today; reserved). |
  | `"system:reconciler"` | Reconciler automated resolution (no writer today; reserved). |
  | `"system:<subsystem>"` | Any future automated caller names its subsystem after `system:`. |
  | anything else non-blank | A human operator identity (e.g. `"Ada Operator"` in tests). |

- **P3 no backfill**: `confirmed_by` / `confirmed_intent` are NULL-able
  columns with no default, no constraint, and no data migration. Old rows
  keep `nil`; old events omit the new keys and still validate (optional),
  replay, and rebuild. Only new writes are gated.
- **P4 pair semantics**: attribution rides INSIDE the digest-covered
  `response` map (`%{"resolution", "confirmed_by", optional "intent"}`), so
  `response_digest = Command.response_digest(response)` covers *who* as well
  as *what*. The row columns and the event top-level keys are queryable
  mirrors of the same values. Same resolution from a different identity is a
  different digest → `response_conflict`, never a silent replay.

## 4. Fail-Closed Matrix (`VERIFIED` by `response_attribution_test.exs`)

| Input | Result | Trace left |
| :--- | :--- | :--- |
| valid human identity (+ optional intent) | `{:ok, %{outcome: :recorded}}`; row + event + rebuild carry attribution | one `cobbler.command.resolved` event |
| explicit `system:<name>` identity | `{:ok, %{outcome: :recorded}}` (facade-level test) | same as above |
| `confirmed_by` missing / `nil` / `""` / whitespace | `{:error, {:confirmation_invalid_responder, %{"reason" => "unattributed"}}}` | ZERO rows/events appended; row stays `needs_user` with nil response + attribution |
| non-string or overlong (>200) intent | `{:error, {:confirmation_invalid_responder, %{"reason" => "invalid_intent"}}}` | same zero-trace refusal |
| unoffered `resolution` (with valid identity) | `{:error, {:invalid_response, options}}`, unchanged | none (pre-existing behavior, still green) |
| UI intent mismatch | error flash, unchanged | none (UI boundary, still green — the domain carries intent but does NOT match it) |
| same resolution, different identity on resolved row | `{:error, {:response_conflict, _}}` | none |

## 5. Backfill Refusal Rationale

Migrating old rows/events would rewrite canonical history: the
`response_digest` of a legacy response covers the unattributed map, so any
injected identity would either invalidate the stored digest (breaking replay
equality) or require recomputing digests (rewriting evidence). The honest
record is that pre-slice resolutions are unattributed: they stay `nil`,
rebuild consistently (§6), and the `nil` itself is the evidence that no one
is on record.

Projector version stays **1**: the registry change adds two *optional*
string keys to `cobbler.command.resolved` v1. Old payloads validate
unchanged, new payloads validate strictly, and `goal_task` projection never
consumes `cobbler.*` fields (passthrough at `projector.ex:187`), so no
upcaster, no version bump, and no replay halt.

## 6. Verification (`VERIFIED`)

- New: `test/shoestring/cobbler/response_attribution_test.exs` (7 tests:
  human accept + row/event/rebuild persistence; `system:` accept via the
  `Cobbler.respond_command/4` facade; nil/missing/blank rejection with exact
  reason and zero-trace assertions in both directions — attribution absent
  AND resolution still unrecorded; intent carried vs nil; cross-identity
  conflict; response/digest pair integrity; legacy nil-attribution rebuild
  with `consistent?` and empty divergences).
- Updated (strict-conformance, same assertions otherwise):
  `test/shoestring/cobbler/commands_test.exs` (all `respond/4` calls now
  pass `"confirmed_by" => "Ada Operator"`; `row.response` assertions include
  the attribution the digest now covers).
- Untouched and green: UI live tests (boundary behavior unchanged — the form
  already collected both fields; only the delegation now forwards them),
  dispatcher, integration, and `command_test.exs` digest tests.
- Fail-on-base (`ecd937b`, verified by stashing tracked changes and running
  the new file against base code with the new migration present): 6 of 7
  fail for the right behavioural reasons — base `validate_response/1` keeps
  only `%{"resolution"}` and ACCEPTS unattributed responses as
  `{:ok, recorded}` (the refusal test), drops `confirmed_by` from the
  persisted response (human/intent tests), replays instead of conflicting
  across identities (`outcome: :replayed`, no events — proving the digest
  now covers identity), and lacks the new columns/fields (`KeyError` /
  `ArgumentError` on absent code — new-surface documentation labeled
  honestly per the T1 precedent). The 7th (response/response_digest pair
  integrity) PASSES on base: it documents preserved pair semantics, not a
  regression lock.
- Gate: `mix precommit` — exact command and counts recorded in the work report.
