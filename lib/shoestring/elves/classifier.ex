defmodule Shoestring.Elves.Classifier do
  @moduledoc """
  Pure classification of an Elf run's terminal state.

  Every terminal report is one of:

    * `:completed` — normal exit: the adapter returned a completed result and
      the OS process exited zero (or had already been reaped after the
      verdict).
    * `:failed` — the run ended but the task did not succeed. Carries a stable
      `error_code` naming the cause: `task_failed`, `quota_refused`,
      `authentication_failed`, `incompatible_protocol`, `signal_exit`,
      `log_overflow`, `launch_failed`, `supervisor_crash`.
    * `:cancelled` — an explicit cancellation terminated the owned process
      group. Cancellation always wins over any concurrent exit: if the Elf
      asked for it, the run is cancelled, never "failed".

  Inputs are adapter verdicts (`Shoestring.Harness.Error` categories and
  result statuses), raw OS exits, and Elf-side conditions (cancel requested,
  overflow, crash). The mapping is total: unknown inputs classify as failed
  with an explicit code, never as silent success.
  """

  @type terminal ::
          %{class: :completed}
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

  def classify({:result, status}, _os_exit, false) when is_binary(status) do
    %{class: :failed, error_category: "task_failed", error_code: "result_#{status}"}
  end

  def classify({:error, %Shoestring.Harness.Error{} = error}, _os_exit, false) do
    error_to_terminal(error)
  end

  # A clean OS exit with no adapter verdict completes for now. This is the
  # conservative placeholder for the milestone's "completed, no final report"
  # eval: synthesizing a completion report from durable evidence (commit +
  # passing tests, but the final response omitted) is orchestrator semantic
  # judgment and is deliberately deferred to the follow-up that owns
  # orchestrator-facing recovery decisions. See `Shoestring.Elves.Staleness`.
  def classify(:no_verdict, {:exit_status, 0}, false) do
    %{class: :completed}
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
  def event_type(%{class: :cancelled}), do: "run.cancelled"
  def event_type(%{class: :failed}), do: "run.failed"

  @doc "Payload for the terminal run event (only `run.failed` carries error fields)."
  @spec event_payload(Ecto.UUID.t(), terminal()) :: map()
  def event_payload(run_id, %{class: :completed}), do: %{"run_id" => run_id}
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
