defmodule Shoestring.CLI.Commands.Models do
  @moduledoc "`shoestring models`: list or add the models agents may use per provider."

  alias Shoestring.AgentProfiles
  alias Shoestring.CLI.{Command, Refusal}

  @help """
  shoestring models list
  shoestring models add PROVIDER MODEL

  The same provider model lists as Settings in the web UI. Agent roles may only
  name a listed model, and execution needs one other than `default`. PROVIDER
  is `claude` or `codex`; MODEL is the name the provider CLI accepts (for
  example `opus`). Starts only the repository; nothing runs. Output is JSON on
  stdout (`--json` is accepted and changes nothing).
  """

  @fields %{"claude" => :claude_models, "codex" => :codex_models}

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [json: :boolean]) do
      {_, ["list"], []} ->
        context.with_repo.(fn _repo -> list(context) end)

      {_, ["add", provider, model], []} ->
        context.with_repo.(fn _repo -> add(provider, model, context) end)

      _ ->
        Refusal.usage!("models")
    end
  end

  defp list(context), do: Command.json(context, AgentProfiles.catalog())

  defp add(provider, model, context) do
    field =
      Map.get(@fields, provider) || Refusal.refuse!("Unknown provider #{inspect(provider)}")

    unless Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@-]{0,99}\z/, model),
      do: Refusal.refuse!("Invalid model name #{inspect(model)}")

    settings = AgentProfiles.settings()
    models = AgentProfiles.Settings.model_ids(Map.fetch!(settings, field))

    if model not in models do
      value = Enum.join(models ++ [model], "\n")

      case AgentProfiles.save_settings(settings, %{to_string(field) => value}) do
        {:ok, _} -> :ok
        {:error, changeset} -> Refusal.refuse!("Models not saved: #{errors(changeset)}")
      end
    end

    list(context)
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
