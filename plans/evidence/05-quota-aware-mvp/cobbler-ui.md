# Milestone 05: Cobbler UI & Explanation (WP G, Incremental Slice)

- **Status**: UI slice (Milestone 05, stacked on T1 at `e7c0b9a`)
- **Scope**: Read-only Cobbler dashboard (`/cobbler`) and per-goal explanation page
  (`/cobbler/goals/:goal_id`) with presentational lifecycle mapping, admission /
  lease / checkpoint / claim / sleep cards, command stream with a single
  confirm/respond form, event stream with PubSub live refresh, projection
  status, and degraded warnings. The only write from any LiveView is the
  confirm/respond form delegating to `Cobbler.respond_command/4`.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. Modules and Routes (`REPO-INSPECTION`)

| Module | Role |
| :--- | :--- |
| `ShoestringWeb.CobblerPresentation` | Pure presentational mapping: lifecycle / decision / command / lease / renewal states to labels, dots, badges, icons, and `data-status` tags, each with an honest `:unknown` fallback; `derive_goal_state/2` folds admission results and command result kinds through `GoalLifecycle` and yields `:unknown` on anything unrecognized instead of raising. |
| `ShoestringWeb.CobblerDashboardLive` | Read-only goal list. Streams goal summaries (`#cobbler-goals-list`, rows `#cobbler-goal-<id>[data-status]`), `#cobbler-empty`, `#cobbler-refresh` (re-reads only). |
| `ShoestringWeb.CobblerGoalLive` | Per-goal explanation: header/status, admission card, lease card, checkpoint card, claim card, sleep-honesty card, commands stream with confirm/respond forms, events stream with PubSub live refresh, projection status with read-only rebuild affordance on `failed`, degraded warnings. |
| Router | `live "/cobbler"` + `live "/cobbler/goals/:goal_id"` in the existing browser scope; no new pipeline, no `live_session`. |

Facade use is read-only except one path: `list_commands/2`, `active_claim/1`,
`rebuild_commands/2`, `command/3` (reads); `respond_command/4` (the single
confirm/respond write). No changes to state machines, dispatcher,
projectors, registries, or Oban queues.

## 2. Honest Unknowns (`VERIFIED`)

- **Sleep card**: no `sleep_until`/`wake_at` source exists anywhere in the
  tree, so the card states that no wake source is recorded and the T3
  producer is pending. A test asserts the card contains **no `<time>`
  element** for a non-sleeping goal.
- **Lease/checkpoint/claim cards** render explicit empty states
  (`#cobbler-lease-empty`, `#cobbler-checkpoint-empty`, `#cobbler-claim-empty`)
  when no row exists; lease rows only appear once lease producers land (T2),
  checkpoint rows once checkpoint producers land (T3) (`UNVERIFIED` beyond
  this note — owned by parallel work packages).
- **Unrecognized values** (future T1–T4 lifecycle/lease/status codes) render
  as "Unknown" via unit-tested fallbacks; the derivation never raises.
  Registry-level unknown admission results fail closed at replay, so they
  cannot reach the card through valid writes (`VERIFIED` by the redaction
  probe below).

## 3. Attribution Boundary (`VERIFIED`)

The confirm/respond form collects `confirmed_by` (required, non-blank) and an
intent confirmation that must equal the command payload intent. Failures:

- blank `confirmed_by` → error flash, command stays `needs_user`;
- mismatched intent → error flash, command stays `needs_user`;
- unoffered resolution → domain `{:error, {:invalid_response, _}}` surfaced as
  an error flash, command stays `needs_user`.

Success resolves via `Cobbler.respond_command/4` (e.g. `abandon` →
`abandoned`) with an info flash naming the operator. `respond_command/4`
validates only `%{"resolution" => ...}`, so attribution is enforced at the UI
boundary, not persisted by the domain — an intentional, documented limit of
this slice.

## 4. Redaction, Both Directions (`VERIFIED`)

- Checkpoint evidence carrying an `sk-*` key, a `/Users/...` path, and a
  `reasoning` key renders with all three gone **and** the legitimate summary
  plus next-action text still present.
- Explanations carrying a JWT and a `<thought>` block render with both gone
  **and** the `reason_code` still present. (API keys and filesystem paths are
  fail-closed by the event registry at append/replay, so they cannot be
  stored; the render boundary is defense-in-depth for legacy rows.)
- Failed projection `error_detail` renders redacted (`Security.redact/1`,
  240-char cap mirroring the timeline) with the marker present.
- Truncation caps apply **after** redaction (`RunPresentation.cap_text/2`),
  so a cut can never bisect a raw secret.

## 5. Auth and Liveness (`VERIFIED`)

- `CobblerGoalLive.authorized_goal?/2` mirrors the timeline owner check:
  local (nil) scope admits non-observatory goals; present scopes need a
  matching owner; the protected observatory goal is denied in both modes and
  denied mounts retain neither goal, decisions, commands, nor events.
- Appended `admission.decided` events appear on the goal page without a
  reload via `Trajectory.topic/1` subscription; projection notifications
  re-read via the `trajectory:projection:<goal_id>` topic.
- Refresh/rebuild buttons call read paths only (`Trajectory.replay/1`,
  `Cobbler.rebuild_commands/2`); tests assert row/event counts are unchanged
  by them. A diverged command store (rows deleted in-test) raises
  `#cobbler-rebuild-warning`.

## 6. Verification

- New tests: `cobbler_presentation_test.exs` (12), `cobbler_dashboard_live_test.exs`
  (5), `cobbler_goal_live_test.exs` (19), `cobbler_goal_authorization_test.exs` (6).
- Gate: `mix precommit` — exact command and counts recorded in the work report.
- Fixture identifiers in tests use generated UUIDs; synthetic fixture values
  (`sk-abcdef1234567890`, `/Users/eve/...`) are format-valid shapes carrying
  no real credentials, paths, or machine identifiers.

## 7. Seams Assumed for T1–T4 Owners (`UNVERIFIED`)

- Lease rows (`harness_execution_leases`) and checkpoint rows
  (`harness_checkpoints`) appear only once T2/T3 producers land; the UI was
  verified against directly inserted rows shaped by the current schemas.
- No wake/sleep event source exists; the sleep card assumes T3 will produce
  an explicit recheck event and deliberately renders no timestamp until then.
- `handoff.*` does not exist (T4); `handing_off` renders from `reject`
  decisions only.
