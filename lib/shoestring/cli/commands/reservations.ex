defmodule Shoestring.CLI.Commands.Reservations do
  @moduledoc "`shoestring reservations`: inspect reservations and queue evidence-backed recovery."

  alias Shoestring.CLI.{Command, Refusal}
  alias Shoestring.Cobbler.{ReservationControl, ReservationInspection}

  @help """
  shoestring reservations list [--goal UUID] [--all] [--limit N]
  shoestring reservations show RESERVATION_ID
  shoestring reservations reconcile RESERVATION_ID --command-id UUID --by human:NAME
  shoestring reservations cancel-unstarted RESERVATION_ID --command-id UUID --by human:NAME

  Read commands expose durable ownership, configured allowances and provider
  evidence without starting providers. Recovery requests are queued for the
  running service; inspect `show` for their durable results. A command ID is
  immutable and replayable. Use a new ID for a later reconciliation observation.
  Overdue reservations still consume capacity. Cancel-unstarted only fences
  provably unused intent; possibly started effects remain held. It never kills
  or replaces a process. Live cancellation stays with the supervising Elf.
  Output is JSON on stdout (`--json` is accepted and changes nothing).
  """

  def help, do: @help

  def run(args, context) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          goal: [:string, :keep],
          all: [:boolean, :keep],
          limit: [:integer, :keep],
          command_id: [:string, :keep],
          by: [:string, :keep],
          json: :boolean
        ]
      )

    opts = Keyword.delete(opts, :json)

    with true <- invalid == [],
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- valid?(positional, opts) do
      context.with_repo.(fn _ ->
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
          {:ok, output} -> Command.json(context, output)
          {:error, reason} -> Refusal.refuse!("Reservation request refused: #{inspect(reason)}")
        end
      end)
    else
      _ -> Refusal.usage!("reservations")
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
