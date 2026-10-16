defmodule Mix.Tasks.Shoestring.Agents do
  use Mix.Task
  @shortdoc "List, read, create or change saved agents"
  @moduledoc """
      mix shoestring.agents list
      mix shoestring.agents show [NAME] [--revision NUMBER]
      mix shoestring.agents create NAME --worker PROVIDER:MODEL
          [--coordinator PROVIDER:MODEL] [--title TEXT] [--purpose TEXT]
          [--instructions TEXT] [--default]
      mix shoestring.agents set-role NAME ROLE PROVIDER:MODEL
      mix shoestring.agents default NAME

  Starts only the repository. No provider, monitor, or execution process starts.
  Omitting NAME reads the saved default. A returned profile_id/revision/digest
  identifies a configuration snapshot; this task does not submit or approve work.

  `create` and `set-role` save a new immutable revision exactly as the web form
  does. NAME is the agent's CLI name (lowercase letters, numbers, hyphens).
  The first role is always Coordinator; `--coordinator` defaults to the worker's
  provider and model. Models must be listed by `mix shoestring.models`.
  `set-role` replaces the role with that name or adds it. `default` makes the
  agent the saved default.
  """

  alias Shoestring.AgentProfiles

  @switches [
    revision: :integer,
    worker: :string,
    coordinator: :string,
    title: :string,
    purpose: :string,
    instructions: :string,
    default: :boolean
  ]

  @purpose "Carry out approved plan tasks."
  @instructions "Complete the task within its stated scope and acceptance gates. Commit the result."

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    unless invalid == [] and valid?(positional, opts),
      do: Mix.raise("Invalid arguments. See mix help shoestring.agents")

    Shoestring.CLI.Repository.with_repo(fn _repo ->
      case positional do
        ["list"] ->
          Enum.each(
            AgentProfiles.list(),
            &Mix.shell().info("#{&1.slug}\t#{&1.name}\trevision #{&1.revision}")
          )

        ["show"] ->
          output(AgentProfiles.default_snapshot(opts[:revision]))

        ["show", name] ->
          output(AgentProfiles.snapshot(name, opts[:revision]))

        ["create", name] ->
          create(name, opts)

        ["set-role", name, role, provider_model] ->
          set_role(name, role, provider_model)

        ["default", name] ->
          make_default(agent!(name))
          output(AgentProfiles.snapshot(name))
      end
    end)
  end

  defp valid?(["list"], opts), do: opts == []
  defp valid?(["show"], opts), do: only?(opts, [:revision]) and positive?(opts[:revision])
  defp valid?(["show", _], opts), do: only?(opts, [:revision]) and positive?(opts[:revision])

  defp valid?(["create", _], opts),
    do:
      Keyword.has_key?(opts, :worker) and
        only?(opts, [:worker, :coordinator, :title, :purpose, :instructions, :default])

  defp valid?(["set-role", _, _, _], opts), do: opts == []
  defp valid?(["default", _], opts), do: opts == []
  defp valid?(_positional, _opts), do: false

  defp only?(opts, keys), do: Enum.all?(Keyword.keys(opts), &(&1 in keys))
  defp positive?(nil), do: true
  defp positive?(number), do: number > 0

  defp create(name, opts) do
    worker = role!("Worker", opts[:worker])
    coordinator = role!("Coordinator", opts[:coordinator] || opts[:worker])

    attrs = %{
      "name" => opts[:title] || name,
      "slug" => name,
      "purpose" => opts[:purpose] || @purpose,
      "instructions" => opts[:instructions] || @instructions,
      "roles" => [coordinator, worker]
    }

    agent = saved!(AgentProfiles.create(attrs))
    if opts[:default], do: make_default(agent)
    output(AgentProfiles.snapshot(agent.slug))
  end

  defp set_role(name, role_name, provider_model) do
    agent = agent!(name)
    role = role!(role_name, provider_model)

    roles =
      Enum.map(agent.roles, fn existing ->
        %{"name" => existing.name, "provider" => existing.provider, "model" => existing.model}
      end)

    roles =
      if Enum.any?(roles, &(&1["name"] == role_name)),
        do: Enum.map(roles, &if(&1["name"] == role_name, do: role, else: &1)),
        else: roles ++ [role]

    agent = saved!(AgentProfiles.update(agent, %{"roles" => roles}))
    output(AgentProfiles.snapshot(agent.slug))
  end

  defp make_default(agent) do
    saved!(
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => agent.id})
    )
  end

  defp agent!(name), do: AgentProfiles.get_by_slug(name) || Mix.raise("Agent not found")

  defp role!(name, provider_model) do
    case String.split(provider_model || "", ":", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        %{"name" => name, "provider" => provider, "model" => model}

      _ ->
        Mix.raise("Use PROVIDER:MODEL for #{name}, for example claude:opus")
    end
  end

  defp saved!({:ok, saved}), do: saved

  defp saved!({:error, %Ecto.Changeset{} = changeset}),
    do: Mix.raise("Not saved: #{errors(changeset)}")

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> flatten()
    |> Enum.join("; ")
  end

  defp flatten(errors) when is_map(errors) do
    Enum.flat_map(errors, fn {field, value} ->
      Enum.map(flatten(value), &"#{field} #{&1}")
    end)
  end

  defp flatten(errors) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)
  defp flatten(message) when is_binary(message), do: [message]

  defp output({:ok, snapshot}), do: Mix.shell().info(Jason.encode!(snapshot, pretty: true))

  defp output({:error, :no_default}),
    do:
      Mix.raise(
        "Choose a default agent with mix shoestring.agents default NAME, or provide its CLI name"
      )

  defp output({:error, :not_found}), do: Mix.raise("Agent or revision not found")
end
