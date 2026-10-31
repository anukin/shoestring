defmodule Shoestring.AgentProfiles do
  @moduledoc "Durable configuration and immutable revision lookup. Saving does not execute work."
  import Ecto.Query
  alias Shoestring.Repo
  alias Shoestring.AgentProfiles.{Definition, Revision, Role, Settings}

  def list, do: Repo.all(from a in Definition, order_by: [a.name, a.id])
  def get(id), do: Repo.get(Definition, id)
  def get_by_slug(slug), do: Repo.get_by(Definition, slug: slug)
  def settings, do: Repo.get!(Settings, 1)

  def catalog do
    settings = settings()

    %{
      "claude" => Settings.model_ids(settings.claude_models),
      "codex" => Settings.model_ids(settings.codex_models),
      "opencode" => Settings.model_ids(settings.opencode_models)
    }
  end

  # Explicit reasoning effort per provider CLI. A role without one runs at the
  # provider's own default, which the role cannot pin. Claude 2.1.309 lists
  # these values for `--effort`; Codex turn/start takes a model-advertised
  # value, so only the widely advertised levels are offered. opencode's effort
  # values differ per model (iteration 13 preflight), so it has no stable set
  # and a role cannot pin one.
  @efforts %{
    "claude" => ~w(low medium high xhigh max),
    "codex" => ~w(low medium high xhigh),
    "opencode" => []
  }

  def efforts, do: @efforts

  @doc """
  The efforts a role may pin for `model`: the ones its harness reported in
  its last listing, otherwise the provider's set above.
  """
  def efforts(provider, model),
    do: Shoestring.ModelCatalog.efforts(provider, model) || Map.get(@efforts, provider, [])

  def template do
    catalog = catalog()

    %Definition{
      roles:
        Enum.map(
          [{"Coordinator", "claude"}, {"Worker", "codex"}, {"Reviewer", "claude"}],
          fn {name, provider} ->
            %Role{name: name, provider: provider, model: hd(catalog[provider])}
          end
        )
    }
  end

  @doc """
  A team's changeset. A role naming an agent (`agent_id`,
  `Shoestring.Agents`) takes that agent's provider, model and effort.
  """
  def change(agent, attrs \\ %{}),
    do: Definition.changeset(agent, map_roles(attrs, &from_agent/1), catalog())

  @doc """
  Saves a new team. Each role names an agent; a role given as a provider and
  model instead is linked to the agent of its job with exactly those (made
  when there is none).
  """
  def create(attrs) do
    Repo.transaction(fn ->
      case persist(change(%Definition{}, map_roles(attrs, &link/1)), :insert) do
        {:ok, team} -> team
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def update(agent, attrs) do
    Repo.transaction(fn ->
      changeset =
        agent |> change(map_roles(attrs, &link/1)) |> Ecto.Changeset.optimistic_lock(:revision)

      case persist(changeset, :update) do
        {:ok, team} -> team
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # `attrs`' roles, as a list or as a form's index map, each mapped by `fun`.
  defp map_roles(attrs, fun) when is_map(attrs) do
    {key, roles} =
      cond do
        Map.has_key?(attrs, "roles") -> {"roles", attrs["roles"]}
        Map.has_key?(attrs, :roles) -> {:roles, attrs[:roles]}
        true -> {nil, nil}
      end

    case roles do
      list when is_list(list) ->
        Map.put(attrs, key, Enum.map(list, &role_attrs(&1, fun)))

      %{} = indexed ->
        Map.put(attrs, key, Map.new(indexed, fn {i, role} -> {i, role_attrs(role, fun)} end))

      _ ->
        attrs
    end
  end

  defp map_roles(attrs, _fun), do: attrs

  defp role_attrs(%Role{} = role, fun), do: role |> Map.from_struct() |> role_attrs(fun)

  defp role_attrs(role, fun) when is_map(role),
    do: role |> Map.new(fn {k, v} -> {to_string(k), v} end) |> fun.()

  defp role_attrs(role, _fun), do: role

  defp from_agent(%{"agent_id" => id} = role) when is_binary(id) and id != "" do
    case Shoestring.Agents.get(id) do
      nil ->
        role

      agent ->
        Map.merge(role, %{
          "provider" => agent.provider,
          "model" => agent.model,
          "effort" => agent.effort,
          "agent_kind" => agent.kind
        })
    end
  end

  defp from_agent(role), do: role

  defp link(%{"agent_id" => id} = role) when is_binary(id) and id != "", do: role

  defp link(%{"name" => name, "provider" => provider, "model" => model} = role)
       when is_binary(name) and is_binary(provider) and is_binary(model) do
    effort = if role["effort"] in [nil, ""], do: nil, else: role["effort"]

    case Shoestring.Agents.ensure(Shoestring.Agents.kind_of(name), provider, model, effort) do
      {:ok, agent} -> Map.put(role, "agent_id", agent.id)
      {:error, _invalid} -> role
    end
  end

  defp link(role), do: role

  def change_settings(settings, attrs \\ %{}) do
    settings
    |> Settings.changeset(attrs)
    |> Ecto.Changeset.validate_change(:default_agent_id, fn field, id ->
      if get(id), do: [], else: [{field, "choose an existing agent"}]
    end)
  end

  def save_settings(settings, attrs) do
    settings
    |> change_settings(attrs)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(
      stale_error_field: :lock_version,
      stale_error_message: "settings changed; reload before saving"
    )
  end

  def snapshot(slug, number \\ nil) do
    case get_by_slug(slug) do
      nil -> {:error, :not_found}
      agent -> snapshot_by_id(agent.id, number)
    end
  end

  def default_snapshot(number \\ nil) do
    case settings().default_agent_id do
      nil -> {:error, :no_default}
      id -> snapshot_by_id(id, number)
    end
  end

  def snapshot_by_id(id, number \\ nil) do
    with %Definition{} = agent <- get(id),
         %Revision{} = revision <-
           Repo.get_by(Revision, definition_id: id, number: number || agent.revision) do
      {:ok,
       %{
         "profile_id" => id,
         "revision" => revision.number,
         "digest" => revision.digest,
         "configuration" => revision.configuration
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp persist(changeset, operation) do
    Repo.transaction(fn ->
      result =
        case operation do
          :insert ->
            Repo.insert(changeset)

          :update ->
            Repo.update(changeset,
              stale_error_field: :revision,
              stale_error_message: "agent changed; reload before saving"
            )
        end

      case result do
        {:ok, agent} ->
          configuration = %{
            "version" => 1,
            "name" => agent.name,
            "slug" => agent.slug,
            "purpose" => agent.purpose,
            "instructions" => agent.instructions,
            "roles" =>
              Enum.map(agent.roles, fn role ->
                # Effort, the agent and its limit are added only when there
                # are any, so earlier revisions keep the configuration shape
                # (and digest) they always had.
                %{"name" => role.name, "provider" => role.provider, "model" => role.model}
                |> then(&if(role.effort, do: Map.put(&1, "effort", role.effort), else: &1))
                |> with_agent(role.agent_id)
              end)
          }

          digest =
            :crypto.hash(:sha256, :erlang.term_to_binary(configuration))
            |> Base.encode16(case: :lower)

          Repo.insert!(%Revision{
            definition_id: agent.id,
            number: agent.revision,
            configuration: configuration,
            digest: digest
          })

          agent

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp with_agent(entry, nil), do: entry

  defp with_agent(entry, id) do
    case Shoestring.Agents.get(id) do
      nil ->
        entry

      agent ->
        entry
        |> Map.merge(%{"agent_id" => id, "agent" => agent.slug})
        |> then(
          &if(agent.max_minutes, do: Map.put(&1, "max_minutes", agent.max_minutes), else: &1)
        )
    end
  end
end
