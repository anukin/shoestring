# Product follow-up: agent configuration and usage UI

**Status:** proposed; product direction and mockup accepted, implementation pending.

**Decision recorded:** 2026-10-05.

**Scheduling:** separate product follow-up; does not close iteration 6 or change
the dependency ordering of its executor and amendment packages. Confirm its
implementation slot after the CLI-facing contracts are established.

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

The user accepted this overall direction. No final choice between the two
layouts, exact model catalog, or arbitrary-team editor was made; those remain
implementation decisions. The mockup is not a shipped product or provider
support claim.

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

- [ ] Define persisted orchestrator configuration and revision semantics.
- [ ] Establish CLI selection of named agents and CLI-facing approval flow.
- [ ] Build Usage from existing normalized capacity observations.
- [ ] Build Agents create/edit/duplicate and provider/model selection.
- [ ] Build Settings for supported connections and defaults.
- [ ] Add history visualization where stored observations support it.
- [ ] Verify restart persistence and UI/CLI configuration consistency.
- [ ] Verify shared quota, missing/stale observations, and narrow-screen/keyboard use.
- [ ] Run `mix precommit` with hermetic fixtures and record exact counts.

## Acceptance gate

1. A user creates or edits an agent in the UI; the CLI resolves the saved
   configuration after restart without an inference call.
2. Existing approved work retains its bound configuration/plan semantics when
   an agent is edited.
3. Usage views accurately distinguish observed data from unknown or stale data,
   identify shared scope, and do not promise unsupported live telemetry.
4. The product UI stays within configuration and usage; work and approval remain
   available through the CLI with their existing safety contracts.

**Completion record:** not implemented; no production acceptance evidence yet.
