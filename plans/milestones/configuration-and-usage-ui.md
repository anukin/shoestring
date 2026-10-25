# Product follow-up: agent configuration and usage UI

**Status:** configuration and usage implemented; CLI approval and execution
binding are implemented in iteration 6. Keyboard and programmatic accessibility
checks are recorded below; actual spoken screen-reader acceptance remains open.

**Decision recorded:** 2026-10-05.

**Scheduling:** separate product follow-up; does not close iteration 6 or change
the dependency ordering of its executor and amendment packages. Its
implementation does not certify the CLI-facing execution contracts.

## Agreed boundary

VERIFIED (user direction and acceptance in the design discussion): Shoestring's
work interface is the CLI. The web UI provides configuration and usage-limit
visualization. It should be minimal and make named orchestrators understandable,
inspired by Omnigent's Polly/Debby approach.

- CLI: submit work, review/edit plans, approve/reject, execute, and continue work.
- Web UI: create/edit orchestrators, choose their underlying providers/models,
  and inspect provider allowance and availability.
- Sessions, chat, execution controls, CLI/test output, and plan approval screens
  are outside this web UI's scope. Durable sessions and evidence may still exist
  internally; this decision does not remove backend contracts or diagnostics.

## Visual reference

VERIFIED (saved artifact): [standalone HTML5 mockup](../mockups/configuration-and-usage.html).
Open it directly in Firefox or Brave; no server or external dependencies are
required. It includes Usage, Agents, Settings, agent editing, and Focus/Console
layout alternatives. Usage figures, connection states, and model choices are
illustrative. Browser-local changes are preview state, not Shoestring settings.

The user accepted this overall direction. REPO-INSPECTION: implementation uses
Focus navigation, configured Claude Code/Codex model identifier catalogs, and a
required coordinator with up to five optional team roles. Catalog membership is
configuration validation; model entitlement was not verified. The mockup remains
illustrative rather than a provider support claim.

## Required outcomes

- **Usage:** compact bars for each reported provider/account allowance window,
  used/remaining values, reset time, and last observation time. Display unknown,
  stale, partial, or unavailable observations plainly; never invent percentages
  or equate missing data with available capacity. Add history charts only from
  recorded observations, with clear units and gaps for missing data.
- **Agents:** a small library of named orchestrators with purpose, stable CLI
  name, instructions, and provider/model configuration. Support create, edit,
  and duplicate; optional worker/reviewer roles can use different providers or
  models. The exact role flexibility remains to be decided.
- **Settings:** provider connections and shared defaults. Reflect actual
  connection/capability state rather than the mockup's illustrative labels.
- Keep the interface useful at narrow widths and operable by keyboard. Favor
  plain labels and disclosure for technical configuration details.

## Configuration and data contracts

- Persist real agent definitions and validate provider/model choices against
  supported, configured capabilities. A preview-only model label is not a valid
  production identifier by itself.
- The CLI resolves the same persisted agent configuration as the UI. Define
  revision/snapshot semantics before implementation so edits cannot silently
  alter an already approved plan or work in progress.
- Group allowance by its observed provider/account scope. Multiple agents
  sharing an account do not each receive a separate quota. Attribute usage to
  agents only where evidence supports that attribution.
- Provider subscription allowance, session context consumption, and API spending
  are different measures. This slice centers on subscription allowance; any
  additional measures need separate labels and verified data sources.
- Configuration does not authorize provider inference or change reserve,
  admission, worktree, or human-approval policy implicitly.

## Implementation checklist

- [x] Define persisted orchestrator configuration and immutable revision semantics.
- [x] Establish CLI lookup of named, default and historical agent snapshots.
- [x] Establish CLI-facing approval and bind snapshots to approved execution.
- [x] Build Usage from existing normalized capacity observations.
- [x] Build Agents create/edit/duplicate and provider/model selection.
- [x] Build Settings for configured model identifiers and shared defaults.
- [x] Add seven-day history from recorded observations, including missing-day gaps.
- [x] Verify restart persistence and UI/CLI configuration consistency.
- [x] Verify shared quota, missing/stale observations and narrow-screen rendering.
- [x] Verify keyboard operation and programmatic accessibility semantics (2026-10-25).
- [ ] Verify actual spoken screen-reader announcements; Firefox Inspector is narrower.
- [x] Final full-gate verification after the transaction-abort fix (record below).

## Acceptance gate

1. A user creates or edits an agent in the UI; the CLI resolves the saved
   configuration after restart without an inference call.
2. Existing approved work retains its bound configuration/plan semantics when
   an agent is edited.
3. Usage views accurately distinguish observed data from unknown or stale data,
   identify shared scope, and do not promise unsupported live telemetry.
4. The product UI stays within configuration and usage; work and approval remain
   available through the CLI with their existing safety contracts.

VERIFIED: Firefox saved an agent revision in an isolated synthetic state store.
A separate CLI process resolved its exact purpose, revision and digest; a server
restart preserved the edit, and historical revision lookup retained the original.
All eight desktop/mobile captures were inspected; the fresh review confirmed the
label contrast and mobile toast fixes. Evidence and limits live in
[configuration-and-usage.md](../evidence/06-cobbler-planning/configuration-and-usage.md).

VERIFIED: `perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null` passed:
4 doctests, 1724 tests, 0 failures, 1 skipped, 6 excluded (seed 269623);
Node capacity 52/52 and UI 8/8 passed. The earlier intermittent red gate and
its transaction-abort regression/fix are retained in the evidence record.

Historical limitation at the UI implementation gate: acceptance item 2 was not
closed then; immutable profile lookup existed without execution binding.

VERIFIED (subsequent implementation evidence): [execution-profile.md](../evidence/06-cobbler-planning/execution-profile.md)
records approved execution binding and the regression proving saved revision/model
identity survives later agent edits. Package C's [CLI approval evidence](../evidence/06-cobbler-planning/cli-approval.md)
records exact-revision approval. These close the previously pending binding/approval
item; they do not turn the earlier UI gate into a binding test.

UNVERIFIED: live entitlement for all configured models and complete keyboard/
screen-reader acceptance remain open. Settings does not test provider
authentication; it states that boundary explicitly. Iteration 6's receipt run
verifies inference only for its explicitly selected model and account.

### Accessibility follow-up — 2026-10-25

VERIFIED: the keyboard/programmatic part of the historical limitation above is
addressed by the [acceptance-gap closure evidence](../evidence/10-forecasting-packaging/acceptance-gap-closure.md).
Firefox exposed labeled role groups and controls, the skip link received the
first page Tab stop, form input reached Save by keyboard, and a submitted
validation error received focus. At the loopback literal, keyboard role
removal returned focus to Add role; Space added a role and focused its name.
A dynamically inserted settings-save message was dismissed with Tab/Enter.
The 390 × 844 form was visually inspected for stacking and wrapping.

VERIFIED: the user chose Firefox Accessibility Inspector and keyboard/automated
checks instead of VoiceOver. No spoken-announcement result is claimed. Firefox's
body-level keyboard diagnostic and the detector's existing type-size advisories
are retained in the evidence rather than presented as a clean automated audit.
