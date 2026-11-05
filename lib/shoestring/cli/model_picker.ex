defmodule Shoestring.CLI.ModelPicker do
  @moduledoc "Line-oriented model selection using the same catalog as the web UI."
  alias Shoestring.{AgentProfiles, Harnesses, ModelCatalog}
  alias Shoestring.CLI.Refusal

  def manage(action, provider, context) do
    rows =
      ModelCatalog.choices(provider: provider, include_disabled: true, include_unavailable: true)

    rows =
      Enum.filter(
        rows,
        &if(action == "enable", do: not &1.enabled and &1.available, else: &1.enabled)
      )

    manage_select(action, rows, rows, context)
  end

  defp manage_select(action, all, rows, context) do
    visible = Enum.take(rows, 15)

    if length(rows) > 15,
      do: context.shell.error("Showing 15 of #{length(rows)} models. Search to narrow the list.")

    for {row, index} <- Enum.with_index(visible, 1),
        do: context.shell.error("  #{index}  #{ModelCatalog.label(row)}\n     #{row.model}")

    if rows == [], do: context.shell.error("No matching models. Type another search or /all.")

    answer =
      context.shell.prompt("Model to #{action} (number/search, Enter cancels): ")
      |> to_string()
      |> String.trim()

    cond do
      answer == "" ->
        nil

      answer == "/all" ->
        manage_select(action, all, all, context)

      true ->
        case resolve(answer, visible, all) do
          {:ok, row} ->
            row

          :search ->
            manage_select(
              action,
              all,
              Enum.filter(all, &ModelCatalog.matches?(&1, answer)),
              context
            )

          :invalid ->
            context.shell.error("Choose a listed number or search again.")
            manage_select(action, all, rows, context)
        end
    end
  end

  def choose(role, current, context, readiness) do
    capability = Harnesses.role_capability(role)

    rows =
      ModelCatalog.choices(capability: capability, executable: true, include_disabled: true)
      |> Enum.reject(&(get_in(readiness, [&1.provider, "readiness"]) == "binary_missing"))

    if rows == [] and is_nil(current) do
      if role == "Reviewer",
        do: nil,
        else: Refusal.refuse!("No models for #{role}. Refresh models or add one first.")
    else
      select(role, current, rows, rows, context)
    end
  end

  defp select(role, current, all, rows, context) do
    context.shell.error("#{role}: choose a number or search by model, CLI or provider.")

    visible = Enum.take(rows, 15)

    if length(rows) > 15,
      do: context.shell.error("Showing 15 of #{length(rows)} models. Search to narrow the list.")

    for {row, index} <- Enum.with_index(visible, 1) do
      state = if row.enabled, do: "", else: " [disabled; enable to select]"
      context.shell.error("  #{index}  #{ModelCatalog.label(row)}#{state}\n     #{row.model}")
    end

    if rows == [], do: context.shell.error("No matches. Type another search or /all.")
    shown = if current, do: "#{current["provider"]}:#{current["model"]}", else: "none"
    answer = context.shell.prompt("#{role} [#{shown}]: ") |> to_string() |> String.trim()

    cond do
      answer == "none" and role == "Reviewer" ->
        nil

      answer == "" and is_nil(current) and role == "Reviewer" ->
        nil

      (answer == "" and current) &&
          Enum.any?(
            all,
            &(&1.enabled and &1.provider == current["provider"] and &1.model == current["model"])
          ) ->
        effort(current, context)

      answer == "" ->
        Refusal.refuse!("No available current model for #{role}; choose a model explicitly.")

      answer == "/all" ->
        select(role, current, all, all, context)

      true ->
        case resolve(answer, visible, all) do
          {:ok, row} ->
            pick(role, current, row, all, context)

          :search ->
            select(
              role,
              current,
              all,
              Enum.filter(all, &ModelCatalog.matches?(&1, answer)),
              context
            )

          :invalid ->
            context.shell.error(
              "That choice is not available. Choose a listed number or search again."
            )

            select(role, current, all, rows, context)
        end
    end
  end

  defp resolve(answer, rows, all) do
    case Integer.parse(answer) do
      {number, ""} ->
        case if(number > 0, do: Enum.at(rows, number - 1)) do
          nil -> :invalid
          row -> {:ok, row}
        end

      _ ->
        case Enum.find(all, &("#{&1.provider}:#{&1.model}" == answer)) do
          nil -> :search
          row -> {:ok, row}
        end
    end
  end

  defp pick(role, current, row, all, context) do
    enabled? =
      if row.enabled do
        true
      else
        context.shell.error(
          "Enabling an opencode route may allow API charges; listing does not verify access or billing."
        )

        answer =
          context.shell.prompt("Enable #{ModelCatalog.label(row)}? [y/N] ")
          |> to_string()
          |> String.trim()
          |> String.downcase()

        if answer in ["y", "yes"] do
          case ModelCatalog.enable(row.provider, row.model) do
            {:ok, _} ->
              true

            {:error, _} ->
              context.shell.error("Could not enable this model. Reload models and try again.")
              false
          end
        else
          false
        end
      end

    cond do
      not enabled? ->
        select(role, current, all, all, context)

      not ModelCatalog.selectable?(row.provider, row.model, Harnesses.role_capability(role)) ->
        Refusal.refuse!("The model catalog changed; run setup again.")

      true ->
        effort(%{"name" => role, "provider" => row.provider, "model" => row.model}, context)
    end
  end

  defp effort(choice, context) do
    efforts = AgentProfiles.efforts(choice["provider"], choice["model"])

    if efforts == [] do
      Map.delete(choice, "effort")
    else
      current = choice["effort"] || "default"
      context.shell.error("Effort: default, " <> Enum.join(efforts, ", "))
      answer = context.shell.prompt("Effort [#{current}]: ") |> to_string() |> String.trim()
      value = if answer == "", do: current, else: answer

      cond do
        value == "default" ->
          Map.delete(choice, "effort")

        value in efforts ->
          Map.put(choice, "effort", value)

        true ->
          context.shell.error("Choose one of the listed efforts.")
          effort(choice, context)
      end
    end
  end
end
