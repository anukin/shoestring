defmodule Shoestring.CLI.Commands.Models do
  @moduledoc "`shoestring models`: the models each harness offers, and which ones agents may use."

  alias Shoestring.{AgentProfiles, Harnesses, ModelCatalog}
  alias Shoestring.CLI.{Command, Refusal}

  @help """
  shoestring models list
  shoestring models show [PROVIDER]
  shoestring models refresh [PROVIDER]
  shoestring models enable PROVIDER MODEL
  shoestring models disable PROVIDER MODEL
  shoestring models add PROVIDER MODEL

  `list` prints the enabled models per provider, the same lists as Settings in
  the web UI. Agent roles may only name an enabled model, and execution needs
  one other than `default`. PROVIDER is `claude`, `codex` or `opencode`.

  `refresh` asks each harness CLI (or only PROVIDER's) which models it offers,
  without sending a prompt, and records the answer. Newly reported Claude and
  Codex models are enabled; opencode models stay disabled until you enable
  them, because opencode can also reach providers that charge per token. A
  model a harness stops reporting is marked unavailable but stays enabled and
  in saved agents. It exits 1 when no harness answered. `show` prints what was
  recorded: each model's name, efforts, whether it is enabled and available,
  where it came from and when.

  `enable` turns on a recorded model. `disable` turns one off, and is refused
  while an agent's current revision names it. `add` records and enables a
  model no harness reported; MODEL is the name the CLI accepts
  (`provider/model` for opencode). Only `refresh` starts a harness; the other
  commands start only the repository. Output is JSON on stdout (`--json` is
  accepted and changes nothing); progress goes to stderr.
  """

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [json: :boolean]) do
      {_, ["list"], []} ->
        context.with_repo.(fn _repo -> list(context) end)

      {_, ["show" | rest], []} when length(rest) <= 1 ->
        provider = Enum.map(rest, &provider!/1) |> List.first()
        context.with_repo.(fn _repo -> show(provider, context) end)

      {_, ["refresh" | rest], []} when length(rest) <= 1 ->
        providers =
          if rest == [], do: ModelCatalog.providers(), else: Enum.map(rest, &provider!/1)

        context.with_repo.(fn _repo -> refresh(providers, context) end)

      {_, ["enable", provider, model], []} ->
        context.with_repo.(fn _repo -> enable(provider!(provider), model, context) end)

      {_, ["disable", provider, model], []} ->
        context.with_repo.(fn _repo -> disable(provider!(provider), model, context) end)

      {_, ["add", provider, model], []} ->
        context.with_repo.(fn _repo -> add(provider!(provider), model, context) end)

      _ ->
        Refusal.usage!("models")
    end
  end

  defp list(context), do: Command.json(context, AgentProfiles.catalog())

  defp show(provider, context) do
    enabled = Map.new(ModelCatalog.providers(), &{&1, ModelCatalog.enabled(&1)})

    entries =
      for entry <- ModelCatalog.entries(provider) do
        %{
          "provider" => entry.provider,
          "model" => entry.model,
          "display_name" => entry.display_name,
          "efforts" => entry.efforts,
          "default_effort" => entry.default_effort,
          "harness_default" => entry.harness_default,
          "resolves_to" => entry.resolves_to,
          "enabled" => entry.model in enabled[entry.provider],
          "available" => entry.available,
          "source" => entry.source,
          "first_seen_at" => entry.first_seen_at,
          "fetched_at" => entry.fetched_at
        }
      end

    Command.json(context, entries)
  end

  defp refresh(providers, context) do
    results =
      for provider <- providers do
        context.shell.error("Asking #{Harnesses.name(provider)} for its models...")

        case ModelCatalog.refresh(provider) do
          {:ok, report} ->
            context.shell.error(summary(report))
            report

          {:error, reason} ->
            context.shell.error("#{Harnesses.name(provider)}: #{reason_text(reason)}")
            %{"provider" => provider, "error" => code(reason)}
        end
      end

    Command.json(context, results)
    if Enum.all?(results, &Map.has_key?(&1, "error")), do: 1, else: :ok
  end

  defp summary(report) do
    name = Harnesses.name(report["provider"])

    "#{name}: #{report["listed"]} models, #{length(report["new"])} new, " <>
      "#{length(report["enabled"])} enabled, #{length(report["unavailable"])} no longer offered" <>
      if(report["skipped"] > 0, do: ", #{report["skipped"]} skipped (unusable names)", else: "")
  end

  defp enable(provider, model, context) do
    case ModelCatalog.enable(provider, model) do
      {:ok, _} ->
        list(context)

      {:error, :unknown_model} ->
        Refusal.refuse!(
          "#{model} is not a recorded #{provider} model. Run shoestring models refresh #{provider}, " <>
            "or shoestring models add #{provider} #{model}"
        )

      {:error, {:settings, changeset}} ->
        Refusal.refuse!("Models not saved: #{Command.errors(changeset)}")
    end
  end

  defp disable(provider, model, context) do
    case ModelCatalog.disable(provider, model) do
      {:ok, _} ->
        list(context)

      {:error, {:in_use, agents}} ->
        Refusal.refuse!(
          "#{model} is used by #{Enum.join(agents, ", ")}. Change their roles before disabling it."
        )

      {:error, {:settings, changeset}} ->
        Refusal.refuse!("Models not saved: #{Command.errors(changeset)}")
    end
  end

  defp add(provider, model, context) do
    case ModelCatalog.add(provider, model) do
      {:ok, _} ->
        list(context)

      {:error, :invalid_model} ->
        Refusal.refuse!("Invalid model name #{inspect(model)}")

      {:error, {:settings, changeset}} ->
        Refusal.refuse!("Models not saved: #{Command.errors(changeset)}")
    end
  end

  defp provider!(provider) do
    if provider in ModelCatalog.providers(),
      do: provider,
      else: Refusal.refuse!("Unknown provider #{inspect(provider)}")
  end

  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code({:settings, _}), do: "settings_not_saved"
  defp code(_reason), do: "failed"

  defp reason_text(:binary_missing), do: "its CLI is not on PATH"
  defp reason_text(:timeout), do: "no answer in time"
  defp reason_text(:exited), do: "the CLI exited before answering"
  defp reason_text(:listing_refused), do: "the CLI refused to list models (is it signed in?)"
  defp reason_text(:oversized_reply), do: "the reply was larger than allowed"
  defp reason_text({:settings, changeset}), do: "models not saved: #{Command.errors(changeset)}"
  defp reason_text(reason), do: "could not list models (#{code(reason)})"
end
