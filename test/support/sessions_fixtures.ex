defmodule Shoestring.SessionsFixtures do
  @moduledoc """
  A coordinator session for the Sessions page's tests: a temporary Git
  repository, a grant with a team, a conversation and dispatches, plus
  normalized worker events shaped as `Shoestring.Elves.Elf` records them.
  No provider, network or listener.
  """

  import Ecto.Query

  alias Shoestring.{Conversations, Dispatches, Grants, ModelCatalog, Repo, Trajectory}
  alias Shoestring.Trajectory.TrajectoryEvent

  @brief "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"

  @team %{
    "team" => "builders",
    "agents" => [
      %{
        "role" => "Coordinator",
        "slug" => "lead",
        "name" => "Lead",
        "kind" => "coordinator",
        "provider" => "claude",
        "model" => "claude-test-model"
      },
      %{
        "role" => "Worker",
        "slug" => "builder",
        "name" => "Builder",
        "kind" => "implementer",
        "provider" => "codex",
        "model" => "gpt-6-luna"
      },
      %{
        "role" => "Explorer",
        "slug" => "scout",
        "name" => "Scout",
        "kind" => "explorer",
        "provider" => "codex",
        "model" => "gpt-6-luna"
      }
    ]
  }

  def team, do: @team

  @doc "A session with a grant, a team and (unless `conversation: false`) a conversation."
  def session(opts \\ []) do
    session = "sess-#{System.unique_integer([:positive])}"
    repo = repository()
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")

    {:ok, grant} =
      Grants.create(
        %{
          session_id: session,
          repository_root: repo,
          models: ["codex:gpt-6-luna"],
          purposes: Grants.purposes(),
          max_dispatches: 6,
          max_parallel: 2,
          max_total_seconds: 4 * 3600,
          max_dispatch_seconds: 3600,
          unread_usage: 0,
          max_turns: 10,
          team: @team
        },
        "human:operator"
      )

    conversation =
      if Keyword.get(opts, :conversation, true) do
        {:ok, conversation} =
          Conversations.open(%{
            session_id: session,
            provider: "claude",
            model: "claude-test-model",
            effort: nil,
            repository_root: repo
          })

        conversation
      end

    %{session: session, repo: repo, grant: grant, conversation: conversation}
  end

  defp repository do
    dir = Path.join(System.tmp_dir!(), "shoestring-sessions-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(dir, "test"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(dir, "test/test_calc.py"), "import unittest\n")
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "."])
    git!(dir, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    {root, 0} = System.cmd("git", ["-C", dir, "rev-parse", "--show-toplevel"])
    String.trim(root)
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  @doc "A dispatch of `purpose` in the session, for `agent` (a team slug) or for none (nil)."
  def dispatch_fixture(ctx, purpose, agent, title) do
    {:ok, dispatch, :recorded} =
      Dispatches.create(%{
        session_id: ctx.session,
        request_id: "req-#{System.unique_integer([:positive])}",
        purpose: purpose,
        provider: "codex",
        model: "gpt-6-luna",
        title: title,
        brief: @brief,
        repository: ctx.repo
      })

    # Set as given, nil included: Shoestring would otherwise pick the team's
    # agent for the job, and a dispatch from the command line may have none.
    Repo.update_all(from(d in Dispatches.Dispatch, where: d.id == ^dispatch.id),
      set: [agent: agent]
    )

    Dispatches.get(dispatch.id)
  end

  @doc """
  Appends one normalized worker event to `goal_id`, as the Elf persists it
  (`harness.event_recorded`, namespaced extensions), and returns it.
  """
  def worker_event(goal_id, kind, extensions, at \\ DateTime.utc_now()) do
    run_id = Ecto.UUID.generate()

    sequence =
      (Repo.one(from e in TrajectoryEvent, where: e.goal_id == ^goal_id, select: max(e.sequence)) ||
         0) + 1

    Repo.insert!(%TrajectoryEvent{
      goal_id: goal_id,
      run_id: run_id,
      sequence: sequence,
      type: "harness.event_recorded",
      actor: "elf",
      occurred_at: at,
      schema_version: 1,
      payload: %{
        "run_id" => run_id,
        "kind" => kind,
        "ordinal" => sequence,
        "source_event_id" => "fixture-#{sequence}",
        "occurred_at" => DateTime.to_iso8601(at),
        "extensions" => extensions
      }
    })
  end

  @doc "Tells subscribers of the goal that `event` was committed, as the writer does."
  def broadcast(event),
    do:
      Phoenix.PubSub.broadcast(
        Shoestring.PubSub,
        Trajectory.topic(event.goal_id),
        {:trajectory_event_committed, event}
      )

  @doc "Appends a conversation event to the conversation's goal."
  def conversation_event(conversation, type, payload, at \\ DateTime.utc_now()) do
    sequence =
      (Repo.one(
         from e in TrajectoryEvent, where: e.goal_id == ^conversation.id, select: max(e.sequence)
       ) || 0) + 1

    Repo.insert!(%TrajectoryEvent{
      goal_id: conversation.id,
      sequence: sequence,
      type: type,
      actor: "test",
      occurred_at: at,
      schema_version: 1,
      payload: payload
    })
  end
end
