defmodule Shoestring.SessionTeamTest do
  @moduledoc """
  A session's team (iteration 16 package T): the grant records the agents a
  session started with; dispatches name an agent and stay within its limit.
  A real temporary Git repository, Oban in manual testing mode, no provider.
  """
  use Shoestring.DataCase, async: false
  import Shoestring.ConfigurationFixtures

  alias Shoestring.{Agents, AgentProfiles, Coordinator, Dispatches, Grants, ModelCatalog}
  alias Shoestring.CLI.Commands.Dispatch

  @brief "EXPLORE - where is the sum computed?\nContract: findings with file:line evidence.\n"

  setup do
    repo = Path.join(System.tmp_dir!(), "shoestring-team-#{Ecto.UUID.generate()}")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    return a + b\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(repo)

    for {provider, model} <- [{"claude", "opus"}, {"codex", "gpt-6-luna"}, {"codex", "gpt-6-sol"}],
        do: {:ok, _} = ModelCatalog.add(provider, model)

    {:ok, team} =
      AgentProfiles.create(
        agent_attrs(%{
          "roles" => [
            %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
            %{"name" => "Explorer", "provider" => "codex", "model" => "gpt-6-sol"},
            %{"name" => "Worker", "provider" => "codex", "model" => "gpt-6-luna"},
            %{"name" => "Reviewer", "provider" => "claude", "model" => "opus"}
          ]
        })
      )

    explorer = Agents.get(Enum.find(team.roles, &(&1.name == "Explorer")).agent_id)
    {:ok, explorer} = Agents.update(explorer, %{"max_minutes" => 10})
    team = AgentProfiles.get(team.id)

    {:ok, grant} =
      Grants.create(
        %{
          session_id: "team-s1",
          repository_root: facts.root,
          models: ["codex:gpt-6-sol", "codex:gpt-6-luna", "claude:opus"],
          purposes: ["explore", "implement", "review"],
          max_dispatches: 6,
          max_parallel: 3,
          max_total_seconds: 7_200,
          max_dispatch_seconds: 3_600,
          unread_usage: 0,
          team: Agents.snapshot(team)
        },
        "human:operator"
      )

    %{repo: repo, grant: grant, explorer: explorer}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp request(ctx, fields) do
    Dispatch.build_request(
      Map.merge(
        %{
          session_id: "team-s1",
          repository: ctx.repo,
          purpose: "explore",
          title: "Where is the sum",
          brief: @brief
        },
        fields
      )
    )
  end

  test "the grant keeps the team the session started with; later edits do not change it", ctx do
    %{"team" => "builder", "agents" => agents} = ctx.grant.team

    assert %{"slug" => slug, "kind" => "explorer", "model" => "gpt-6-sol", "max_minutes" => 10} =
             Enum.find(agents, &(&1["role"] == "Explorer"))

    assert slug == ctx.explorer.slug
    {:ok, _} = Agents.update(ctx.explorer, %{"max_minutes" => 120})
    assert Grants.get(ctx.grant.id).team == ctx.grant.team
  end

  test "a dispatch names an agent by its job or slug; its model and limit are used", ctx do
    assert {:ok, request} = request(ctx, %{agent: "explorer"})
    assert {request.provider, request.model} == {"codex", "gpt-6-sol"}
    assert {:ok, dispatch, :recorded} = Dispatches.create(request)
    assert dispatch.agent == ctx.explorer.slug
    # No minutes asked for: the agent's limit, under the grant's.
    assert dispatch.max_duration_seconds == 600
    assert Dispatch.summary(dispatch)["agent"] == ctx.explorer.slug

    assert {:ok, by_slug} = request(ctx, %{agent: ctx.explorer.slug, request_id: "by-slug"})
    assert by_slug.model == "gpt-6-sol"
  end

  test "an agent's limit bounds its dispatches however they are named; only the person raises it",
       ctx do
    {:ok, over} = request(ctx, %{agent: "explorer", minutes: 20})
    over = %{over | seconds: 20 * 60}

    assert {:error, {:over_agent_limit, slug, 10}} = Dispatches.create(over)
    assert slug == ctx.explorer.slug
    assert Dispatch.message({:over_agent_limit, slug, 10}, over) =~ "ask the person to raise"

    # Named by its model instead, the same agent and limit.
    {:ok, by_worker} = request(ctx, %{worker: "codex:gpt-6-sol", minutes: 20})
    assert {:error, {:over_agent_limit, _, 10}} = Dispatches.create(by_worker)
    {:ok, within} = request(ctx, %{worker: "codex:gpt-6-sol", minutes: 5})
    assert {:ok, dispatch, :recorded} = Dispatches.create(within)
    assert {dispatch.agent, dispatch.max_duration_seconds} == {ctx.explorer.slug, 300}

    # An agent with no limit of its own: the grant's per-dispatch limit.
    {:ok, implementer} = request(ctx, %{worker: "codex:gpt-6-luna", request_id: "free"})
    assert {:ok, free, :recorded} = Dispatches.create(implementer)
    assert free.max_duration_seconds == 3_600
  end

  test "an unknown agent, both names, or an agent of another job is refused", ctx do
    assert {:error, message} = request(ctx, %{agent: "pilot"})
    assert message =~ "No agent \"pilot\"" and message =~ ctx.explorer.slug

    assert {:error, "Name the agent or the worker, not both"} =
             request(ctx, %{agent: "explorer", worker: "codex:gpt-6-sol"})

    {:ok, reviewer} = request(ctx, %{agent: "reviewer"})
    assert {:error, {:agent_purpose, _, "reviewer", "explore"}} = Dispatches.create(reviewer)

    {:ok, _} = Grants.revoke(ctx.grant, "human:operator")
    assert {:error, message} = request(ctx, %{agent: "explorer"})
    assert message =~ "no team"
  end

  test "the coordinator is told its team's agents and their limits", ctx do
    text =
      Coordinator.conversation_instructions(%{
        session: "team-s1",
        grant: ctx.grant,
        roles: [],
        agent_instructions: nil
      })

    assert text =~ "`#{ctx.explorer.slug}`: Explorer, codex:gpt-6-sol; at most 10 minutes"
    assert text =~ "Implementer, codex:gpt-6-luna; no time limit of its own"
    refute text =~ "Coordinator, claude:opus"
  end

  # Live 2026-10-31: told "every change gets a reviewer", a coordinator twice
  # refused the person's "no reviewer". The wording is all this pins; whether a
  # model follows it is not something a hermetic test can show.
  test "review is the coordinator's default, and the person's choice", ctx do
    conversation =
      Coordinator.conversation_instructions(%{
        session: "team-s1",
        grant: ctx.grant,
        roles: [],
        agent_instructions: nil
      })

    external =
      Coordinator.instructions(%{
        session: "team-s1",
        grant: ctx.grant,
        roles: [],
        agent_instructions: nil,
        command: "shoestring"
      })

    for text <- [conversation, external] do
      text = String.replace(text, ~r/\s+/, " ")
      assert text =~ "Shoestring does not require one: the person decides"
      assert text =~ "dispatch it without"
      refute text =~ "Every change gets a reviewer"
    end
  end
end
