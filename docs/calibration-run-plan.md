# Real-work calibration collection plan

REPO-INSPECTION: the collection and dataset-v2 machinery is implemented; real
calibration is not established. Routing remains disabled. This plan is an
operator runbook, not a calibration result or authorization to consume quota.

## Before collection

1. Choose one real, representative task cohort. Pin its Codex provider, harness,
   model, effort, CLI version, Shoestring version and gate-derived task class.
   Do not pool different versions or invent missing metadata.
2. Declare a run/call ceiling and an allowed subscription budget before any live
   execution. Include planner, worker, retry and optional-review calls separately;
   200 accepted examples do not imply only 200 calls. Set attempt limits and
   stop at the authorized ceiling, even if too few eligible rows result.
3. Use sequential work in isolated repository worktrees. No fan-out, overlapping
   Codex runs, or opencode `openai/` work may share the collection window.
4. A human must establish that no other session or device uses the subscription
   and personally open the attested window. An agent cannot make this claim on
   the human's behalf. Close with `external_use_reported` if it stops being true.
5. Record an explicit chronological split before inspecting evaluation outcomes.
   Collect at least 100 attributable training rows, then at least 100 strictly
   later evaluation rows for the exact cohort. More attempts may be necessary
   because rejected/unassignable rows do not count.

REPO-INSPECTION: Claude and opencode cannot currently supply eligible examples.
Their missing attribution is not filled with synthetic data. Codex percentage
readings are coarse; zero deltas remain valid observed values rather than being
replaced with invented token costs.

## Operator commands

From the source checkout, against the intended state directory:

```sh
mix shoestring.measurements collection status
mix shoestring.measurements collection open --provider codex --by operator
```

REPO-INSPECTION: opening prints the attestation and requires the human to type
`I attest`. Do not pipe an answer into it. Run the approved real tasks through
the normal CLI approval/admission path, then close the window explicitly:

```sh
mix shoestring.measurements collection close --provider codex
# If there was any outside usage instead:
mix shoestring.measurements collection close --provider codex --reason external_use_reported
mix shoestring.measurements report --dataset-version 2 --split-at SPLIT_UTC_ISO8601
mix shoestring.forecasts report --dataset-version 2 --split-at SPLIT_UTC_ISO8601 --at EVALUATION_UTC_ISO8601
```

REPO-INSPECTION: replace the two timestamp placeholders with recorded UTC times.
The split separates evidence availability, not just run end times. The final
evaluation timestamp must follow all held-out evidence. These report commands
start no provider and do not enable routing.

## Acceptance evidence

REPO-INSPECTION: retain the dataset/source digests, cohort identity, split and
evaluation timestamps, exact eligible/excluded counts and reasons, task
acceptance separately from forecast coverage, the static-policy comparison and
the exact quota ceiling/usage. Exports contain local identifiers and timestamps;
keep them private and commit only redacted aggregates under
`plans/evidence/10-forecasting-packaging/`.

REPO-INSPECTION: sample counts alone do not establish calibration. Slice 10B
requires at least 99% held-out interval coverage and at most 1% observed
underprediction, with explicit fallback for sparse or shifted cohorts. False
admission, false deferral, reserve violations and useful work per capacity delta
must not be invented when the shadow evaluator cannot measure them.

REPO-INSPECTION: slice 10C remains a separate implementation and rollout decision.
It needs a declared improvement metric and reserve-violation bound, explainable
baseline comparisons, exact restoration of static policy when disabled, and
drift-triggered fallback. No successful shadow report automatically enables it.

UNVERIFIED: no real collection, new provider call, calibration result or
forecast-assisted rollout is claimed by this plan.
