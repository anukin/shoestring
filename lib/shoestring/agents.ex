defmodule Shoestring.Agents do
  @moduledoc """
  Reusable agents (iteration 16 package T). An agent is one job done one
  way: a coordinator, explorer, implementer or reviewer, with its model,
  effort and the most one of its dispatches may take (none by default).

  Teams (`Shoestring.AgentProfiles`, the saved "agents" of earlier
  iterations) compose agents: each role names one (`agent_id`) and takes its
  model and effort from it. Editing an agent saves a new revision of every
  team that uses it, so the change reaches them all while work already
  running stays pinned to the revision it started with.

  A team role's stored name keeps its earlier spelling: the implementer is
  "Worker", which runs recorded before this iteration resolve by.
  """
  import Ecto.Query

  alias Shoestring.{AgentProfiles, Repo}
  alias Shoestring.Agents.Agent
  alias Shoestring.AgentProfiles.Definition

  @labels %{
    "coordinator" => "Coordinator",
    "explorer" => "Explorer",
    "implementer" => "Implementer",
    "reviewer" => "Reviewer"
  }
  @role_names %{
    "coordinator" => "Coordinator",
    "explorer" => "Explorer",
    "implementer" => "Worker",
    "reviewer" => "Reviewer"
  }

  def kinds, do: Agent.kinds()

  @doc "What a person calls an agent of `kind`."
  def label(kind), do: Map.fetch!(@labels, kind)

  @doc "The team role name an agent of `kind` fills."
  def role_name(kind), do: Map.fetch!(@role_names, kind)

  @doc "The kind of agent a team role named `name` takes."
  def kind_of("Coordinator"), do: "coordinator"
  def kind_of("Explorer"), do: "explorer"
  def kind_of("Reviewer"), do: "reviewer"
  def kind_of(_worker_implementer_or_custom), do: "implementer"

  def list, do: Repo.all(from a in Agent, order_by: [a.kind, a.name, a.id])
  def get(id) when is_binary(id), do: Repo.get(Agent, id)
  def get(_id), do: nil
  def get_by_slug(slug), do: Repo.get_by(Agent, slug: slug)

  def change(agent, attrs \\ %{}),
    do: Agent.changeset(agent, attrs, AgentProfiles.catalog())

  def create(attrs), do: attrs |> then(&change(%Agent{}, &1)) |> Repo.insert()

  @doc """
  Saves `agent` and a new revision of every team that uses it, in one
  transaction.
  """
  def update(%Agent{} = agent, attrs) do
    Repo.transaction(fn ->
      with {:ok, agent} <-
             change(agent, attrs)
             |> Ecto.Changeset.optimistic_lock(:lock_version)
             |> Repo.update(
               stale_error_field: :lock_version,
               stale_error_message: "agent changed; reload before saving"
             ),
           :ok <- refresh_teams(agent) do
        agent
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp refresh_teams(agent) do
    agent
    |> used_by()
    |> Enum.reduce_while(:ok, fn team, :ok ->
      roles = Enum.map(team.roles, &Map.take(Map.from_struct(&1), [:name, :agent_id]))

      case AgentProfiles.update(team, %{"roles" => roles}) do
        {:ok, _team} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, {:team, team.slug, changeset}}}
      end
    end)
  end

  @doc "The teams with a role that names `agent`."
  def used_by(%Agent{id: id}) do
    Repo.all(from d in Definition, order_by: [d.name, d.slug])
    |> Enum.filter(fn team -> Enum.any?(team.roles, &(&1.agent_id == id)) end)
  end

  @doc """
  The agent of `kind` with exactly this provider, model and effort, created
  when there is none: how a role saved without naming an agent gets one.
  """
  def ensure(kind, provider, model, effort) do
    query =
      from a in Agent,
        where: a.kind == ^kind and a.provider == ^provider and a.model == ^model,
        order_by: [a.inserted_at, a.id],
        limit: 1

    query =
      if effort,
        do: where(query, [a], a.effort == ^effort),
        else: where(query, [a], is_nil(a.effort))

    existing = Repo.one(query)

    case existing do
      %Agent{} = agent ->
        {:ok, agent}

      nil ->
        create(%{
          "name" =>
            "#{label(kind)} · #{provider}:#{model}" <> if(effort, do: " (#{effort})", else: ""),
          "slug" => free_slug("#{kind}-#{provider}-#{model}#{if effort, do: "-#{effort}"}"),
          "kind" => kind,
          "provider" => provider,
          "model" => model,
          "effort" => effort
        })
    end
  end

  defp free_slug(text) do
    base =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 50)
      |> String.trim("-")

    Enum.find([base | Enum.map(2..999, &"#{base}-#{&1}")], &is_nil(get_by_slug(&1)))
  end

  # -- A session's team ----------------------------------------------------

  @purpose_kind %{"explore" => "explorer", "implement" => "implementer", "review" => "reviewer"}

  @doc "The kind of agent that does dispatches of `purpose`."
  def purpose_kind(purpose), do: Map.get(@purpose_kind, purpose)

  @doc """
  What a session records of `team` when it starts (on its grant): each role's
  agent, its model and its limit. Later edits of the agents do not change a
  session already started.
  """
  def snapshot(%Definition{} = team) do
    agents =
      for role <- team.roles, agent = get(role.agent_id), agent != nil do
        %{
          "role" => role.name,
          "slug" => agent.slug,
          "name" => agent.name,
          "kind" => agent.kind,
          "provider" => agent.provider,
          "model" => agent.model,
          "effort" => agent.effort,
          "max_minutes" => agent.max_minutes
        }
      end

    %{
      "team" => team.slug,
      "profile_id" => team.id,
      "revision" => team.revision,
      "agents" => agents
    }
  end

  @doc """
  The agent of a session's `team` (a `snapshot/1`) a dispatch names: by slug,
  or by its job (`explorer`, `implementer` or `worker`, `reviewer`). nil when
  there is none.
  """
  def find(team, name) when is_map(team) and is_binary(name) do
    wanted = String.downcase(String.trim(name))
    wanted = if wanted == "worker", do: "implementer", else: wanted

    Enum.find(team["agents"] || [], &(&1["slug"] == wanted)) ||
      Enum.find(team["agents"] || [], &(&1["kind"] == wanted and &1["kind"] != "coordinator"))
  end

  def find(_team, _name), do: nil

  @doc """
  The agent of a session's `team` a dispatch of `purpose` on
  `provider:model` is for, so its limit applies however it was named; nil
  when the team has none.
  """
  def for_dispatch(team, purpose, provider, model) when is_map(team) do
    kind = purpose_kind(purpose)

    Enum.find(
      team["agents"] || [],
      &(&1["kind"] == kind and &1["provider"] == provider and &1["model"] == model)
    )
  end

  def for_dispatch(_team, _purpose, _provider, _model), do: nil
end
