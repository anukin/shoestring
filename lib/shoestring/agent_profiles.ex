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
      "codex" => Settings.model_ids(settings.codex_models)
    }
  end

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

  def change(agent, attrs \\ %{}), do: Definition.changeset(agent, attrs, catalog())
  def create(attrs), do: persist(change(%Definition{}, attrs), :insert)

  def update(agent, attrs),
    do: persist(change(agent, attrs) |> Ecto.Changeset.optimistic_lock(:revision), :update)

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
                %{"name" => role.name, "provider" => role.provider, "model" => role.model}
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
end
