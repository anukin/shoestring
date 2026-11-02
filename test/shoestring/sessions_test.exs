defmodule Shoestring.SessionsTest do
  @moduledoc "Which sessions the Sessions page lists, and how a session's agents are grouped."
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.SessionsFixtures

  alias Shoestring.{Repo, Sessions}
  alias Shoestring.Conversations.Conversation
  alias Shoestring.Dispatches.Dispatch
  alias Shoestring.Grants.Grant

  defp age!(session, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds)

    for schema <- [Grant, Conversation, Dispatch] do
      Repo.update_all(from(r in schema, where: r.session_id == ^session),
        set: [inserted_at: at, updated_at: at]
      )
    end
  end

  test "a session is listed while its newest record is within the days asked for" do
    ctx = session()
    ids = fn days -> Enum.map(Sessions.recent(days).sessions, & &1.session_id) end

    assert ctx.session in ids.(7)

    # Just under eight days since anything happened: hidden at 7, shown at 8.
    age!(ctx.session, 8 * 86_400 - 60)
    refute ctx.session in ids.(7)
    assert Sessions.recent(7).hidden == 1
    assert ctx.session in ids.(8)
    assert Sessions.recent(8).hidden == 0
  end

  test "a session that started long ago but is still working stays listed" do
    ctx = session()
    age!(ctx.session, 30 * 86_400)
    refute ctx.session in Enum.map(Sessions.recent(7).sessions, & &1.session_id)

    dispatch_fixture(ctx, "implement", "builder", "One change")
    [listed] = Sessions.recent(7).sessions
    assert listed.session_id == ctx.session
    assert listed.dispatches == 1
    assert Path.basename(listed.repository_root) == Path.basename(ctx.repo)
    assert listed.coordinator.provider == "claude"
    assert DateTime.compare(listed.started_at, listed.last_at) == :lt
  end

  test "the list counts dispatches by their derived state: a held one needs you, not working" do
    ctx = session()
    held_fixture(ctx)
    [listed] = Enum.filter(Sessions.recent(7).sessions, &(&1.session_id == ctx.session))

    # Its stored state is `started`; only its derived state says it is held.
    assert {listed.dispatches, listed.held, listed.working, listed.asks} == {1, 1, 0, 0}
  end

  test "a session a worker's ask waits in stays listed however old it is" do
    ctx = session()
    builder = dispatch_fixture(ctx, "implement", "builder", "One change")
    age!(ctx.session, 30 * 86_400)
    refute ctx.session in Enum.map(Sessions.recent(7).sessions, & &1.session_id)

    waiting_ask(builder)
    [listed] = Sessions.recent(7).sessions
    assert {listed.session_id, listed.asks} == {ctx.session, 1}
  end

  test "agents: the coordinator, then the team's agents in order, then workers no agent names" do
    ctx = session()
    implement = dispatch_fixture(ctx, "implement", "builder", "One change")
    explore = dispatch_fixture(ctx, "explore", nil, "Where is add?")

    groups = Sessions.agents(Sessions.get(ctx.session))

    assert Enum.map(groups, & &1.key) == [
             "lead",
             "builder",
             "scout",
             "worker-explorer-codex-gpt-6-luna"
           ]

    [lead, builder, scout, unnamed] = groups
    assert {lead.kind, lead.name, lead.dispatches} == {"coordinator", "Lead", []}
    assert Enum.map(builder.dispatches, & &1.id) == [implement.id]
    assert scout.dispatches == []
    assert unnamed.name == "Explorer (Codex)"
    assert Enum.map(unnamed.dispatches, & &1.id) == [explore.id]
  end

  test "a session with no conversation has no coordinator, and an unknown one is nil" do
    ctx = session(conversation: false)
    assert Enum.map(Sessions.agents(Sessions.get(ctx.session)), & &1.key) == ["builder", "scout"]
    assert Sessions.get("no-such-session") == nil
  end
end
