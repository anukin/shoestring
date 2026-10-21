# Shadow forecast reports

```sh
mix shoestring.forecasts report --split-at 2026-10-01T00:00:00Z --at 2026-10-21T06:00:00Z
```

This repository-only command derives fresh measurements and evaluates them as
of an explicit timestamp. It starts no provider or execution worker. There is
no enable switch, and neither admission nor reservation code calls the shadow
evaluator. Every result retains the static policy with `policy_effect: none`.

Forecast/evaluator v1 groups exact provider, harness, model, effort, adapter/CLI
version and task class. Missing features and model/version changes cannot be
filled by pooling incompatible cohorts. At least 100 training rows and 100
strictly later held-out evaluation rows are required per class. Every included
row needs an assignable label, high attribution confidence, established external
isolation, no exclusions or overlapping runs, and source evidence available
strictly before `--at`. A row whose outcome postdates its supposed evidence
availability is rejected. Duplicate run rows and unsupported dataset versions
fail closed.

The empirical interval is zero through the finite-sample 99% upper order
statistic, using rank `ceil((n + 1) * 0.99)`. The evaluator then reports held-out
interval coverage and underprediction separately from task acceptance. The
initial coverage target is 99%, with at most 1% observed underprediction. Below
that target it withholds the forecast and reports the failed candidate interval.
Passing a finite held-out cohort is not a statistical guarantee, calibration on
real user work, or acceptance of forecast-assisted routing.

Reports identify cohorts by a digest instead of echoing arbitrary model/class
text. They expose sample counts, timestamps, thresholds, candidate/accepted
intervals and fallback reasons. Task acceptance remains distinct from interval
coverage. False admission/deferral and work per capacity delta remain unknown:
this evaluator changes no decisions, and configured concurrency weights are not
provider percentages. It does not invent a static-reserve comparison by equating
those units.

VERIFIED: constructed 200-row cohorts exercise the calculation and conservative
fallback paths. These are test fixtures, not measured provider consumption.
Historical dataset v1 cannot establish external isolation and has no assignable
labels; real local reporting therefore produces no usable forecasts. Real
calibration and slice 10C's improvement/rollout requirements remain open. The
user explicitly authorized proceeding with independent adapter/packaging/
diagnostic work while forecast enforcement stays disabled.
