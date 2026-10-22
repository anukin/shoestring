defmodule Shoestring.Harness.HTTP.Session do
  @moduledoc "Owned one-shot HTTP task and bounded live normalized buffer. Never restarts inference."
  use GenServer, restart: :temporary
  import Ecto.Query
  alias Shoestring.{ApiSpend, Repo}
  alias Shoestring.Harness.{Error, HarnessEvent, Security}
  alias Shoestring.Harness.HTTP.{Call, Providers}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:run_id]))
  def via(id), do: {:via, Registry, {Shoestring.Harness.HTTP.Registry, id}}
  def events(id), do: GenServer.call(via(id), :events)
  def await(id), do: GenServer.call(via(id), :await, :infinity)
  def cancel(id), do: GenServer.call(via(id), :cancel)
  def status(id), do: GenServer.call(via(id), :status)

  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Process.monitor(opts[:owner])

    task =
      Task.Supervisor.async(Shoestring.Harness.HTTP.Tasks, fn ->
        try do
          Providers.execute(
            opts[:provider],
            opts[:request],
            opts[:config],
            opts[:adapter_opts],
            opts[:quote]
          )
        rescue
          _ -> {:error, :http_transport_uncertain, nil}
        catch
          _, _ -> {:error, :http_transport_uncertain, nil}
        end
      end)

    state = %{
      id: opts[:run_id],
      request: opts[:request],
      provider: opts[:provider],
      task: task,
      owner: owner,
      events: [],
      status: "running",
      waiters: [],
      call_id: opts[:request].dispatch_id,
      clock: Map.get(opts[:adapter_opts], :clock, Shoestring.Harness.SystemClock),
      evidence: evidence(opts)
    }

    {:ok, add_event(state, :lifecycle, %{})}
  end

  def handle_call(:events, _, state), do: {:reply, {:ok, state.events}, state}
  def handle_call(:status, _, state), do: {:reply, {:ok, %{status: state.status}}, state}

  def handle_call(:await, from, %{status: "running"} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:await, _, state), do: {:reply, {:ok, state.events}, state}

  def handle_call(:cancel, _, %{status: "running"} = state) do
    Task.Supervisor.terminate_child(Shoestring.Harness.HTTP.Tasks, state.task.pid)
    {:reply, {:ok, :cancelled}, finish(state, {:error, :cancelled, nil})}
  end

  def handle_call(:cancel, _, state), do: {:reply, {:ok, :cancelled}, state}

  def handle_info({ref, result}, %{task: %{ref: ref}, status: "running"} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}, status: "running"} = state),
    do: {:noreply, finish(state, {:error, :http_transport_uncertain, nil})}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, %{status: "running"} = state) do
    Task.Supervisor.terminate_child(Shoestring.Harness.HTTP.Tasks, state.task.pid)
    uncertain(state)
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_, _), do: :ok

  defp finish(state, result) do
    state =
      try do
        finish_result(state, result)
      rescue
        _ ->
          uncertain(state)
          terminal_error(state, :http_transport_uncertain)
      catch
        _, _ ->
          uncertain(state)
          terminal_error(state, :http_transport_uncertain)
      end

    try do
      Repo.update_all(from(c in Call, where: c.id == ^state.call_id), set: [status: state.status])
    rescue
      _ -> :ok
    end

    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, state.events}))
    %{state | waiters: []}
  end

  defp finish_result(state, {:ok, text, usage}) when is_binary(text) do
    settled = settle(state, usage)

    with true <- settled and String.valid?(text) and byte_size(text) in 1..65_536,
         false <- Regex.match?(~r/<\/?(?:think|analysis|reasoning)>/i, text),
         {:ok, artifact} <-
           Shoestring.Trajectory.ArtifactStore.put(
             state.request.goal_id,
             Security.redact_retained(text),
             %{media_type: "text/plain", redacted: true},
             task_id: state.request.task_id
           ) do
      state
      |> add_event(:artifact, %{artifact_id: artifact.id})
      |> add_event(:result, %{result: %{status: "completed", artifact_id: artifact.id}})
      |> Map.put(:status, "completed")
    else
      _ -> terminal_error(state, :http_output_or_usage_invalid)
    end
  end

  defp finish_result(state, {:error, reason, usage}) do
    _ = settle(state, usage)
    terminal_error(state, reason)
  end

  defp finish_result(state, _) do
    uncertain(state)
    terminal_error(state, :http_transport_uncertain)
  end

  defp settle(%{provider: "openai_responses"} = state, usage) do
    case ApiSpend.reconcile(state.call_id, usage, now: Shoestring.Harness.Clock.now(state.clock)) do
      {:ok, %{status: "reconciled"}} -> true
      _ -> false
    end
  end

  defp settle(_, _), do: true
  defp uncertain(%{provider: "openai_responses"} = state), do: ApiSpend.unresolved(state.call_id)
  defp uncertain(_), do: :ok

  defp terminal_error(state, reason) do
    {category, code} =
      case reason do
        :authentication_required ->
          {:authentication_required, "http_authentication_required"}

        :quota_refused ->
          {:quota_refused, "http_quota_refused"}

        :cancelled ->
          {:cancelled, "http_request_cancelled"}

        reason
        when reason in [
               :http_output_or_usage_invalid,
               :http_schema_incompatible,
               :local_model_not_verified,
               :http_incomplete,
               :http_response_oversized,
               :http_transport_uncertain
             ] ->
          {:transport, Atom.to_string(reason)}

        _ ->
          {:transport, "http_request_failed_or_uncertain"}
      end

    state
    |> add_event(:error, %{
      error: Error.new(category, code, "Text request did not produce a verified completion.")
    })
    |> Map.put(:status, if(reason == :cancelled, do: "cancelled", else: "failed"))
  end

  defp add_event(state, kind, fields) do
    ordinal = length(state.events) + 1

    {:ok, event} =
      HarnessEvent.new(
        Map.merge(
          %{
            version: 1,
            run_id: state.id,
            source_event_id: "http:#{state.id}:#{ordinal}",
            ordinal: ordinal,
            occurred_at: Shoestring.Harness.Clock.now(state.clock),
            kind: kind,
            extensions: state.evidence
          },
          fields
        )
      )

    %{state | events: state.events ++ [event]}
  end

  defp evidence(opts) do
    if opts[:provider] == "openai_responses" do
      %{
        "http:provider" => opts[:provider],
        "http:pricing_version" => opts[:quote]["version"],
        "http:reserved_microusd" => opts[:quote]["maximum_reserved_microusd"],
        "http:model" => opts[:quote]["model"],
        "http:output_token_limit" => opts[:quote]["output_token_limit"]
      }
    else
      %{
        "http:provider" => opts[:provider],
        "http:cost_basis" => "local_compute_context_and_time",
        "http:model" => opts[:config][:model],
        "http:context_limit" => opts[:config][:context_tokens],
        "http:output_token_limit" => opts[:config][:max_output_tokens]
      }
    end
  end
end
