# Optional local and capped API text runs

These adapters produce one text artifact. They have cancellation, normalized
lifecycle/error/result events and durable dispatch ownership. They do not have
repository tools, interactive input, resume or repair loops. A completed response
does not accept a task or substitute for a recorded gate. Use the existing
Claude/Codex workers for repository changes.

Both adapters are disabled by default. Configuration belongs to the operator's
service environment; prompts and model output cannot choose caps, prices,
credentials, endpoints or additional calls. The queueing CLI needs the same
configuration as the service. Each request is claimed durably before execution.
Repeated delivery and restart cannot authorize another inference for that run.
There is no automatic retry, download, model pull or fallback to another provider.

## API configuration

The initial adapter uses text-only standard OpenAI Responses with `gpt-6-luna`,
no tools, no storage/background job, reasoning effort `none`, disabled input
truncation, and an explicit output ceiling. Input/output usage counters reconcile
the frozen upper-price reservation. Missing, invalid or untrusted usage retains
the whole maximum. See [spend authority and dated pricing](api-spend.md).

Supply an API key through the service's secret environment. Do not put it in a
prompt, repository, diagnostic bundle or committed configuration. An operator
may explicitly configure, for example:

```sh
export SHOESTRING_API_ENABLED=1
export SHOESTRING_API_MONTHLY_CAP_MICROUSD=1000000
export SHOESTRING_API_PRICE_VERSION=openai-standard-upper-2026-10-20-v1
export SHOESTRING_API_MAX_OUTPUT_TOKENS=4096
```

That example cap is USD 1, not a recommendation to spend it. It authorizes no
calls until an operator actually submits work. The reviewed price interval
expires on 2026-11-20; new calls then fail closed until a reviewed schedule is
accepted. The API transport reads `OPENAI_API_KEY` only after the durable
reservation. Changing the key or account does not reset local spend history.
Separate applications sharing that account can incur costs outside Shoestring.

Each call's normalized evidence identifies its price version, model, output
ceiling and maximum reserved microusd. The ledger survives application restart
and month rollover; lower caps do not release prior reservations. Counter-based
upper bookkeeping is not a provider invoice or a guarantee against provider
pricing/behavior outside the reviewed assumptions.

## Local configuration

Run a separately administered Ollama daemon in local-only mode. Official
[Ollama configuration](https://docs.ollama.com/faq#how-do-i-disable-ollamas-cloud-features)
supports `OLLAMA_NO_CLOUD=1` or `disable_ollama_cloud`; restart the daemon after
changing it. Shoestring does not change that configuration or start the daemon.
The operator must confirm it and pin a preinstalled local GGUF model:

```sh
export SHOESTRING_LOCAL_ENABLED=1
export SHOESTRING_LOCAL_CLOUD_DISABLED_CONFIRMED=1
export SHOESTRING_LOCAL_MODEL=YOUR_PREINSTALLED_MODEL_TAG
export SHOESTRING_LOCAL_MODEL_DIGEST=YOUR_64_CHARACTER_MODEL_SHA256
export SHOESTRING_LOCAL_SERVER_VERSION=YOUR_NUMERIC_SERVER_VERSION
export SHOESTRING_LOCAL_CONTEXT_TOKENS=8192
export SHOESTRING_LOCAL_MAX_OUTPUT_TOKENS=512
```

These are placeholders, not an installed model or verified local configuration.
Before generation the adapter checks the exact server version, tag/digest,
positive local model size, GGUF format and absence of remote-model fields.
It contacts only literal loopback port 11434. Model tags naming cloud resources
are refused. Loopback alone does not prove local inference: the daemon and its
configuration remain trusted operator responsibilities, and preflight metadata
does not prevent an operator changing the model/configuration concurrently.

Local execution consumes compute, memory/context and user time. It never
reports subscription capacity or an unlimited/free quota. The adapter sets
`num_ctx`/`num_predict`, disables thinking output, requests raw prompt processing,
and refuses inputs whose byte count plus output allowance and headroom exceed
the configured context. This is conservative input screening, not a verified
tokenizer accounting guarantee for every GGUF model. Only the response field is
retained; separate thinking fields and known private-channel tags are excluded.

## Queue a response

Start the configured service against the same state directory. From a source
installation:

```sh
mix shoestring.text --provider local --prompt-file prompt.txt
mix shoestring.text --provider api --prompt-file prompt.txt
```

The prompt file must be a regular file of 1–12,000 bytes and satisfy the existing
run-request contract. The command creates a manual goal/task and prints their
IDs with the run/dispatch IDs. To use existing records, supply both `--goal UUID`
and `--task UUID`. Queueing starts no provider in the CLI. If delivery later
fails, its durable records remain for inspection; they are never cleaned up
automatically.

For a packaged release use `bin/shoestringctl text local prompt.txt` (or `api`).
Existing IDs can be supplied as `text local GOAL_UUID TASK_UUID prompt.txt`.
Follow the goal using the existing follow/result commands or local UI. Output
artifacts contain the visible response after credential-pattern redaction; raw
HTTP envelopes, hidden reasoning, credentials and provider-generated identifiers
are not persisted by these adapters.

HTTP bodies are bounded to 64 KiB on both success and failure. Oversized,
malformed, incomplete, unexpected-tier or incompatible responses fail closed.
Redirects, decompression and automatic retries are disabled. Connection setup
is bounded; quiet model work has no receive timer. A transport failure,
cancellation or local process death
does not prove remote inference stopped: ambiguous API usage retains the full
reservation. Cancellation stops the owned local HTTP task. No second call is
silently substituted for the uncertain one.

## Compatibility and adapter development

Implement `Shoestring.Harness.Adapter` with an explicit identity/capability set.
Reuse shared contract assertions, and test unsupported optional operations
explicitly. Local adapters must refuse subscription-capacity claims instead of
simulating provider percentages. Keep changing commercial facts dated and
operator-reviewed. Any inference must have a durable once-only authority before
transport. A new retry is a new explicit run and needs a new reservation.

Use format-valid synthetic protocol data and the hermetic shared contract/failure
tests. Check both positive and refusal paths, source/request identity, cancellation,
owner death, restart, ambiguous usage, raw-size limits, redaction AND useful data
retention. Update protocol fixtures and declared wire versions only with actual
schema evidence. Do not label a synthetic fixture as a live capture. Live
verification requires a separately named call budget under the agent contract.

These adapters currently have synthetic contract/integration coverage. I did not
verify live OpenAI or Ollama inference during this implementation.
