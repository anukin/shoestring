# Saved agent and model binding

REPO-INSPECTION: approved execution can select a saved agent's immutable
revision, digest and named role. The execution stores the selected provider,
adapter, model and instructions. Editing the agent afterward does not change
that execution. Dispatch admission must name the same provider and adapter;
the persisted run and delivery options retain the selection. The provider's
`default` sentinel is refused because it does not select an explicit model.

REPO-INSPECTION: Codex fresh and resumed threads and turns receive the model
parameter; Claude receives a distinct `--model` argument. The protocols are
documented in [Codex app-server](https://learn.chatgpt.com/docs/app-server) and
[Claude CLI reference](https://code.claude.com/docs/en/cli-reference). Runtime
custom argv cannot replace the model on a bound delivery. Trusted application
adapter injection remains available for hermetic tests.

VERIFIED: the focused command
`perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/execution_profile_test.exs test/shoestring/harness/provider_model_selection_test.exs test/shoestring/cobbler/plan_executor_test.exs test/shoestring/harness/dispatch/elf_effect_test.exs < /dev/null`
exited 0 with **36 tests, 0 failures**, seed **165910**, in **1.1 seconds**.
Transport tests use only in-memory fakes. Delivery uses the fake harness and a
local `cat`, an owned supervisor, a fixed clock, a terminal notification and
process monitor. No provider execution or quota was used.

VERIFIED: all **9 new tests fail behaviorally** against an archive of the exact
pre-fix main commit `a99d3e7558d1d22489d03bcba816a2d6633f1eb1`; seed **107548**,
**0.3 seconds**, exit **2**. Assertions detect missing protocol model fields,
missing Claude model argv, ignored saved profile/digest/admission constraints,
and runtime options replacing the selected model. This proof copies only the
four test/support files into the original source archive. Earlier archive setup
failed on build-directory symlinks and permissions; its missing-test-path run
was not regression evidence.

VERIFIED: earlier focused runs were red while the test transports lacked owner
synchronization and the full configuration exceeded the existing extension
depth bound. The binding now retains compact immutable references and selected
instructions. Subsequent fixture corrections addressed missing fake scenario,
terminal message shape and database-owner cleanup. The existing missing-Codex
log comes from a deliberate nonexistent-executable test, not provider execution.

UNVERIFIED: no live provider launch or physical model identity was verified.
Configured vendor aliases remain vendor aliases. CLI execution, quota
continuation and model-assisted amendments remain separate remaining work.

VERIFIED: full gate
`perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null`
exited **0**: **4 doctests, 1806 tests, 0 failures, 1 skipped (6 excluded)**,
seed **351490**, **161.5 seconds** (**9.2 async, 152.3 sync**). The JavaScript
suites passed **52/52** and **8/8**, with zero failures.

VERIFIED (user instruction): this checkpoint is developed and published directly
on main, overriding the standing branch/PR and source-checkout isolation rules.
