# Iteration 14 evidence

## Fixture convention

Captured provider replies are kept as **excerpts**: the member of the reply
Shoestring reads, byte-identical in value (re-serialized with sorted keys).
Members Shoestring does not read are left out rather than rewritten, so no
account, session or local-configuration data is kept and no captured value
is altered. Each fixture below names the member it is an excerpt of. When a
later fixture must keep an identifier, it is replaced with a synthetic value
of the same shape and the substitution is listed here.

## Model listing probe, 2026-10-25

The user authorized one model-listing call per harness ("Yes, all three"):
no prompt is sent and no allowance is used. `model_listing_probe.py` is the
script that ran (`python3 -I model_listing_probe.py HARNESS OUT.jsonl CWD`,
from an empty scratch directory).

| Harness | Version | Request | Excerpt kept | Fixture |
| --- | --- | --- | --- | --- |
| Codex | codex-cli 0.164.0 | `initialize`, `initialized`, `model/list` on `codex app-server --stdio` | the `result` of `model/list` (7 models, no `nextCursor`) | `test/fixtures/model_listing/codex_model_list_result.json` |
| opencode | 2.0.31 | ACP `initialize`, `session/new` on `opencode acp` | `result.configOptions` of `session/new` (`model`: 150 options from `openai` 79, `opencode` 41, `opencode-go` 30; `mode`: 2) | `test/fixtures/model_listing/opencode_session_new_config_options.json` |
| Claude Code | 2.1.310 | stream-json `control_request` `initialize` | `response.response.models` (13 models) | `test/fixtures/model_listing/claude_initialize_models.json` |

VERIFIED from the captured frames:

- Each CLI exited 0 after its stdin closed.
- Claude Code sent exactly one frame, the `control_response`; no inference
  frame (`assistant`, `result`) appeared.
- Codex reports per-model efforts (`supportedReasoningEfforts`, some up to
  `max` and `ultra`) and a `defaultReasoningEffort`; Claude Code reports
  `supportedEffortLevels` (absent for `claude-haiku-4-5-20251001`) and the
  model each alias resolves to (`opus` → `claude-opus-5-5`); opencode reports
  no effort until a model is chosen.
- The largest reply frame was about 40 KB (Claude Code), under the 256 KB
  frame limit.

Side effect: the opencode probe created one unprompted session in opencode's
own storage, as every `shoestring models refresh opencode` will.
