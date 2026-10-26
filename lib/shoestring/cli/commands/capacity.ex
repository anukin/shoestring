defmodule Shoestring.CLI.Commands.Capacity do
  @moduledoc "`shoestring capacity`: each provider's latest usage reading and what admission is likely to do."

  alias Shoestring.Cobbler.AdmissionPolicy
  alias Shoestring.CLI.{Command, Refusal}

  @help """
  shoestring capacity [--json]

  Each provider's latest usage reading (the same readings as the Usage page):
  its status, each window's used percentage and reset time, and an outlook
  for a new dispatch against the standing reserves (automatic admission
  stops at 80% of the 5-hour window and 90% of the weekly one):

    admits     the reading is fresh and under both reserves
    deferred   a window is over its reserve; work waits for its reset
    asks       the reading is unknown or stale, or the provider (opencode)
               reports none: a person confirms, or the grant spends one of
               its unread-usage pre-approvals
    refused    the provider reported it cannot take work

  The outlook is where admission starts, not its decision, which also
  weighs each harness's support tier. Reads Shoestring's records only.
  Output is JSON on stdout.
  """

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [json: :boolean]) do
      {_opts, [], []} ->
        context.with_repo.(fn _repo ->
          policy = AdmissionPolicy.default()

          Command.json(context, %{
            "reserves" => %{
              "five_hour_max_used_percent" => policy.five_hour_max_used_percent,
              "weekly_max_used_percent" => policy.weekly_max_used_percent
            },
            "providers" =>
              Enum.map(Shoestring.Usage.cards(), &provider(&1, policy)) ++ [opencode()]
          })
        end)

      _ ->
        Refusal.usage!("capacity")
    end
  end

  @doc "The capacity entry for one harness, as `shoestring capacity` prints it."
  def for_provider("opencode"), do: opencode()

  def for_provider(id) do
    policy = AdmissionPolicy.default()

    case Enum.find(Shoestring.Usage.cards(), &(&1.provider == id)) do
      nil -> nil
      card -> provider(card, policy)
    end
  end

  defp provider(card, policy) do
    %{
      "provider" => card.provider,
      "scope" => card.scope,
      "status" => card.status,
      "observed_at" => card.observed_at,
      "warning" => card.warning?,
      "windows" =>
        for window <- card.windows do
          %{
            "kind" => window.kind,
            "used_percent" => window.used_percent,
            "reset_at" => window.reset_at
          }
        end,
      "outlook" => outlook(card, policy)
    }
  end

  @doc false
  def outlook(%{status: "Unavailable"}, _policy), do: %{"outlook" => "refused"}

  def outlook(%{status: "Observed", windows: windows}, policy) do
    over =
      Enum.filter(windows, fn window ->
        limit =
          case window.kind do
            "five_hour" -> policy.five_hour_max_used_percent
            "seven_day" -> policy.weekly_max_used_percent
            _ -> nil
          end

        limit && is_number(window.used_percent) && window.used_percent >= limit
      end)

    case over do
      [] ->
        %{"outlook" => "admits"}

      over ->
        %{
          "outlook" => "deferred",
          "until" =>
            over
            |> Enum.map(& &1.reset_at)
            |> Enum.reject(&is_nil/1)
            |> Enum.max(DateTime, fn -> nil end)
        }
    end
  end

  def outlook(_card, _policy), do: %{"outlook" => "asks"}

  defp opencode do
    %{
      "provider" => "opencode",
      "status" => "Unreadable",
      "observed_at" => nil,
      "windows" => [],
      "outlook" => %{
        "outlook" => "asks",
        "note" =>
          "opencode reports no remaining usage; an openai/ model shares the ChatGPT subscription Codex uses"
      }
    }
  end
end
