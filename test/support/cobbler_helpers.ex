defmodule Shoestring.Test.CobblerHelpers do
  @moduledoc """
  Hermetic helpers for Cobbler command tests: goal creation, canonical
  `admission.decided` events appended through the standard trajectory
  boundary, and command attribute builders. No provider CLIs, no network,
  no execution.
  """

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.Goal

  import Ecto.Query

  @now ~U[2026-09-07 12:00:00.000000Z]

  @doc "Inserts a goal with a unique id and returns the struct."
  @spec create_goal!(module(), String.t()) :: Goal.t()
  def create_goal!(repo \\ Repo, title \\ "Cobbler goal") do
    %Goal{}
    |> Ecto.Changeset.change(%{
      id: Ecto.UUID.generate(),
      owner_id: Ecto.UUID.generate(),
      title: title,
      status: "active"
    })
    |> repo.insert!()
  end

  @doc "A valid `admission.decided` (v1) payload for the given intent, scope, and candidate."
  @spec admission_payload(keyword()) :: map()
  def admission_payload(opts \\ []) do
    intent = Keyword.get(opts, :intent, "supervised_execution")
    scope = Keyword.get(opts, :scope, "account:codex")
    provider_id = Keyword.get(opts, :provider_id, "codex")
    adapter_id = Keyword.get(opts, :adapter_id, "codex_app_server")

    %{
      "decision_id" => Keyword.get_lazy(opts, :decision_id, &Ecto.UUID.generate/0),
      "result" => "admit",
      "reason_code" => "automatic_admission_eligible",
      "explanation" => "Synthetic eligible admission for hermetic command tests",
      "requested_capability" => intent,
      "candidate" => %{
        "provider_id" => provider_id,
        "adapter_id" => adapter_id,
        "support_tier" => "proactive",
        "compatibility_state" => "compatible"
      },
      "scope" => scope,
      "observation" => %{
        "snapshot_id" => nil,
        "confidence" => "high",
        "freshness" => "fresh"
      },
      "policy" => %{"version" => 1},
      "proposed_bounds" => %{"response_budget" => 10, "tool_budget" => 25},
      "reobservation_required" => false,
      "evaluated_at" => DateTime.to_iso8601(@now)
    }
  end

  @doc "Appends one canonical admission.decided event through the trajectory boundary."
  @spec append_admission_event!(Ecto.UUID.t(), map() | nil) ::
          Shoestring.Trajectory.TrajectoryEvent.t()
  def append_admission_event!(goal_id, payload \\ nil) do
    payload = payload || admission_payload()

    {:ok, event} =
      Trajectory.append(goal_id, %{
        "type" => "admission.decided",
        "schema_version" => 1,
        "actor" => "cobbler",
        "occurred_at" => @now,
        "payload" => payload
      })

    event
  end

  @doc "Builds a task.claim command payload that matches the given admission event."
  @spec claim_command(Shoestring.Trajectory.TrajectoryEvent.t(), keyword()) :: map()
  def claim_command(admission_event, opts \\ []) do
    payload = admission_event.payload

    command_payload = %{
      "intent" => payload["requested_capability"],
      "scope" => payload["scope"],
      "candidate" => %{
        "provider_id" => payload["candidate"]["provider_id"],
        "adapter_id" => payload["candidate"]["adapter_id"]
      },
      "admission_event_id" => admission_event.id
    }

    command_id = Keyword.get_lazy(opts, :command_id, fn -> "cmd-" <> Ecto.UUID.generate() end)

    %{"type" => "task.claim", "command_id" => command_id, "payload" => command_payload}
  end

  @doc "Builds a task.release command payload."
  @spec release_command(String.t(), keyword()) :: map()
  def release_command(reason \\ "operator released", opts \\ []) do
    command_id = Keyword.get_lazy(opts, :command_id, fn -> "cmd-" <> Ecto.UUID.generate() end)

    %{"type" => "task.release", "command_id" => command_id, "payload" => %{"reason" => reason}}
  end

  @doc "Counts canonical trajectory events of the given types for a goal."
  @spec event_count(Ecto.UUID.t(), [String.t()]) :: non_neg_integer()
  def event_count(goal_id, types) do
    Repo.one!(
      from event in Shoestring.Trajectory.TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type in ^types,
        select: count()
    )
  end

  @doc "Fixed deterministic timestamp for hermetic tests."
  @spec now() :: DateTime.t()
  def now, do: @now
end
