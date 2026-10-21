defmodule Shoestring.Test.ApiSpendHelpers do
  @moduledoc "Synthetic durable API intents; never sends an API request."
  alias Shoestring.Harness.{RunRecord, RunRequest}
  alias Shoestring.Trajectory.{Goal, Task}

  def request!(repo) do
    goal =
      %Goal{id: Ecto.UUID.generate(), owner_id: Ecto.UUID.generate()}
      |> Goal.changeset(%{"title" => "API spend fixture"})
      |> repo.insert!()

    task =
      %Task{id: Ecto.UUID.generate(), goal_id: goal.id}
      |> Task.changeset(%{"title" => "Text-only fixture"})
      |> repo.insert!()

    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: goal.id,
        task_id: task.id,
        dispatch_id: Ecto.UUID.generate(),
        workspace_ref: "workspace/fixture",
        prompt: "Synthetic bounded completion",
        policy: %{mode: "supervised"},
        continuation: nil,
        requested_capabilities: [],
        extensions: %{}
      })

    run =
      %RunRecord{id: Ecto.UUID.generate()}
      |> RunRecord.intent_changeset(request, "openai_responses", ~U[2026-10-20 12:00:00.000000Z])
      |> repo.insert!()

    {request, run}
  end

  def config do
    %{
      enabled: true,
      monthly_cap_microusd: 1_000_000,
      model: "gpt-6-luna",
      accepted_price_version: Shoestring.ApiSpend.Pricing.version(),
      max_output_tokens: 4096
    }
  end
end
