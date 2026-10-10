defmodule Shoestring.Cobbler.Planner.Amendment do
  @moduledoc "Bounded, canonical amendment context and preservation rules for model proposals."
  import Ecto.Query
  alias Shoestring.Cobbler.{PlanContract, Plans}
  alias Shoestring.Cobbler.Planner.Projection
  alias Shoestring.Harness.Contract
  alias Shoestring.Trajectory.TrajectoryEvent

  def build(repo, goal_id, attrs) do
    with number when is_integer(number) and number > 0 <- attrs[:revision_number],
         digest when is_binary(digest) <- attrs[:digest],
         revision when not is_nil(revision) <-
           Plans.get_revision(goal_id, number, repo: repo),
         true <- revision.digest == attrs[:digest],
         {:ok, contract} <- PlanContract.new(revision.content),
         true <- contract.digest == revision.digest,
         {:ok, reason} <- Contract.text(attrs[:reason], :reason, max: 500),
         {:ok, projection} <-
           Projection.build(repo, goal_id, %{
             requested_by: attrs[:requested_by],
             goal_contract: contract.content["goal"]
           }) do
      events =
        repo.all(
          from e in TrajectoryEvent,
            where: e.goal_id == ^goal_id,
            order_by: [asc: e.sequence]
        )

      evidence =
        events
        |> Enum.filter(
          &(&1.type in [
              "checkpoint.created",
              "cobbler.plan.task.accepted",
              "cobbler.plan.task.gate_failed"
            ])
        )
        |> Enum.take(-15)
        |> Enum.map(&Projection.summarize_event/1)

      projection =
        projection
        |> Map.put("source_context_refs", Enum.map(evidence, & &1["reference"]))
        |> Map.put("evidence_summaries", %{"items" => evidence})
        |> Map.put("amendment", %{
          "revision_number" => revision.revision_number,
          "plan_digest" => revision.digest,
          "reason" => reason,
          "current_plan_json" => PlanContract.canonical_json(contract),
          "accepted_task_ids" => accepted_ids(events)
        })

      with :ok <- Projection.validate(projection), do: {:ok, projection}
    else
      _ -> {:error, :invalid_amendment_request}
    end
  end

  def matches_request?(row, attrs) do
    a = row.projection["amendment"]

    reason =
      case Contract.text(attrs[:reason], :reason, max: 500) do
        {:ok, reason} -> reason
        _ -> nil
      end

    is_map(a) and row.request_key == attrs[:request_key] and
      row.projection["requested_by"] == attrs[:requested_by] and
      a["revision_number"] == attrs[:revision_number] and a["plan_digest"] == attrs[:digest] and
      a["reason"] == reason
  end

  def authorize_parent(goal_id, projection) do
    %{"revision_number" => number, "plan_digest" => digest} = projection["amendment"]

    case Plans.authority(goal_id) do
      %{revision_number: ^number, digest: ^digest} -> :ok
      _ -> {:error, :amendment_parent_changed}
    end
  end

  def valid_projection?(projection) do
    case projection["amendment"] do
      nil ->
        true

      a when is_map(a) ->
        with true <-
               Enum.sort(Map.keys(a)) ==
                 Enum.sort(
                   ~w(revision_number plan_digest reason current_plan_json accepted_task_ids)
                 ),
             true <- is_integer(a["revision_number"]) and a["revision_number"] > 0,
             {:ok, _} <- Contract.text(a["reason"], :reason, max: 500),
             {:ok, contract} <- PlanContract.from_canonical_json(a["current_plan_json"]),
             true <-
               contract.digest == a["plan_digest"] and
                 contract.content["goal"] == projection["goal_contract"],
             ids when is_list(ids) <- a["accepted_task_ids"],
             true <-
               ids == Enum.sort(Enum.uniq(ids)) and
                 Enum.all?(ids, &(&1 in PlanContract.task_ids(contract))) do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  def valid_history?(projection, events, sequence) do
    a = projection["amendment"]
    prior = Enum.filter(events, &(&1.sequence < sequence))
    approved = prior |> Enum.filter(&(&1.type == "cobbler.plan.approved")) |> List.last()

    revision =
      Enum.find(
        prior,
        &(&1.type == "cobbler.plan.revision.created" and
            &1.payload["revision_number"] == a["revision_number"])
      )

    not is_nil(approved) and not is_nil(revision) and
      Enum.count(prior, &(&1.type == "cobbler.plan.execution.requested")) < 2 and
      approved.payload["revision_number"] == a["revision_number"] and
      approved.payload["plan_digest"] == a["plan_digest"] and
      revision.payload["plan_content"] == a["current_plan_json"] and
      accepted_ids(prior) == a["accepted_task_ids"]
  end

  # A model can revise unfinished work but cannot erase identities, rewrite
  # accepted contracts or author retirements. Retirement remains a human edit.
  def output_allowed?(contract, projection) do
    case projection["amendment"] do
      nil ->
        PlanContract.retirements(contract) == []

      a ->
        {:ok, parent} = PlanContract.from_canonical_json(a["current_plan_json"])
        original = Map.new(parent.content["tasks"], &{&1["id"], &1})
        incoming = Map.new(contract.content["tasks"], &{&1["id"], &1})

        preserved =
          a["accepted_task_ids"] ++ Enum.map(PlanContract.retirements(parent), & &1["task_id"])

        Enum.all?(Map.keys(original), &Map.has_key?(incoming, &1)) and
          Enum.all?(preserved, &(incoming[&1] == original[&1])) and
          Map.get(contract.content, "retirements") == Map.get(parent.content, "retirements")
    end
  end

  defp accepted_ids(events),
    do:
      events
      |> Enum.filter(&(&1.type == "cobbler.plan.task.accepted"))
      |> Enum.map(& &1.payload["plan_task_id"])
      |> Enum.uniq()
      |> Enum.sort()
end
