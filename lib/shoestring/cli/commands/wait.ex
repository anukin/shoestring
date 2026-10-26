defmodule Shoestring.CLI.Commands.Wait do
  @moduledoc "`shoestring wait`: block until one of a coordinator's dispatches settles."

  alias Shoestring.Dispatches
  alias Shoestring.CLI.{Command, Refusal}
  alias Shoestring.CLI.Commands.Dispatch

  @help """
  shoestring wait DISPATCH... [--timeout MINUTES] [--json]

  Returns as soon as one of the dispatches settles — completed, cancelled,
  failed to start, held for a usage confirmation (`held`), or waiting for a
  person (`needs_you`) — and prints it with
  the others' states. It reads Shoestring's records every few seconds and
  makes no model call. After --timeout minutes (default 30, at most 1440) it
  returns with `timed_out` and exit status 3; nothing about the dispatches
  changes either way. A coordinator can run it in the background to be woken
  when it exits. Output is JSON on stdout.
  """

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [timeout: :integer, json: :boolean]) do
      {opts, [_ | _] = ids, []} ->
        minutes = Keyword.get(opts, :timeout, 30)
        unless minutes in 1..1440, do: Refusal.refuse!("--timeout is 1 to 1440 minutes")

        context.with_repo.(fn _repo ->
          dispatches =
            Enum.map(ids, &(Dispatches.get(&1) || Refusal.refuse!("Dispatch not found: #{&1}")))

          deadline =
            System.monotonic_time(:millisecond) + Map.get(context, :wait_ms, minutes * 60_000)

          poll(dispatches, deadline, Map.get(context, :poll_ms, 2_000), context)
        end)

      _ ->
        Refusal.usage!("wait")
    end
  end

  defp poll(dispatches, deadline, interval, context) do
    summaries = Enum.map(dispatches, &Dispatch.summary/1)

    case Enum.find(summaries, &Dispatches.settled?(&1["state"])) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          Command.json(context, %{"timed_out" => true, "dispatches" => summaries})
          3
        else
          Process.sleep(interval)
          poll(dispatches, deadline, interval, context)
        end

      settled ->
        Command.json(context, %{
          "settled" => settled,
          "others" => Enum.reject(summaries, &(&1["dispatch_id"] == settled["dispatch_id"]))
        })

        :ok
    end
  end
end
