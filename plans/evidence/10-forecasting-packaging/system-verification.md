# Shoestring system verification — 2026-10-21

Status: audit complete; core automated checks and fresh-process structured
memory probe passed. Current installed capacity-version compatibility remains
a recorded limitation. Verified product revision: `2a14f99`.
This is an audit of implemented contracts, not full iteration 10 acceptance or
a claim that an arbitrary real task will succeed with every provider version.
The user authorized direct work/push on main earlier in this session; that
explicit instruction overrides standing worktree/PR isolation for this report.

## What “memory” means here

REPO-INSPECTION: canonical SQLite trajectory events, goal/task state, structured
checkpoints, decisions, artifact references and bounded continuation/handoff
context are implemented. Checkpoints carry an acceptance contract, repository
revision/dirty state, completed work, verification evidence, unresolved issues
and next action. Continuation authority checks the current checkpoint, decision
references, lease and session binding before permitting resume.

REPO-INSPECTION: no separate embeddings, semantic search or general cross-project
agent knowledge store was found in the inspected implementation. Iteration 1
explicitly excludes model-generated summaries, embeddings and semantic
retrieval. This audit does not turn structured continuity into a claim of that
broader capability. Provider transcripts/hidden reasoning are not the durable
continuation contract.

## Fresh-process durable-context probe

VERIFIED: the already sealed 0.2.0 native release at product revision `2a14f99`
ran three separate BEAM invocations against newly created synthetic state:
initialize; write a goal/task/run/checkpoint/artifact; read them in a fresh VM.
Automation was disabled, HTTP endpoint startup was disabled, and guarded PATH
commands would record and refuse any provider/system toolchain launch.

The read phase checked:

- A different OS process performed the read.
- Canonical event IDs and order remained unchanged.
- The goal and task titles survived process exit.
- Artifact bytes survived and passed the product's size/hash/containment read.
- The run-scoped continuation recovered the exact checkpoint and next action.
- The composed handoff retained required objective, evidence, decision, open
  issue and next-action markers.
- Re-recording the same checkpoint returned replayed with zero new events.
- A subsequent append continued at the next canonical sequence.

VERIFIED: write/read exited 0; four canonical events existed before the final
append. Provider/system toolchain guard launch count was zero. No live model
call, worktree mutation or user database was involved. Scratch code/state/logs
are retained under ignored `tmp/iter10-durable-context-verification-v2/`.
This is an orderly process-exit/reopen check, not a physical power-loss test.

VERIFIED: the initial probe fixture used atom keys inside an event's JSON
payload. The public append boundary correctly refused that invalid input before
any checkpoint was written. The fixture was corrected to JSON string keys and
run on fresh state; original failed logs/state remain retained separately.
No product code or test assertion was changed to obtain a pass.

## Finding: current installed capacity versions require verification

VERIFIED: bounded metadata-only `--version` calls through the product's
`Release.ProviderProbe.capture/2` observed Claude `2.1.307` and Codex `0.163.0`.
No prompt, authentication-status command or inference was sent. Raw CLI output
was discarded after extracting the numeric versions.

VERIFIED: a separate pure product compatibility lookup using those observed
versions returned:

| Provider/mode | Installed CLI | Tested capacity versions | Result |
| --- | --- | --- | --- |
| Claude interactive status-line capacity | 2.1.307 | 2.1.251 | degraded / conservative_partial |
| Codex App Server capacity | 0.163.0 | 0.150.1, 0.162.0, 0.162.1 | degraded / proactive |

REPO-INSPECTION: `CapacitySnapshot.eligible?/2` requires compatible, high-confidence
fresh proactive observations. `AdmissionEvaluation.check_bypassable_conditions`
requires attributable confirmation for partial support or degraded compatibility.
Consequently these current installed versions do not establish unconfirmed
automatic quota admission. This is intentional conservative behavior, not proof
that their execution or TUI protocols are broken. The older successful TUI smoke
does not establish capacity-protocol compatibility.

REPO-INSPECTION: execution adapter identity versions (`2.1.261` / `0.153.2`) are
separate fixture baselines, not the capacity registry. The release doctor also
flags version drift against those baselines. Do not make either check green by
changing version constants without protocol evidence and corresponding fixtures.
The runtime capacity lookup is the authority for the admission finding here.

UNVERIFIED: current-version live capacity protocols and live worker execution.
Version-specific capture/schema review is the next compatibility verification
step; this audit intentionally does not promote unobserved versions to tested.

## Requirements and automated evidence

VERIFIED: the fresh full gate passed for the inspected product revision.
The following REPO-INSPECTION mappings identify the behavior each included suite
checks. The listed files contain both successful behavior and applicable refusal
paths; synthetic transports do not establish live vendor behavior.

| Area | Contract checked | Automated evidence |
| --- | --- | --- |
| Durable history | Ordered/idempotent appends, writer restart, replay, visible incompatible-history refusal | `trajectory/append_test.exs`, `trajectory/replay_test.exs`, `trajectory/writer_contention_test.exs` |
| Goal/task reconstruction | Resumable projection, identical rebuild, per-goal isolation | `trajectory/projector_test.exs`, `trajectory/projector_cobbler_test.exs` |
| Checkpoint memory | Owned run/artifacts, bounded validated contents, exact idempotent replay, no-model fallback | `harness/checkpoints_test.exs`, `harness/checkpoint_fallback_test.exs`, `elves/terminal_checkpoint_test.exs` |
| Resume and handoff | Fresh checkpoint/decisions/lease/session, required context retained, transcript/secret fields excluded | `harness/continuation_resume_test.exs`, `harness/handoff_projection_content_test.exs`, `harness/handoff_privacy_test.exs`, `cobbler/handoff_production_test.exs` |
| Durable task delivery | No duplicate launches, lost-delivery repair, authoritative child acknowledgements | `cobbler/plan_dispatch_claim_recovery_test.exs`, `cobbler/plan_child_inbox_test.exs`, `harness/dispatches_test.exs` |
| Planning and execution | Canonical revision replay, approved binding, worker/gate integration, dependent task progression | `cobbler/plan_replay_test.exs`, `cobbler/plan_executor_integration_test.exs`, `cobbler/plan_fanout_integration_test.exs` |
| Quota and reservations | Unknown capacity refuses/waits, restart retains authority, no replacement while ownership is uncertain | `cobbler/execution_admission_waiting_test.exs`, `cobbler/reservation_recovery_integration_test.exs`, `cobbler/admission_recovery_test.exs` |
| Worktrees and processes | Source isolation, safe cancellation, checkpoint capture, staleness alone does not kill useful work | `worktrees_test.exs`, `elves/elf_checkpoint_resume_test.exs`, `elves/staleness_test.exs`, `elves/elf_test.exs` |
| Acceptance and review | Recorded gate identity/commit, sandboxed checks, stale-evidence refusal, independent review and human resolution | `cobbler/plan_gate_contract_test.exs`, `cobbler/gate_sandbox_test.exs`, `cobbler/plan_review_test.exs`, `cobbler/gate_output_stream_test.exs` |
| UI and terminal | Form-to-worker lifecycle, restart continuation, terminal ownership, slow-consumer bounds and recovery | `../shoestring_web/live/hermetic_lifecycle_test.exs`, `terminal/session_test.exs`, `terminal/recovery_test.exs`, `../shoestring_web/channels/terminal_channel_test.exs` |
| Retention and privacy | Artifact integrity/ownership, redaction with useful evidence retained, bounded terminal logs and diagnostics | `trajectory/artifact_store_test.exs`, `trajectory/redaction_test.exs`, `terminal/retention_test.exs`, `diagnostics/bundle_test.exs` |
| Release and optional text adapters | Private bootstrap, upgrade backup integrity, helper compatibility, once-only HTTP calls, zero-default durable API cap | `release/backup_test.exs`, `release/bootstrap_test.exs`, `release/doctor_test.exs`, `harness/http_test.exs`, `measurement/api_spend_concurrency_test.exs` |

Test paths are relative to `test/shoestring/`, except the explicit web paths.
The fresh full gate command is `timeout 590 mix precommit < /dev/null`.
VERIFIED: it exited 0 with 4 doctests, 2411 tests, 0 failures, 1 skipped,
6 excluded; seed 645636. ExUnit took 564.1 seconds (12.6 async, 551.5 sync).
Rust formatting/Clippy, 4 unit and 5 integration tests passed. JavaScript passed
52/52 and 14/14 tests, both with zero failures. The local raw gate log is retained
under ignored `tmp/iter10-system-verification-precommit.log`; the aggregate
[JSON record](system-verification.json) contains no raw provider output or user
identifiers. No product code was changed during verification. No new regression
lock or pre-fix failure proof is claimed by this audit.

## Limits of the result

- UNVERIFIED in this run: fresh real Claude/Codex inference, actual vendor
  session continuity and long-lived model behavior. Older iteration 8/9 live
  records remain historical evidence only. Six opt-in live tests are excluded
  by the ordinary gate configuration; their absence is not a pass.
- UNVERIFIED: RSS/leak/long-duration load testing. Bounded-buffer/backpressure
  tests exercise specified limits, not a general proof of absence of leaks.
- UNVERIFIED: fresh supported-machine/Homebrew installation. Prior local native
  archive relocation smoke is narrower than that acceptance requirement.
- UNVERIFIED: live new API/local inference. The user acknowledged keeping paid
  API verification pending; Ollama metadata checks found no reachable daemon.
- REPO-INSPECTION: independent review and optional API/local adapters are configuration-dependent and disabled by default. Tests that enable them do not establish that a user service has enabled them.
- UNVERIFIED: the configuration and real task behavior of any separately running user instance; this probe uses isolated synthetic state.
- REPO-INSPECTION: forecast routing is disabled. Real calibration/provenance and
  forecast-assisted policy acceptance remain open; no synthetic run qualifies
  as attributable real-work calibration evidence.
- REPO-INSPECTION: Linux sandbox support remains deferred. This result applies
  to the supported local macOS arm64 environment, not all platforms.
- REPO-INSPECTION: the application remains local single-user software. The README
  explicitly records the absence of a multi-user authentication boundary; this
  audit does not establish safe exposure to untrusted or shared users.
