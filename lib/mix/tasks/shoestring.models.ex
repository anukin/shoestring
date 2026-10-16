defmodule Mix.Tasks.Shoestring.Models do
  use Mix.Task
  @shortdoc "List or add the models agents may use per provider"
  @moduledoc """
      mix shoestring.models list
      mix shoestring.models add PROVIDER MODEL

  The same provider model lists as Settings in the web UI. Agent roles may only
  name a listed model, and execution needs one other than `default`. PROVIDER
  is `claude` or `codex`; MODEL is the name the provider CLI accepts (for
  example `opus`). Starts only the repository; nothing runs.
  """

  alias Shoestring.AgentProfiles

  @fields %{"claude" => :claude_models, "codex" => :codex_models}

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: []) do
      {[], ["list"], []} -> with_repo(&list/0)
      {[], ["add", provider, model], []} -> with_repo(fn -> add(provider, model) end)
      _ -> Mix.raise("Invalid arguments. See mix help shoestring.models")
    end
  end

  defp with_repo(fun), do: Shoestring.CLI.Repository.with_repo(fn _repo -> fun.() end)

  defp list, do: output(AgentProfiles.catalog())

  defp add(provider, model) do
    field = Map.get(@fields, provider) || Mix.raise("Unknown provider #{inspect(provider)}")

    unless Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@-]{0,99}\z/, model),
      do: Mix.raise("Invalid model name #{inspect(model)}")

    settings = AgentProfiles.settings()
    models = AgentProfiles.Settings.model_ids(Map.fetch!(settings, field))

    if model not in models do
      value = Enum.join(models ++ [model], "\n")

      case AgentProfiles.save_settings(settings, %{to_string(field) => value}) do
        {:ok, _} -> :ok
        {:error, changeset} -> Mix.raise("Models not saved: #{errors(changeset)}")
      end
    end

    list()
  end

  defp output(value), do: Mix.shell().info(Jason.encode!(value, pretty: true))

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
