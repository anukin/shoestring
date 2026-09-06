defmodule Shoestring.Elves.Classifier do
  @moduledoc """
  Pure classification of an Elf run's terminal state.

  Every terminal report is one of:

    * `:completed` — normal exit: the adapter returned a completed result and
      the OS process exited zero (or had already been reaped after the
      verdict).
    * `:interrupted` — the turn was deliberately stopped before completion
      (lease non-renewal at the safe boundary, or an adapter-level stop):
      the in-flight item completed, the turn was interrupted, and the work
      completed so far is preserved in durable evidence. Never a failure.
    * `:failed` — the run ended but the task did not succeed. Carries a stable
      `error_code` naming the cause: `task_failed`, `quota_refused`,
      `authentication_failed`, `incompatible_protocol`, `signal_exit`,
      `log_overflow`, `launch_failed`, `supervisor_crash`.
    * `:cancelled` — an explicit cancellation terminated the owned process
      group. Cancellation always wins over any concurrent exit: if the Elf
      asked for it, the run is cancelled, never "failed" and never
      "interrupted".

  An interrupted turn is never `task_failed`: the normalizer reports the
  interruption honestly as `result: %{status: "interrupted"}` (plus a
  `codex-app-server:interrupted` extension), and this mapping keys on that
  signal instead of inferring failure from a misleading status string.

  Inputs are adapter verdicts (`Shoestring.Harness.Error` categories and
  result statuses), raw OS exits, and Elf-side conditions (cancel requested,
  overflow, crash). The mapping is total: unknown inputs classify as failed
  with an explicit code, never as silent success.
  """

  @type terminal ::
          %{class: :completed}
          | %{class: :interrupted}
          | %{class: :failed, error_category: String.t(), error_code: String.t()}
          | %{class: :cancelled}

  @doc """
  Classifies an adapter terminal verdict. `verdict` is one of:

    * `{:result, status}` — the adapter's final result status string.
    * `{:error, %Shoestring.Harness.Error{}}` — a terminal adapter error.
    * `:no_verdict` — the adapter stream ended (or never produced) without a
      terminal verdict; classification falls back to the OS exit below.

  `os_exit` is `{:exit_status, non_neg_integer()}`, `:no_exit` (process still
  owned/alive), or `:unknown`. `cancel_requested?` forces `:cancelled`.

  The 4-arity variant additionally takes the count of observed adapter
  events (`observed_adapter_events`): a clean OS exit with no adapter
  verdict completes ONLY when at least one adapter event was observed.
  With zero observed events the launch never demonstrably began, so the
  run fails as `transport/no_adapter_events` instead of reporting a
  success it never witnessed. The 3-arity variant cannot tell the two
  cases apart and fails closed: without evidence of stream activity,
  success is never claimed.
  """
  @spec classify(term(), term(), boolean()) :: terminal()
  def classify(_verdict, _os_exit, true) do
    %{class: :cancelled}
  end

  def classify({:result, "completed"}, {:exit_status, 0}, false) do
    %{class: :completed}
  end

  def classify({:result, "completed"}, _os_exit, false) do
    # The adapter declared success; a ragged OS exit afterwards (or a group
    # that outlived the verdict and was reaped) does not rewrite success.
    %{class: :completed}
  end

  def classify({:result, "interrupted"}, _os_exit, false) do
    # A deliberately stopped turn: the boundary was honored, the in-flight
    # item completed, and the evidence is durable. This is never a failure,
    # and `result_accepted`-style mislabeling must not return here.
    %{class: :interrupted}
  end

  def classify({:result, status}, _os_exit, false) when is_binary(status) do
    %{class: :failed, error_category: "task_failed", error_code: "result_#{status}"}
  end

  def classify({:error, %Shoestring.Harness.Error{} = error}, _os_exit, false) do
    error_to_terminal(error)
  end

  # A clean OS exit with no adapter verdict is NOT a completion by itself:
  # without a single observed adapter event the launch never demonstrably
  # began, and reporting success would be a false durable claim (a run that
  # did nothing reported successful). Fail closed as
  # `transport/no_adapter_events`.
  #
  # The genuinely ambiguous case — events WERE streamed but no explicit
  # verdict arrived — stays deferred: `classify/4` with a positive observed
  # count completes, preserving the milestone's "completed, no final report"
  # eval (synthesizing a completion report from durable evidence is
  # orchestrator semantic judgment, deliberately deferred to the follow-up
  # that owns orchestrator-facing recovery decisions).
  # See `Shoestring.Elves.Staleness`.
  def classify(:no_verdict, {:exit_status, 0}, false) do
    %{class: :failed, error_category: "transport", error_code: "no_adapter_events"}
  end

  def classify(:no_verdict, {:exit_status, status}, false) when is_integer(status) do
    %{class: :failed, error_category: "transport", error_code: "signal_exit_#{status}"}
  end

  def classify(:no_verdict, _os_exit, false) do
    %{class: :failed, error_category: "transport", error_code: "missing_terminal_verdict"}
  end

  def classify(_verdict, _os_exit, false) do
    %{class: :failed, error_category: "transport", error_code: "unclassifiable_terminal"}
  end

  @doc """
  Classifies a `:no_verdict` clean OS exit with knowledge of how many
  adapter events were observed during the run.

  A positive count means the run streamed evidence and then ended without
  an explicit verdict — the genuinely ambiguous ending, still deferred to
  orchestrator-facing recovery as `:completed`. Zero means the launch
  never began observably — never `:completed`.
  """
  @spec classify(term(), term(), boolean(), non_neg_integer()) :: terminal()
  def classify(:no_verdict, {:exit_status, 0}, false, observed_adapter_events)
      when is_integer(observed_adapter_events) and observed_adapter_events > 0 do
    %{class: :completed}
  end

  def classify(:no_verdict, {:exit_status, 0}, false, _observed_adapter_events) do
    %{class: :failed, error_category: "transport", error_code: "no_adapter_events"}
  end

  def classify(verdict, os_exit, cancel_requested?, _observed_adapter_events) do
    classify(verdict, os_exit, cancel_requested?)
  end

  @doc "Terminal for an Elf-side overflow: oversized output fails the run, never truncates silently."
  @spec overflow() :: terminal()
  def overflow do
    %{class: :failed, error_category: "task_failed", error_code: "log_overflow"}
  end

  @doc "Terminal for a launch refusal: the adapter would not start."
  @spec launch_failed(String.t()) :: terminal()
  def launch_failed(code \\ "process_launch_failed") do
    %{class: :failed, error_category: "transport", error_code: code}
  end

  @doc "Terminal recorded by recovery when the Elf died without reporting."
  @spec supervisor_crash() :: terminal()
  def supervisor_crash do
    %{class: :failed, error_category: "transport", error_code: "supervisor_crash"}
  end

  @doc "Maps a terminal to the run lifecycle event type it must be reported with."
  @spec event_type(terminal()) :: String.t()
  def event_type(%{class: :completed}), do: "run.completed"
  def event_type(%{class: :interrupted}), do: "run.interrupted"
  def event_type(%{class: :cancelled}), do: "run.cancelled"
  def event_type(%{class: :failed}), do: "run.failed"

  @doc "Payload for the terminal run event (only `run.failed` carries error fields)."
  @spec event_payload(Ecto.UUID.t(), terminal()) :: map()
  def event_payload(run_id, %{class: :completed}), do: %{"run_id" => run_id}
  def event_payload(run_id, %{class: :interrupted}), do: %{"run_id" => run_id}
  def event_payload(run_id, %{class: :cancelled}), do: %{"run_id" => run_id}

  def event_payload(run_id, %{class: :failed} = terminal) do
    %{
      "run_id" => run_id,
      "error_category" => terminal.error_category,
      "error_code" => terminal.error_code
    }
  end

  # -- Private helpers --

  defp error_to_terminal(%Shoestring.Harness.Error{category: :quota_refused, code: code}) do
    %{class: :failed, error_category: "quota_refused", error_code: code}
  end

  defp error_to_terminal(%Shoestring.Harness.Error{
         category: :authentication_required,
         code: code
       }) do
    %{class: :failed, error_category: "authentication_required", error_code: code}
  end

  defp error_to_terminal(%Shoestring.Harness.Error{category: :schema_incompatible, code: code}) do
    %{class: :failed, error_category: "schema_incompatible", error_code: code}
  end

  defp error_to_terminal(%Shoestring.Harness.Error{category: :task_failed, code: code}) do
    %{class: :failed, error_category: "task_failed", error_code: code}
  end

  defp error_to_terminal(%Shoestring.Harness.Error{category: :cancelled}) do
    %{class: :cancelled}
  end

  defp error_to_terminal(%Shoestring.Harness.Error{category: category, code: code})
       when is_atom(category) and is_binary(code) do
    %{class: :failed, error_category: Atom.to_string(category), error_code: code}
  end
end
