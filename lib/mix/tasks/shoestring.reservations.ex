defmodule Mix.Tasks.Shoestring.Reservations do
  use Mix.Task
  alias Shoestring.Cobbler.{ReservationControl, ReservationInspection}
  @shortdoc "Inspect configured reservations and queue evidence-backed recovery"
  @moduledoc """
      mix shoestring.reservations list [--goal UUID] [--all] [--limit N]
      mix shoestring.reservations show RESERVATION_ID
      mix shoestring.reservations reconcile RESERVATION_ID --command-id UUID --by human:NAME
      mix shoestring.reservations cancel-unstarted RESERVATION_ID --command-id UUID --by human:NAME

  Read commands expose durable ownership, configured allowances and provider
  evidence without starting providers. Recovery requests are queued for the
  running service; inspect `show` for their durable results. A command ID is
  immutable and replayable. Use a new ID for a later reconciliation observation.
  Overdue reservations still consume capacity. Cancel-unstarted only fences
  provably unused intent; possibly started effects remain held. It never kills
  or replaces a process. Live cancellation stays with the supervising Elf.
  """
  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          goal: [:string, :keep],
          all: [:boolean, :keep],
          limit: [:integer, :keep],
          command_id: [:string, :keep],
          by: [:string, :keep]
        ]
      )

    with true <- invalid == [],
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- valid?(positional, opts) do
      Shoestring.CLI.Repository.with_repo(fn _ ->
        result =
          case positional do
            ["list"] ->
              ReservationInspection.list(
                goal_id: opts[:goal],
                all: opts[:all] || false,
                limit: opts[:limit] || 100
              )

            ["show", id] ->
              ReservationInspection.show(id)

            [action, id] ->
              Shoestring.CLI.Jobs.with_client(fn client ->
                ReservationControl.request(
                  id,
                  action,
                  %{command_id: opts[:command_id], requested_by: opts[:by]},
                  oban: client
                )
              end)
          end

        case result do
          {:ok, output} -> Mix.shell().info(Jason.encode!(output, pretty: true))
          {:error, reason} -> Mix.raise("Reservation request refused: #{inspect(reason)}")
        end
      end)
    else
      _ -> Mix.raise("Invalid arguments. See mix help shoestring.reservations")
    end
  end

  defp valid?(["list"], opts) do
    Keyword.keys(opts) -- [:goal, :all, :limit] == [] and
      (is_nil(opts[:goal]) or match?({:ok, _}, Ecto.UUID.cast(opts[:goal]))) and
      (is_nil(opts[:limit]) or opts[:limit] in 1..1000)
  end

  defp valid?(["show", id], []), do: match?({:ok, _}, Ecto.UUID.cast(id))

  defp valid?([action, id], opts) when action in ["reconcile", "cancel-unstarted"],
    do:
      Enum.sort(Keyword.keys(opts)) == [:by, :command_id] and match?({:ok, _}, Ecto.UUID.cast(id)) and
        match?({:ok, _}, Ecto.UUID.cast(opts[:command_id]))

  defp valid?(_, _), do: false
end
