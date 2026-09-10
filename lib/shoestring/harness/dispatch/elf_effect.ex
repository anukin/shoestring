defmodule Shoestring.Harness.Dispatch.ElfEffect do
  @moduledoc """
  Production `Shoestring.Harness.Dispatch.Effect`: delivers one claimed
  dispatch by starting the supervising Elf for the persisted run intent.

  The Oban `Shoestring.Harness.DispatchWorker` calls `perform/2` only after
  `Shoestring.Harness.Dispatches.prepare_for_effect/2` has reconciled and
  claimed the dispatch, so this effect never launches blindly: it rebuilds the
  `RunRequest` from the durable `RunRecord` and starts (or attaches to) the
  single Elf for the run via `Shoestring.Elves.start_elf/3`.

  ## Start/outcome mapping (P1-P2)

  The mapping mirrors the UI's `gated_dispatch` (`ShoestringWeb.RunNewLive`,
  read-only reference): both start outcomes are delivery success, a start
  failure is a failure, and anything that cannot be executed is never
  invented.

    * `{:ok, pid}` → `:ok` (worker records `effect_completed`);
    * `{:ok, :already_running, pid}` → `{:ok, :already_running}` (a 2-tuple,
      so the worker records `effect_completed`; the 3-tuple is normalized
      here because the worker maps any other shape to `effect_unknown`).
      No second Elf is started: idempotency rests on the Elf `run_id`
      registration, exactly as in the UI path;
    * `{:error, reason}` from `start_elf/3` → `{:error, reason}` (worker
      records `effect_failed`, not unknown);
    * unrebuildable persisted request or unrecognized provider →
      `{:unknown, reason}` (worker catch-all records `effect_unknown`; no
      execution is invented).

  ## Fire semantics (P4)

  This effect starts the Elf and reports delivery; it does NOT wait for the
  run's terminal state (contrast `Shoestring.Elves.DispatchEffect`, the
  blocking test/operator effect). A crash between start and completion
  resolves through the existing reconcile → requeue → outcome paths — no new
  mechanisms are introduced here.

  ## No re-admission (P5)

  The dispatch was already authorized at enqueue time; this effect performs no
  Cobbler gating, emits no trajectory events, and introduces no new event
  types. Claim/gate semantics are untouched.

  ## Elf options

  Provider launch parameters (`adapter`, `command`, `process_owner`) default
  from the run's persisted `provider_id`, mirroring the provider branches of
  the manual-run UI. `Application.get_env(:shoestring, :elf_dispatch_opts)`
  overrides any default per key (hermetic tests inject `scenario:`,
  `command:`, `runner_opts:`, and an isolated `supervisor:` this way).
  """

  @behaviour Shoestring.Harness.Dispatch.Effect

  alias Shoestring.Elves
  alias Shoestring.Harness.{ClaudeHeadless, CodexAppServer, DispatchRecord, Fake, RunRecord}

  @impl true
  def perform(%RunRecord{} = run, %DispatchRecord{} = dispatch) do
    with {:ok, request} <- Elves.request_from_run(run),
         {:ok, opts} <- elf_opts(run) do
      case Elves.start_elf(request, dispatch, opts) do
        {:ok, _pid} -> :ok
        {:ok, :already_running, _pid} -> {:ok, :already_running}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:unknown_provider, _provider_id}} -> {:unknown, :unknown_provider}
      {:error, _reason} -> {:unknown, :invalid_persisted_request}
    end
  end

  # -- Private helpers --

  defp elf_opts(%RunRecord{provider_id: provider_id}) do
    case provider_defaults(provider_id) do
      {:ok, defaults} ->
        {:ok, Keyword.merge(defaults, Application.get_env(:shoestring, :elf_dispatch_opts, []))}

      {:error, _reason} = error ->
        error
    end
  end

  # Launch parameters mirror the manual-run UI's provider branches
  # (`ShoestringWeb.RunNewLive`, read-only reference). Unknown providers are
  # refused rather than executed under a guessed adapter.
  defp provider_defaults("shoestring.harness.fake") do
    {:ok, [adapter: Fake, process_owner: :runner, command: ["sleep", "30"]]}
  end

  defp provider_defaults("codex_app_server_stdio") do
    {:ok,
     [
       adapter: CodexAppServer,
       process_owner: :adapter,
       command: ["codex", "app-server", "--stdio"],
       adapter_opts: %{live: true}
     ]}
  end

  defp provider_defaults("claude_headless_stream_json") do
    {:ok,
     [
       adapter: ClaudeHeadless,
       process_owner: :adapter,
       command: ["claude", "--print", "--verbose", "--output-format", "stream-json"],
       adapter_opts: %{live: true}
     ]}
  end

  defp provider_defaults(provider_id), do: {:error, {:unknown_provider, provider_id}}
end
