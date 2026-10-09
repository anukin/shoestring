defmodule Shoestring.Cobbler.PlanBinding do
  @moduledoc false
  alias Shoestring.Cobbler.Plans

  @key "shoestring.plan:binding"
  def key, do: @key

  # Called inside the dispatch write transaction. Existing unplanned runs retain
  # their lifecycle; plan runs carry an immutable revision/digest binding.
  def authorize(repo, run) do
    with :ok <- Shoestring.Cobbler.ExecutionProfile.run_authority(repo, run) do
      with :ok <- authorize_plan(repo, run),
           do: Shoestring.Cobbler.PlanRunLineage.authorize(repo, run)
    end
  end

  defp authorize_plan(repo, run) do
    case (run.extensions || %{})[@key] do
      nil ->
        :ok

      %{"revision_number" => number, "plan_digest" => digest} ->
        with %{} = authority <- Plans.authority(run.goal_id, repo: repo),
             true <-
               authority.revision.revision_number == number and
                 authority.revision.digest == digest do
          :ok
        else
          _ -> {:error, :plan_authority_changed}
        end

      _ ->
        {:error, :invalid_plan_binding}
    end
  end

  def transaction_check(repo, run) do
    case authorize(repo, run) do
      :ok -> {:ok, :authorized}
      error -> error
    end
  end
end
