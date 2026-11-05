defmodule Shoestring.ModelCatalog do
  @moduledoc """
  The models each harness reports, and which of them agents may use.

  A refresh asks one harness for its models (`Shoestring.Harnesses.ModelListing`)
  and records what it said. A model seen for the first time is enabled
  automatically for Claude and Codex, which run on the user's subscriptions,
  and left disabled for opencode, which can also reach providers that charge
  per token. A model the user disabled stays disabled, because it is no
  longer new. A model the harness stops reporting is marked unavailable; it
  stays in the enabled list and in saved agents.

  "Enabled" is the provider's list in `agent_settings`, the list agent roles
  are validated against, so the web Settings page and `shoestring models`
  edit the same thing. Nothing here runs unless asked: no command but a
  refresh starts a harness.
  """
  import Ecto.Query

  alias Shoestring.{AgentProfiles, Harnesses, Repo}
  alias Shoestring.AgentProfiles.{Definition, Settings}
  alias Shoestring.Harnesses.ModelListing
  alias Shoestring.ModelCatalog.Entry

  @auto_enable ~w(claude codex)
  @fields %{"claude" => :claude_models, "codex" => :codex_models, "opencode" => :opencode_models}

  def providers, do: Map.keys(@fields) |> Enum.sort()

  @doc "Recorded entries, by provider and model."
  def entries(provider \\ nil) do
    Entry
    |> then(&if(provider, do: where(&1, [e], e.provider == ^provider), else: &1))
    |> order_by([e], [e.provider, e.model])
    |> Repo.all()
  end

  def entry(provider, model), do: Repo.get_by(Entry, provider: provider, model: model)

  @doc "When `provider`'s models were last listed by its harness, or nil."
  def last_listed_at(provider) do
    Repo.one(
      from e in Entry,
        where: e.provider == ^provider and e.source == "live",
        select: max(e.fetched_at)
    )
  end

  @doc "The models enabled for `provider`."
  def enabled(provider),
    do: Settings.model_ids(Map.get(AgentProfiles.settings(), field!(provider)))

  @doc """
  Shared picker rows, including legacy identifiers saved before discovery.
  By default only enabled, currently reported (or manually configured) choices
  are offered. Management screens opt into disabled and unavailable rows.
  Search matches the display name, exact identifier, CLI and opencode route.
  """
  def choices(opts \\ []) do
    settings = AgentProfiles.catalog()
    recorded = Map.new(entries(), &{{&1.provider, &1.model}, &1})

    keys =
      (Map.keys(recorded) ++
         for({provider, models} <- settings, model <- models, do: {provider, model}))
      |> Enum.uniq()
      |> Enum.sort()

    for {provider, model} <- keys,
        entry <- [recorded[{provider, model}]],
        row = %{
          provider: provider,
          model: model,
          display_name: (entry && entry.display_name) || model,
          route: if(provider == "opencode", do: hd(String.split(model, "/"))),
          enabled: model in Map.get(settings, provider, []),
          available: is_nil(entry) or entry.available,
          source: if(entry, do: entry.source, else: "configured"),
          fetched_at: entry && entry.fetched_at,
          harness_default: entry && entry.harness_default,
          efforts: if(entry, do: entry.efforts, else: [])
        },
        is_nil(opts[:provider]) or provider == opts[:provider],
        is_nil(opts[:capability]) or Harnesses.supports?(provider, opts[:capability]),
        opts[:include_disabled] == true or row.enabled,
        opts[:include_unavailable] == true or row.available,
        opts[:executable] != true or model != "default",
        matches?(row, opts[:query] || ""),
        do: row
  end

  def matches?(row, query) do
    text =
      [row.display_name, row.model, row.provider, Harnesses.name(row.provider), row.route]
      |> Enum.join(" ")
      |> String.downcase()

    query |> String.downcase() |> String.split() |> Enum.all?(&String.contains?(text, &1))
  end

  def label(row) do
    route = if row.route, do: " · #{row.route}", else: ""
    "#{row.display_name} — #{Harnesses.name(row.provider)}#{route}"
  end

  @doc "Bulk settings edits in model-management interfaces protect current model users."
  def change_settings(settings, attrs) do
    AgentProfiles.change_settings(settings, attrs) |> validate_model_removals(settings)
  end

  def save_settings(settings, attrs) do
    Repo.transaction(fn ->
      changeset = change_settings(settings, attrs)

      result =
        if changeset.valid?,
          do: AgentProfiles.save_settings(settings, attrs),
          else: {:error, %{changeset | action: :update}}

      case result do
        {:ok, saved} -> saved
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp validate_model_removals(changeset, settings) do
    Enum.reduce(
      [{"claude", :claude_models}, {"codex", :codex_models}, {"opencode", :opencode_models}],
      changeset,
      fn {provider, field}, changeset ->
        Ecto.Changeset.validate_change(changeset, field, fn _, value ->
          removed = Settings.model_ids(Map.get(settings, field)) -- Settings.model_ids(value)
          used = Enum.filter(removed, &(Shoestring.ModelCatalog.agents_using(provider, &1) != []))

          if used == [],
            do: [],
            else: [{field, "models still used by agents or teams: #{Enum.join(used, ", ")}"}]
        end)
      end
    )
  end

  @doc "Checks a picker choice again when it is submitted."
  def selectable?(provider, model, capability \\ nil) do
    Enum.any?(choices(capability: capability), &(&1.provider == provider and &1.model == model))
  end

  @doc """
  The efforts `model` accepts, as its harness last reported them, or nil
  when no listing has described it.
  """
  def efforts(provider, model) when is_binary(provider) and is_binary(model) do
    case entry(provider, model) do
      %Entry{source: "live", efforts: efforts} -> efforts
      _ -> nil
    end
  end

  def efforts(_provider, _model), do: nil

  @doc """
  Asks `provider` for its models and records them. Returns a report, or
  `{:error, reason}` with nothing changed. Options: `:lister` (instead of
  `ModelListing.list/2`, also read from `config :shoestring, :model_lister`),
  `:listing_opts` and `:now`.
  """
  def refresh(provider, opts \\ []) do
    field!(provider)

    lister =
      Keyword.get_lazy(opts, :lister, fn ->
        Application.get_env(:shoestring, :model_lister, &ModelListing.list/2)
      end)

    case lister.(provider, Keyword.get(opts, :listing_opts, [])) do
      {:ok, %{models: models, skipped: skipped}} ->
        record(provider, models, skipped, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record(provider, models, skipped, now) do
    Repo.transaction(fn ->
      existing = Map.new(entries(provider), &{&1.model, &1})
      listed = MapSet.new(models, & &1["model"])

      new =
        for model <- models do
          attrs = %{
            display_name: model["display_name"],
            efforts: model["efforts"] || [],
            default_effort: model["default_effort"],
            harness_default: model["default"] == true,
            resolves_to: model["resolves_to"],
            source: "live",
            available: true,
            fetched_at: now
          }

          case Map.get(existing, model["model"]) do
            nil ->
              Repo.insert!(
                struct(
                  Entry,
                  Map.merge(attrs, %{
                    provider: provider,
                    model: model["model"],
                    first_seen_at: now
                  })
                )
              )

              model["model"]

            entry ->
              entry |> Ecto.Changeset.change(attrs) |> Repo.update!()
              nil
          end
        end
        |> Enum.reject(&is_nil/1)

      unavailable =
        for {model, %Entry{source: "live", available: true} = entry} <- existing,
            not MapSet.member?(listed, model) do
          entry |> Ecto.Changeset.change(available: false) |> Repo.update!()
          model
        end

      enabled =
        if provider in @auto_enable do
          case enable_all(provider, new) do
            {:ok, added} -> added
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          []
        end

      %{
        "provider" => provider,
        "listed" => MapSet.size(listed),
        "skipped" => skipped,
        "new" => Enum.sort(new),
        "enabled" => enabled,
        "unavailable" => Enum.sort(unavailable),
        "fetched_at" => now
      }
    end)
  end

  @doc "Records a model the operator named by hand and enables it."
  def add(provider, model) do
    field!(provider)

    if Settings.valid_model?(provider, model) do
      Repo.transaction(fn ->
        unless entry(provider, model) do
          now = DateTime.utc_now()

          Repo.insert!(%Entry{
            provider: provider,
            model: model,
            source: "manual",
            available: true,
            first_seen_at: now
          })
        end

        case enable_all(provider, [model]) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :invalid_model}
    end
  end

  @doc "Enables a model a harness reported or the operator added."
  def enable(provider, model) do
    field!(provider)

    cond do
      model in enabled(provider) -> {:ok, :already_enabled}
      is_nil(entry(provider, model)) -> {:error, :unknown_model}
      true -> with {:ok, _} <- enable_all(provider, [model]), do: {:ok, :enabled}
    end
  end

  @doc """
  Disables a model. Refused while an agent's current revision names it, so
  no saved agent is left pointing at a model it can no longer be saved with.
  """
  def disable(provider, model) do
    field = field!(provider)
    models = enabled(provider)

    cond do
      model not in models ->
        {:ok, :already_disabled}

      (users = agents_using(provider, model)) != [] ->
        {:error, {:in_use, users}}

      true ->
        value = Enum.join(List.delete(models, model), "\n")

        case AgentProfiles.save_settings(AgentProfiles.settings(), %{to_string(field) => value}) do
          {:ok, _} -> {:ok, :disabled}
          {:error, changeset} -> {:error, {:settings, changeset}}
        end
    end
  end

  def agents_using(provider, model) do
    teams =
      for agent <- Repo.all(Definition),
          Enum.any?(agent.roles, &(&1.provider == provider and &1.model == model)),
          do: agent.slug

    agents =
      Repo.all(
        from a in Shoestring.Agents.Agent,
          where: a.provider == ^provider and a.model == ^model,
          select: a.slug
      )

    Enum.uniq(teams ++ agents)
  end

  defp enable_all(provider, models) do
    current = enabled(provider)

    case Enum.reject(models, &(&1 in current)) do
      [] ->
        {:ok, []}

      added ->
        value = Enum.join(current ++ added, "\n")

        case AgentProfiles.save_settings(AgentProfiles.settings(), %{
               to_string(field!(provider)) => value
             }) do
          {:ok, _} -> {:ok, added}
          {:error, changeset} -> {:error, {:settings, changeset}}
        end
    end
  end

  defp field!(provider) do
    Map.get(@fields, provider) || raise ArgumentError, "unknown provider #{inspect(provider)}"
  end
end
