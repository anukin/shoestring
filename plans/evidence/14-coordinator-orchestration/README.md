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

## Offline launch checks, 2026-10-26

What each coordinator CLI does with the arguments Shoestring gives it, read
from the request it would send. Each CLI ran with a scratch `HOME` (and
`CODEX_HOME`, `XDG_*` for Codex and opencode), a dummy key and its API
address on `capture_server.py` (`python3 -I capture_server.py PORT OUT`),
which records each request body and answers 400. No request left the
machine, no model was called and no allowance was used. Only the fields
below were read; the captured bodies (which hold each CLI's own system
prompt) are not kept.

| CLI | Invocation (besides scratch home, dummy key, local address) | Read from the request | Result |
| --- | --- | --- | --- |
| Claude Code 2.1.310 | `claude -p hi --model opus --effort high --effort low` (and reversed) | `output_config.effort` | `low` (reversed: `high`): the last `--effort` wins |
| Claude Code 2.1.310 | same, no `--effort`, `--model opus` and `--model sonnet` | `output_config.effort` | `medium` for both |
| Claude Code 2.1.310 | `--append-system-prompt-file FILE` | `system` | holds FILE's marker line |
| Codex 0.164.0 | `codex exec -m gpt-6-luna -c developer_instructions='''…''' -c model_reasoning_effort="high"`, with a `model_providers.capture` entry at the local address | `input[role=developer]`, `reasoning` | the developer message is FILE's text exactly; `reasoning.effort` is `high` |
| opencode 2.0.31 | `opencode run --standalone -m openai/gpt-6-luna` with `OPENCODE_CONFIG_CONTENT` `{"model", "instructions": [FILE], "provider": {"openai": {"options": {"baseURL", "apiKey"}}}}` | request bodies | FILE's marker is in the main request (not in its two short side requests) |

UNVERIFIED: the interactive start `shoestring chat` uses (`claude`, `codex`
and `opencode` with no prompt) takes the same flags and configuration, but
was not run against the capture server.

## Offline explorer checks, 2026-10-26

`Shoestring.Dispatches.Explore.ClaudeHeadless` and `.CodexExec` were run
through their real code against `capture_server.py`. A wrapper executable
gave each CLI a scratch home, a dummy key and the local address; Codex got
a `model_providers.capture` entry. No model was called.

| CLI | Read from the request | Result |
| --- | --- | --- |
| Claude Code 2.1.310 | `tools`, `output_config` | `Glob`, `Grep`, `Read` and `StructuredOutput` only; effort `low` as given; the brief present |
| Codex 0.164.0, `gpt-5.1-codex` | `tools`, `reasoning`, `text.format`, the environment message | `exec_command`, `write_stdin`, `request_user_input` (web search, images, multi-agent and goals off); effort `low`; `json_schema`; "`sandbox_mode` is `read-only`" and "Network access is restricted" |
| Codex 0.164.0, `gpt-6-luna` | `tools` | none: under the stand-in provider Codex has no metadata for that model. With the real provider its catalog has it; UNVERIFIED |

`request_user_input` cannot be switched off in 0.164.0. An explorer that
calls it fails as `explorer_used_tools`, closed.
