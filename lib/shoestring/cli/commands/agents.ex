defmodule Shoestring.CLI.Commands.Agents do
  @moduledoc "`shoestring agents`: list, read, create or change saved agents."

  alias Shoestring.AgentProfiles
  alias Shoestring.CLI.{Command, Refusal}

  @help """
  shoestring agents list [--json]
  shoestring agents show [NAME] [--revision NUMBER]
  shoestring agents create NAME --worker PROVIDER:MODEL
      [--coordinator PROVIDER:MODEL] [--title TEXT] [--purpose TEXT]
      [--instructions TEXT] [--default]
  shoestring agents set-role NAME ROLE PROVIDER:MODEL
  shoestring agents default NAME

  Starts only the repository. No provider, monitor, or execution process starts.
  Omitting NAME reads the saved default. A returned profile_id/revision/digest
  identifies a configuration snapshot; this command does not submit or approve
  work. `list` prints one tab-separated line per agent, or a JSON list with
  `--json`; the other subcommands print JSON (`--json` changes nothing).

  `create` and `set-role` save a new immutable revision exactly as the web form
  does. NAME is the agent's CLI name (lowercase letters, numbers, hyphens).
  The first role is always Coordinator; `--coordinator` defaults to the worker's
  provider and model. Models must be listed by `shoestring models`.
  `set-role` replaces the role with that name or adds it. `default` makes the
  agent the saved default.
  """

  @switches [
    revision: :integer,
    worker: :string,
    coordinator: :string,
    title: :string,
    purpose: :string,
    instructions: :string,
    default: :boolean,
    json: :boolean
  ]

  @purpose "Carry out approved plan tasks."
  @instructions "Complete the task within its stated scope and acceptance gates. Commit the result."

  def help, do: @help

  def run(args, context) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    {json?, opts} = Keyword.pop(opts, :json, false)

    unless invalid == [] and valid?(positional, opts), do: Refusal.usage!("agents")

    context.with_repo.(fn _repo ->
      case positional do
        ["list"] when json? ->
          AgentProfiles.list()
          |> Enum.map(&%{slug: &1.slug, name: &1.name, revision: &1.revision})
          |> then(&Command.json(context, &1))

        ["list"] ->
          Enum.each(
            AgentProfiles.list(),
            &context.shell.info("#{&1.slug}\t#{&1.name}\trevision #{&1.revision}")
          )

        ["show"] ->
          output(context, AgentProfiles.default_snapshot(opts[:revision]))

        ["show", name] ->
          output(context, AgentProfiles.snapshot(name, opts[:revision]))

        ["create", name] ->
          create(name, opts, context)

        ["set-role", name, role, provider_model] ->
          set_role(name, role, provider_model, context)

        ["default", name] ->
          make_default(agent!(name))
          output(context, AgentProfiles.snapshot(name))
      end
    end)

    :ok
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

  defp create(name, opts, context) do
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
    output(context, AgentProfiles.snapshot(agent.slug))
  end

  defp set_role(name, role_name, provider_model, context) do
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
    output(context, AgentProfiles.snapshot(agent.slug))
  end

  defp make_default(agent) do
    saved!(
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => agent.id})
    )
  end

  defp agent!(name),
    do: AgentProfiles.get_by_slug(name) || Refusal.refuse!("Agent not found")

  defp role!(name, provider_model) do
    case String.split(provider_model || "", ":", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        %{"name" => name, "provider" => provider, "model" => model}

      _ ->
        Refusal.refuse!("Use PROVIDER:MODEL for #{name}, for example claude:opus")
    end
  end

  defp saved!({:ok, saved}), do: saved

  defp saved!({:error, %Ecto.Changeset{} = changeset}),
    do: Refusal.refuse!("Not saved: #{Command.errors(changeset)}")

  defp output(context, {:ok, snapshot}), do: Command.json(context, snapshot)

  defp output(_context, {:error, :no_default}),
    do:
      Refusal.refuse!(
        "Choose a default agent with shoestring agents default NAME, or provide its CLI name"
      )

  defp output(_context, {:error, :not_found}), do: Refusal.refuse!("Agent or revision not found")
end
