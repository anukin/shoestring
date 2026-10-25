# Current acceptance status

REPO-INSPECTION: implementation completion, hermetic checks, historical live
receipts and full roadmap acceptance are separate claims. The milestone index
and dated completion addenda remain the authoritative history; old proposed
headers do not override later decisions.

| Area | Evidence and boundary |
| --- | --- |
| Core supervisor, plans, concurrency, review, terminal and installed CLI | REPO-INSPECTION: implemented, with dated acceptance records through iterations 9 and 11–13 in the [milestone index](../plans/milestones/README.md). |
| Fresh supported-machine installation | VERIFIED by committed historical evidence: iteration 12's [fresh VM run](../plans/evidence/12-installed-cli/README.md#fresh-vm-acceptance-verified-2026-10-24), 38 PASS, 0 FAIL. This is not a new VM run. |
| Real forecast calibration | UNVERIFIED: dataset-v2 collection exists; attributable real examples and slice-10B acceptance remain open. See the [collection plan](calibration-run-plan.md). |
| Forecast-assisted routing | REPO-INSPECTION: disabled by the recorded user decision; slice 10C is deferred. No data threshold enables it implicitly. |
| Optional API/local text adapter inference | UNVERIFIED live: hermetic contract/cap tests are narrower than real inference. Paid API policy defaults to disabled with zero allowance. |
| Accessibility | REPO-INSPECTION: keyboard and programmatic accessibility checks are recorded in the [current closure evidence](../plans/evidence/10-forecasting-packaging/acceptance-gap-closure.md). Actual spoken screen-reader announcements are not established by an accessibility tree. |
| Platform/exposure | REPO-INSPECTION: macOS arm64 and a single local user are the supported scope. Linux sandboxing and a shared/non-loopback authentication boundary remain deferred. |

REPO-INSPECTION: live provider calls require a named quota budget. An ordinary
gate excludes live tests and does not verify current login, model entitlement
or vendor behavior. A separately running user installation also needs its own
configuration/readiness check.

REPO-INSPECTION: RSS/leak and long-duration operational behavior are not proved
by the deterministic bounded-buffer and lifecycle tests. A load-test result must
state its duration, workload, concurrency and measured resource bounds.
