defmodule Shoestring.Harness.HTTP do
  @moduledoc "Common durable text-only HTTP lifecycle. No subscription-capacity fiction or repository tools."
  alias Shoestring.{ApiSpend, Repo}
  alias Shoestring.Harness.{Error, RunIdentity, RunRecord}
  alias Shoestring.Harness.HTTP.{Call, Providers, Session}

  def start(provider, request, opts) do
    now = Shoestring.Harness.Clock.now(Map.get(opts, :clock, Shoestring.Harness.SystemClock))

    with true <-
           is_nil(request.continuation) and request.policy["write_access"] != true and
             request.policy[:write_access] != true and
             request.requested_capabilities -- [:cancel] == [],
         {:ok, config} <- Providers.configuration(provider, now),
         {:ok, run_id} <- claim(provider, request),
         {:ok, quote} <- reserve(provider, request, now),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(
             Shoestring.Harness.HTTP.Sessions,
             {Session,
              run_id: run_id,
              request: request,
              provider: provider,
              config: config,
              quote: quote,
              owner: self(),
              adapter_opts: opts}
           ) do
      RunIdentity.new(%{run_id: run_id, harness_id: provider})
    else
      {:error, reason} ->
        code =
          if reason in [
               :http_run_not_owned,
               :http_plan_tools_unsupported,
               :http_call_already_claimed,
               :api_disabled,
               :api_zero_cap,
               :api_cap_exceeded,
               :api_call_already_reserved,
               :api_policy_not_compatible,
               :local_execution_not_configured
             ], do: Atom.to_string(reason), else: "http_dispatch_refused"

        {:error,
         Error.new(
           :quota_refused,
           code,
           "Text execution requires a valid owned request and explicit operator policy."
         )}

      _ ->
        {:error,
         Error.new(
           :quota_refused,
           "http_dispatch_refused",
           "Text execution is disabled, unsupported, already claimed, or outside its configured budget."
         )}
    end
  end

  defp claim(provider, request) do
    Repo.transaction(
      fn ->
        run =
          Repo.get_by(RunRecord,
            dispatch_id: request.dispatch_id,
            goal_id: request.goal_id,
            task_id: request.task_id,
            workspace_ref: request.workspace_ref
          )

        if is_nil(run) or run.provider_id != provider or run.prompt != request.prompt or
             Shoestring.Cobbler.PlanContract.canonical_json(run.policy) !=
               Shoestring.Cobbler.PlanContract.canonical_json(request.policy),
           do: Repo.rollback(:http_run_not_owned)

        if run.extensions[Shoestring.Cobbler.ExecutionProfile.key()] != nil,
          do: Repo.rollback(:http_plan_tools_unsupported)

        if Repo.get(Call, request.dispatch_id), do: Repo.rollback(:http_call_already_claimed)

        Repo.insert!(%Call{
          id: request.dispatch_id,
          run_id: run.id,
          provider: provider,
          status: "started"
        })

        run.id
      end,
      mode: :immediate
    )
  end

  defp reserve("openai_responses", request, now) do
    case ApiSpend.reserve(request, now: now) do
      {:ok, row} -> {:ok, Map.put(row.pricing, "maximum_reserved_microusd", row.maximum_microusd)}
      error -> error
    end
  end

  defp reserve(_, _, _), do: {:ok, nil}

  def stream(identity), do: safely(fn -> Session.events(identity.run_id) end)
  def cancel(identity), do: safely(fn -> Session.cancel(identity.run_id) end)
  def status(identity), do: safely(fn -> Session.status(identity.run_id) end)

  def release(identity) do
    case Registry.lookup(Shoestring.Harness.HTTP.Registry, identity.run_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Shoestring.Harness.HTTP.Sessions, pid)
      _ -> :ok
    end
  end

  defp safely(fun) do
    fun.()
  catch
    :exit, _ ->
      {:error,
       Error.new(:transport, "http_session_unavailable", "No replacement request was started.")}
  end
end
