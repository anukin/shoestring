defmodule Shoestring.Sessions do
  @moduledoc """
  Coordinator sessions as the Sessions page shows them: each session's
  grants, conversations, team and dispatches, read from their own records.
  Reading a session never advances or changes anything.

  A session is every record that carries its `session_id`: its grants, its
  conversations (one per handoff) and its dispatches. Its last activity is
  the newest `updated_at` among them, so a long session that is still
  working stays listed however long ago it started.
  """

  import Ecto.Query

  alias Shoestring.{Agents, Harnesses, PermissionAsks, Repo}
  alias Shoestring.Conversations.Conversation
  alias Shoestring.Dispatches.Dispatch
  alias Shoestring.Grants.Grant

  @final ~w(completed cancelled failed failed_to_start)
  # Not working: finished, or waiting on the person.
  @settled @final ++ ~w(held needs_you)

  @doc "Dispatch states after which a dispatch changes no more."
  def final_states, do: @final

  @doc """
  The sessions active in the last `days` days, newest activity first, and
  how many older sessions are hidden. A session a worker's ask is waiting
  in stays listed however old it is.

  Each listed session counts its dispatches by the state
  `Shoestring.Dispatches.state/2` derives (a stored dispatch is only
  `started` while it runs, holds or completes): `working`, `held`, `stopped` (waiting for the person), `failed`,
  and `asks` waiting. `counts: false` leaves those out, for a caller that
  needs only which sessions are listed.
  """
  def recent(days, now \\ DateTime.utc_now(), opts \\ []) when is_integer(days) and days > 0 do
    since = DateTime.add(now, -days * 86_400)
    asking = MapSet.new(PermissionAsks.pending(), & &1.session_id)

    {shown, hidden} =
      Enum.split_with(
        summaries(),
        &(DateTime.compare(&1.last_at, since) != :lt or MapSet.member?(asking, &1.session_id))
      )

    shown = if Keyword.get(opts, :counts, true), do: Enum.map(shown, &with_counts/1), else: shown
    %{sessions: shown, hidden: length(hidden)}
  end

  defp with_counts(summary) do
    states =
      summary.session_id
      |> Shoestring.Dispatches.list()
      |> Enum.map(&Shoestring.Dispatches.state/1)
      |> Enum.frequencies()

    count = &Map.get(states, &1, 0)

    Map.merge(summary, %{
      working: Enum.sum(for {state, n} <- states, state not in @settled, do: n),
      held: count.("held"),
      stopped: count.("needs_you"),
      failed: count.("failed") + count.("failed_to_start"),
      asks: length(PermissionAsks.pending(summary.session_id))
    })
  end

  defp summaries do
    grants = Repo.all(from g in Grant, order_by: [g.inserted_at, g.id])
    conversations = Repo.all(from c in Conversation, order_by: [c.inserted_at, c.id])

    dispatches =
      Repo.all(
        from d in Dispatch,
          group_by: [d.session_id, d.state],
          select: {d.session_id, d.state, count(d.id), max(d.updated_at)}
      )

    ids =
      Enum.map(grants, & &1.session_id) ++
        Enum.map(conversations, & &1.session_id) ++ Enum.map(dispatches, &elem(&1, 0))

    ids
    |> Enum.uniq()
    |> Enum.map(fn id ->
      summary(
        id,
        Enum.filter(grants, &(&1.session_id == id)),
        Enum.filter(conversations, &(&1.session_id == id)),
        for({^id, state, count, at} <- dispatches, do: {state, count, at})
      )
    end)
    |> Enum.sort_by(& &1.last_at, {:desc, DateTime})
  end

  defp summary(id, grants, conversations, dispatches) do
    stamps =
      Enum.flat_map(grants ++ conversations, &[&1.inserted_at, &1.updated_at]) ++
        Enum.map(dispatches, fn {_state, _count, at} -> stamp(at) end)

    total = dispatches |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    %{
      session_id: id,
      repository_root: repository_root(grants, conversations),
      coordinator: coordinator(List.last(conversations)),
      started_at: stamps |> Enum.reject(&is_nil/1) |> Enum.min(DateTime, fn -> nil end),
      last_at: stamps |> Enum.reject(&is_nil/1) |> Enum.max(DateTime),
      dispatches: total
    }
  end

  # SQLite hands an aggregate back as its stored text.
  defp stamp(%DateTime{} = at), do: at

  defp stamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, value, _} ->
        value

      _ ->
        case NaiveDateTime.from_iso8601(at) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp stamp(_at), do: nil

  defp repository_root(grants, conversations) do
    case List.last(grants) || List.last(conversations) do
      nil -> nil
      record -> record.repository_root
    end
  end

  defp coordinator(nil), do: nil

  defp coordinator(%Conversation{} = c),
    do: %{provider: c.provider, model: c.model, effort: c.effort}

  @doc """
  One session: its newest grant and team, its conversations (oldest
  first, one per handoff) and its dispatches (oldest first). nil when no
  record carries the id.
  """
  def get(session_id) when is_binary(session_id) do
    grants =
      Repo.all(
        from g in Grant, where: g.session_id == ^session_id, order_by: [g.inserted_at, g.id]
      )

    conversations =
      Repo.all(
        from c in Conversation,
          where: c.session_id == ^session_id,
          order_by: [c.inserted_at, c.id]
      )

    dispatches = Shoestring.Dispatches.list(session_id)

    if grants == [] and conversations == [] and dispatches == [] do
      nil
    else
      grant = List.last(grants)

      %{
        session_id: session_id,
        grant: grant,
        team: grant && grant.team,
        repository_root: repository_root(grants, conversations),
        conversations: conversations,
        dispatches: dispatches
      }
    end
  end

  def get(_session_id), do: nil

  @doc """
  The session's agents, each with its dispatches (oldest first): the
  coordinator first when the session has a conversation, then the team's
  agents in the team's order, then one group for each worker that ran
  dispatches no team agent names (a dispatch made from the command line
  without `--agent`). Each has a `key` that is safe in a URL.
  """
  def agents(%{} = session) do
    team = (session.team || %{})["agents"] || []
    {leads, workers} = Enum.split_with(team, &(&1["kind"] == "coordinator"))
    slugs = MapSet.new(workers, & &1["slug"])

    coordinator =
      case session.conversations do
        [] ->
          []

        conversations ->
          current = List.last(conversations)
          lead = List.first(leads)

          [
            %{
              key: (lead && lead["slug"]) || "coordinator",
              name: (lead && lead["name"]) || "Coordinator",
              kind: "coordinator",
              provider: current.provider,
              model: current.model,
              dispatches: []
            }
          ]
      end

    named =
      Enum.map(workers, fn agent ->
        %{
          key: agent["slug"],
          name: agent["name"] || agent["slug"],
          kind: agent["kind"],
          provider: agent["provider"],
          model: agent["model"],
          dispatches: Enum.filter(session.dispatches, &(&1.agent == agent["slug"]))
        }
      end)

    unnamed =
      session.dispatches
      |> Enum.reject(&(&1.agent && MapSet.member?(slugs, &1.agent)))
      |> Enum.group_by(&{Agents.purpose_kind(&1.purpose), &1.provider, &1.model})
      |> Enum.sort_by(fn {_key, [first | _]} -> {first.inserted_at, first.id} end)
      |> Enum.map(fn {{kind, provider, model}, dispatches} ->
        %{
          key: unnamed_key(kind, provider, model),
          name: "#{kind_label(kind)} (#{Harnesses.name(provider)})",
          kind: kind,
          provider: provider,
          model: model,
          dispatches: dispatches
        }
      end)

    coordinator ++ named ++ unnamed
  end

  defp unnamed_key(kind, provider, model) do
    "#{kind}-#{provider}-#{model}"
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> then(&("worker-" <> &1))
  end

  defp kind_label(nil), do: "Worker"

  defp kind_label(kind) do
    Agents.label(kind)
  rescue
    KeyError -> "Worker"
  end
end
