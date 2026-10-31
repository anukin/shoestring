defmodule Shoestring.Repo.Migrations.CreateAgents do
  @moduledoc """
  Reusable agents (iteration 16 package T): one row per agent, which teams
  (`agent_definitions`) compose by naming it in a role (`roles[].agent_id`).

  Every existing role becomes an agent, roles with the same job, provider,
  model and effort sharing one, and names it. Saved team revisions are left
  as they are: their digests, which running work is pinned to, stay valid.
  """
  use Ecto.Migration

  import Ecto.Query

  def up do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :kind, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :effort, :string
      add :notes, :text
      add :max_minutes, :integer
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:slug])
    flush()

    now = DateTime.utc_now()
    teams = repo().all(from(d in "agent_definitions", select: %{id: d.id, roles: d.roles}))

    Enum.reduce(teams, %{}, fn team, agents ->
      {roles, agents} =
        team.roles
        |> decode()
        |> Enum.map_reduce(agents, fn role, agents ->
          key = {kind(role["name"]), role["provider"], role["model"], role["effort"]}

          case agents do
            %{^key => id} ->
              {Map.put(role, "agent_id", id), agents}

            _ ->
              id = insert!(key, now)
              {Map.put(role, "agent_id", id), Map.put(agents, key, id)}
          end
        end)

      repo().query!("UPDATE agent_definitions SET roles = ? WHERE id = ?", [
        Jason.encode!(roles),
        team.id
      ])

      agents
    end)
  end

  def down do
    for team <- repo().all(from(d in "agent_definitions", select: %{id: d.id, roles: d.roles})) do
      roles = team.roles |> decode() |> Enum.map(&Map.delete(&1, "agent_id"))

      repo().query!("UPDATE agent_definitions SET roles = ? WHERE id = ?", [
        Jason.encode!(roles),
        team.id
      ])
    end

    drop table(:agents)
  end

  defp decode(roles) when is_binary(roles), do: Jason.decode!(roles)
  defp decode(roles) when is_list(roles), do: roles

  defp kind("Coordinator"), do: "coordinator"
  defp kind("Explorer"), do: "explorer"
  defp kind("Reviewer"), do: "reviewer"
  defp kind(_worker), do: "implementer"

  defp insert!({kind, provider, model, effort}, now) do
    id = Ecto.UUID.generate()

    name =
      "#{String.capitalize(kind)} · #{provider}:#{model}" <>
        if(effort, do: " (#{effort})", else: "")

    base =
      "#{kind}-#{provider}-#{model}#{if effort, do: "-#{effort}", else: ""}"
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 50)
      |> String.trim("-")

    slug = Enum.find([base | Enum.map(2..99, &"#{base}-#{&1}")], &(not taken?(&1)))

    repo().query!(
      "INSERT INTO agents (id, name, slug, kind, provider, model, effort, lock_version, " <>
        "inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)",
      [id, String.slice(name, 0, 60), slug, kind, provider, model, effort, now, now]
    )

    id
  end

  defp taken?(slug),
    do: repo().one(from(a in "agents", where: a.slug == ^slug, select: count())) > 0
end
