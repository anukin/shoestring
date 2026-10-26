defmodule Shoestring.CLI.Commands.Setup do
  @moduledoc "`shoestring setup`: check the agent CLIs, record their models and save a default agent."

  alias Shoestring.{AgentProfiles, Harnesses, ModelCatalog}
  alias Shoestring.CLI.{Command, Refusal, Terminal}
  alias Shoestring.Release.{Doctor, ProviderProbe}

  @help """
  shoestring setup [--agent NAME] [--coordinator PROVIDER:MODEL]
      [--worker PROVIDER:MODEL] [--reviewer PROVIDER:MODEL|none]
      [--skip-refresh] [--yes] [--json]

  Gets Shoestring ready to use in one pass:

  1. Checks each agent CLI (claude, codex, opencode) the way
     `shoestring doctor --probe-providers` does: installed, signed in, a
     tested version. No prompt is sent.
  2. Asks each installed CLI which models it offers and records them, as
     `shoestring models refresh` does (skip it with --skip-refresh). New
     Claude and Codex models are enabled; opencode ones are left for you to
     enable.
  3. Chooses the default agent's Coordinator (plans for `shoestring do`),
     Worker (runs tasks) and Reviewer (reviews them, from another vendor than
     the Worker). It suggests each one, or keeps the agent's current choice;
     press Enter to accept or type PROVIDER:MODEL. `--reviewer none` leaves
     the Reviewer out.
  4. Shows what it would save and asks before saving. Running it again with
     the same choices saves nothing.

  The agent is NAME, else the current default agent, else `builder`. Its
  other team roles are kept. Without a terminal it asks nothing: pass at
  least --worker together with --yes, or it refuses before changing
  anything. Sign-in stays with each CLI; Shoestring never reads, stores or
  copies credentials. Output is JSON on stdout: the readiness of each CLI,
  the model refreshes and the saved agent.
  """

  @switches [
    agent: :string,
    coordinator: :string,
    worker: :string,
    reviewer: :string,
    skip_refresh: :boolean,
    yes: :boolean,
    json: :boolean
  ]

  @roles ["Coordinator", "Worker", "Reviewer"]
  @flags %{"Coordinator" => :coordinator, "Worker" => :worker, "Reviewer" => :reviewer}

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        interactive = Map.get(context, :interactive?, &Terminal.interactive?/0).()

        unless interactive or (opts[:yes] && opts[:worker]),
          do:
            Refusal.refuse!(
              "setup asks questions. Without a terminal pass --worker PROVIDER:MODEL " <>
                "(and --coordinator, --reviewer if you like) with --yes"
            )

        context.with_repo.(fn _repo -> setup(opts, interactive, context) end)

      _ ->
        Refusal.usage!("setup")
    end
  end

  defp setup(opts, interactive, context) do
    readiness = Map.get(context, :readiness, fn -> Doctor.agents(ProviderProbe.report()) end).()

    for id <- Harnesses.ids() do
      %{"readiness" => state} = readiness[id]
      version = readiness[id]["cli_version"]
      context.shell.error("#{Harnesses.name(id)}: #{state}#{if version, do: " (#{version})"}")
    end

    refreshed =
      if opts[:skip_refresh] do
        []
      else
        for id <- Harnesses.ids(), readiness[id]["readiness"] != "binary_missing" do
          context.shell.error("Asking #{Harnesses.name(id)} for its models...")

          case ModelCatalog.refresh(id) do
            {:ok, report} ->
              report

            {:error, reason} ->
              context.shell.error(
                "#{Harnesses.name(id)}: could not list models (#{inspect(reason)})"
              )

              %{"provider" => id, "error" => error_code(reason)}
          end
        end
      end

    name = opts[:agent] || current_default() || "builder"
    existing = AgentProfiles.get_by_slug(name)
    current = if existing, do: Map.new(existing.roles, &{&1.name, role_map(&1)}), else: %{}

    chosen =
      Enum.reduce(@roles, %{}, fn role, chosen ->
        flag = opts[@flags[role]]

        value =
          cond do
            flag -> parse!(role, flag)
            interactive -> ask(role, current[role] || suggest(role, chosen, readiness), context)
            true -> current[role] || suggest(role, chosen, readiness)
          end

        if value, do: Map.put(chosen, role, value), else: chosen
      end)

    unless chosen["Worker"],
      do: Refusal.refuse!("No Worker: pass --worker PROVIDER:MODEL with an enabled model")

    chosen =
      Map.put_new_lazy(chosen, "Coordinator", fn ->
        Map.put(chosen["Worker"], "name", "Coordinator")
      end)

    roles =
      Enum.map(@roles, &chosen[&1])
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(if existing, do: other_roles(existing), else: [])

    if same_vendor?(chosen["Worker"], chosen["Reviewer"]),
      do:
        context.shell.error(
          "The Reviewer's model is the same vendor as the Worker's: cross-review will wait for you."
        )

    unchanged? = existing != nil and Enum.map(existing.roles, &role_map/1) == roles
    default? = existing != nil and AgentProfiles.settings().default_agent_id == existing.id

    agent =
      if unchanged? and default? do
        context.shell.error("Agent #{name} is already set up this way; nothing to save.")
        existing
      else
        describe(name, existing, roles, context)

        unless opts[:yes] == true or (interactive and confirmed?(context)),
          do: Refusal.refuse!("Not saved.")

        saved = save!(name, existing, roles, unchanged?)

        saved!(
          AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => saved.id})
        )

        saved
      end

    {:ok, snapshot} = AgentProfiles.snapshot(agent.slug)

    Command.json(context, %{
      "readiness" => readiness,
      "models" => refreshed,
      "agent" => snapshot,
      "changed" => not (unchanged? and default?)
    })
  end

  defp same_vendor?(%{} = worker, %{} = reviewer),
    do:
      Harnesses.vendor(worker["provider"], worker["model"]) ==
        Harnesses.vendor(reviewer["provider"], reviewer["model"])

  defp same_vendor?(_worker, _reviewer), do: false

  defp current_default do
    case AgentProfiles.default_snapshot() do
      {:ok, snapshot} -> snapshot["configuration"]["slug"]
      _ -> nil
    end
  end

  defp role_map(role) do
    %{"name" => role.name, "provider" => role.provider, "model" => role.model}
    |> then(&if(role.effort, do: Map.put(&1, "effort", role.effort), else: &1))
  end

  defp other_roles(agent),
    do: agent.roles |> Enum.reject(&(&1.name in @roles)) |> Enum.map(&role_map/1)

  # The first enabled model of the first harness, in order, that is
  # installed, can do the role and (for the Reviewer) is another vendor than
  # the Worker. A harness's own default model comes first.
  defp suggest(role, chosen, readiness) do
    capability = Harnesses.role_capability(role)
    worker = chosen["Worker"]
    worker_vendor = worker && Harnesses.vendor(worker["provider"], worker["model"])

    preferred =
      case role do
        "Worker" -> ["codex", "claude", "opencode"]
        _ -> ["claude", "codex", "opencode"]
      end

    Enum.find_value(preferred, fn id ->
      if readiness[id]["readiness"] != "binary_missing" and Harnesses.supports?(id, capability) do
        id
        |> candidates()
        |> Enum.find(&(role != "Reviewer" or Harnesses.vendor(id, &1) != worker_vendor))
        |> then(&(&1 && %{"name" => role, "provider" => id, "model" => &1}))
      end
    end)
  end

  defp candidates(id) do
    enabled = ModelCatalog.enabled(id) -- ["default"]

    defaults =
      for entry <- ModelCatalog.entries(id),
          entry.harness_default,
          entry.model in enabled,
          do: entry.model

    Enum.uniq(defaults ++ Enum.filter(["opus"], &(&1 in enabled)) ++ enabled)
  end

  defp ask(role, suggestion, context) do
    shown = if suggestion, do: "#{suggestion["provider"]}:#{suggestion["model"]}", else: "none"
    answer = context.shell.prompt("#{role} [#{shown}]: ") |> to_string() |> String.trim()

    cond do
      answer == "" -> suggestion
      true -> parse!(role, answer)
    end
  end

  defp parse!("Reviewer", "none"), do: nil

  defp parse!(role, value) do
    case String.split(value, ":", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        %{"name" => role, "provider" => provider, "model" => model}

      _ ->
        Refusal.refuse!("Use PROVIDER:MODEL for #{role}, for example claude:opus")
    end
  end

  defp describe(name, existing, roles, context) do
    action = if existing, do: "update to revision #{existing.revision + 1}", else: "create"
    context.shell.error("Agent #{name} (#{action}), made the default:")

    for role <- roles,
        do: context.shell.error("  #{role["name"]}: #{role["provider"]}:#{role["model"]}")
  end

  defp confirmed?(context) do
    answer = context.shell.prompt("Save? [y/N] ") |> to_string() |> String.trim()
    String.downcase(answer) in ["y", "yes"]
  end

  defp save!(_name, existing, _roles, true), do: existing

  defp save!(name, nil, roles, _unchanged?) do
    saved!(
      AgentProfiles.create(%{
        "name" => name,
        "slug" => name,
        "purpose" => "Plan, implement and review changes.",
        "instructions" => "Keep changes small and verify them with the repository's checks.",
        "roles" => roles
      })
    )
  end

  defp save!(_name, existing, roles, _unchanged?),
    do: saved!(AgentProfiles.update(existing, %{"roles" => roles}))

  defp saved!({:ok, saved}), do: saved

  defp saved!({:error, %Ecto.Changeset{} = changeset}),
    do: Refusal.refuse!("Not saved: #{Command.errors(changeset)}")

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "failed"
end
