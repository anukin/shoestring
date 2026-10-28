defmodule Shoestring.CLI.Commands.Grants do
  @moduledoc "`shoestring grants`: list, show, widen or revoke coordinator grants."

  alias Shoestring.Grants
  alias Shoestring.CLI.{Command, Refusal, WorkLoop}
  alias Shoestring.CLI.Commands.Grant

  @help """
  shoestring grants list [--json]
  shoestring grants show GRANT [--json]
  shoestring grants extend GRANT [--dispatches N] [--hours H] [--unread-usage N]
      [--turns N] [--models PROVIDER:MODEL,...] [--purposes P,...] [--max-parallel N]
      [--by human:NAME]
  shoestring grants revoke GRANT [--by human:NAME]

  `list` and `show` print each grant, what its dispatches use against its
  limits and its history. `extend` adds to a grant's attempts, hours,
  unread-usage dispatches, coordinator turns, models or purposes, or sets
  how many may run at once. `revoke` stops new dispatches and turns under
  it; work already running keeps running. Both are a person's decision: they show the change, ask, and
  refuse without a terminal. Output is JSON on stdout.
  """

  @switches [
    dispatches: :integer,
    hours: :integer,
    unread_usage: :integer,
    turns: :integer,
    models: :string,
    purposes: :string,
    max_parallel: :integer,
    by: :string,
    json: :boolean
  ]

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {_opts, ["list"], []} ->
        context.with_repo.(fn _repo ->
          Command.json(context, Enum.map(Grants.list(), &Grant.show/1))
        end)

      {_opts, ["show", id], []} ->
        context.with_repo.(fn _repo -> Command.json(context, detail(grant!(id))) end)

      {opts, ["extend", id], []} ->
        Grant.terminal!(context)
        context.with_repo.(fn _repo -> extend(grant!(id), opts, context) end)

      {opts, ["revoke", id], []} ->
        Grant.terminal!(context)
        context.with_repo.(fn _repo -> revoke(grant!(id), opts, context) end)

      _ ->
        Refusal.usage!("grants")
    end
  end

  defp extend(grant, opts, context) do
    changes =
      %{}
      |> put(:add_dispatches, opts[:dispatches])
      |> put(:add_seconds, opts[:hours] && opts[:hours] * 3600)
      |> put(:add_unread_usage, opts[:unread_usage])
      |> put(:add_turns, opts[:turns])
      |> put(:add_models, opts[:models] && Grant.list(opts[:models]))
      |> put(:add_purposes, opts[:purposes] && Grant.list(opts[:purposes]))
      |> put(:max_parallel, opts[:max_parallel])

    if changes == %{}, do: Refusal.usage!("grants")

    context.shell.error(
      "Widen grant #{grant.id} (session #{grant.session_id}): #{describe(changes)}"
    )

    unless Grant.confirmed?(context, "Extend it? [y/N] "), do: Refusal.refuse!("Not changed.")

    case Grants.extend(grant, changes, opts[:by] || WorkLoop.default_human()) do
      {:ok, grant} -> Command.json(context, detail(grant))
      {:error, reason} -> Refusal.refuse!("Not changed: #{Grant.reason_text(reason)}")
    end
  end

  defp revoke(grant, opts, context) do
    context.shell.error(
      "Revoke grant #{grant.id} (session #{grant.session_id})? New dispatches stop; running work continues."
    )

    unless Grant.confirmed?(context, "Revoke it? [y/N] "), do: Refusal.refuse!("Not changed.")

    case Grants.revoke(grant, opts[:by] || WorkLoop.default_human()) do
      {:ok, grant} -> Command.json(context, detail(grant))
      {:error, reason} -> Refusal.refuse!("Not changed: #{Grant.reason_text(reason)}")
    end
  end

  defp detail(grant) do
    Map.put(
      Grant.show(grant),
      "history",
      for event <- Grants.events(grant.id) do
        %{
          "kind" => event.kind,
          "actor" => event.actor,
          "at" => event.occurred_at,
          "payload" => event.payload
        }
      end
    )
  end

  defp grant!(id),
    do: Grants.get(id) || Refusal.refuse!("Grant not found. See shoestring grants list.")

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp describe(changes) do
    Enum.map_join(changes, ", ", fn
      {:add_dispatches, n} -> "+#{n} attempts"
      {:add_seconds, s} -> "+#{div(s, 3600)} hours"
      {:add_unread_usage, n} -> "+#{n} unread-usage dispatches"
      {:add_turns, n} -> "+#{n} coordinator turns"
      {:add_models, models} -> "models #{Enum.join(models, ", ")}"
      {:add_purposes, purposes} -> "purposes #{Enum.join(purposes, ", ")}"
      {:max_parallel, n} -> "#{n} at once"
    end)
  end
end
