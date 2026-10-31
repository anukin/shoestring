defmodule Shoestring.DispatchChainTest do
  @moduledoc """
  Dependent dispatches (iteration 16 C1) up to their start: an IMPLEMENT that
  follows another is recorded `chained` with its room reserved, waits while
  that one is unfinished, and is called off, its room released, when that
  one is cancelled or its grant revoked. A real temporary Git repository,
  Oban in manual testing mode, no service, provider or network. Starting
  from the followed commit is covered end to end in
  `Shoestring.DispatchIntegrationTest`.
  """
  use Shoestring.DataCase, async: false
  import Ecto.Query

  alias Shoestring.{Dispatches, Grants, ModelCatalog, Repo}
  alias Shoestring.CLI.Commands.{Dispatch, Runs}
  alias Shoestring.Cobbler.PlanCancellationWorker
  alias Shoestring.Dispatches.ChainWorker

  @brief """
  IMPLEMENT - make add() return the sum of its arguments
  Contract: test/test_calc.py passes.
  """

  setup do
    repo = Path.join(System.tmp_dir!(), "shoestring-chain-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(repo)
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")

    {:ok, grant} =
      Grants.create(
        %{
          session_id: "s1",
          repository_root: facts.root,
          models: ["codex:gpt-6-luna"],
          purposes: ["implement", "explore"],
          max_dispatches: 3,
          # One at a time: a chained dispatch does not run beside the one it
          # follows, so it is not refused for parallel room.
          max_parallel: 1,
          max_total_seconds: 7_200,
          max_dispatch_seconds: 1_800,
          unread_usage: 0
        },
        "human:operator"
      )

    {:ok, first, :recorded} = Dispatches.create(request(repo, %{request_id: "first"}))
    %{repo: repo, grant: grant, first: first}
  end

  defp request(repo, overrides) do
    Map.merge(
      %{
        session_id: "s1",
        purpose: "implement",
        provider: "codex",
        model: "gpt-6-luna",
        title: "Make add return the sum of its arguments",
        brief: @brief,
        repository: repo
      },
      overrides
    )
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp chain_job!(dispatch) do
    Repo.one!(
      from j in Oban.Job,
        where:
          j.worker == "Shoestring.Dispatches.ChainWorker" and
            fragment("json_extract(?, '$.dispatch_id')", j.args) == ^dispatch.id
    )
  end

  defp executions,
    do:
      Repo.aggregate(
        from(j in Oban.Job, where: j.worker == "Shoestring.Cobbler.PlanExecutionWorker"),
        :count
      )

  defp cancel_execution!(dispatch) do
    {:ok, _} = Dispatches.cancel(dispatch, "Superseded.")

    for job <-
          Repo.all(
            from j in Oban.Job, where: j.worker == "Shoestring.Cobbler.PlanCancellationWorker"
          ),
        do: PlanCancellationWorker.perform(job)

    assert Dispatches.state(dispatch) == "cancelled"
  end

  test "a dispatch that follows another waits, recorded with its room reserved; nothing starts",
       ctx do
    assert Dispatches.state(ctx.first) == "queued"

    assert {:ok, second, :recorded} =
             Dispatches.create(
               request(ctx.repo, %{request_id: "second", after_dispatch: ctx.first.id})
             )

    assert second.state == "chained"
    assert second.after_dispatch_id == ctx.first.id
    assert Dispatches.state(second) == "chained"

    # Reserved, not running: the grant's one parallel place stays the first's.
    usage = Dispatches.usage(ctx.grant)
    assert usage.attempts == 2
    assert usage.running == 1
    assert usage.seconds == 2 * 1800

    # Nothing of it started: no execution, and its job waits.
    assert executions() == 1
    assert Repo.get(Shoestring.Trajectory.Goal, second.goal_id) == nil
    assert {:snooze, 30} = ChainWorker.perform(chain_job!(second))
    assert Dispatches.get(second.id).state == "chained"
    assert executions() == 1

    # The coordinator sees what it follows and that nothing is to be done.
    shown = Runs.detail(Dispatches.get(second.id))
    assert shown["after"] == ctx.first.id
    assert shown["state"] == "chained"
    assert shown["next"] =~ "Follows #{ctx.first.id} (queued): starts by itself"

    # A retry returns it; the same request id following nothing is another request.
    assert {:ok, replayed, :replayed} =
             Dispatches.create(
               request(ctx.repo, %{request_id: "second", after_dispatch: ctx.first.id})
             )

    assert replayed.id == second.id

    assert {:error, :request_id_conflict} =
             Dispatches.create(request(ctx.repo, %{request_id: "second"}))
  end

  test "cancelling the one it follows calls it off and releases its room", ctx do
    {:ok, second, :recorded} =
      Dispatches.create(request(ctx.repo, %{request_id: "second", after_dispatch: ctx.first.id}))

    cancel_execution!(ctx.first)
    assert :ok = ChainWorker.perform(chain_job!(second))

    second = Dispatches.get(second.id)
    assert {second.state, second.error} == {"cancelled", "after_cancelled"}
    assert Dispatches.state(second) == "cancelled"
    assert Dispatches.usage(ctx.grant).attempts == 1
    assert executions() == 1
    assert Runs.detail(second)["next"] =~ "the dispatch it followed is cancelled"

    # It never starts afterwards.
    assert Dispatches.follow(second) == :none
  end

  test "cancelling it while it waits releases its room; it never starts", ctx do
    {:ok, second, :recorded} =
      Dispatches.create(request(ctx.repo, %{request_id: "second", after_dispatch: ctx.first.id}))

    assert {:ok, cancelled} = Dispatches.cancel(second, "Not needed.")
    assert {cancelled.state, cancelled.error} == {"cancelled", "cancelled"}
    assert Dispatches.usage(ctx.grant).attempts == 1
    assert :ok = ChainWorker.perform(chain_job!(second))
    assert Dispatches.get(second.id).state == "cancelled"
    assert executions() == 1
  end

  test "a revoked grant calls it off", ctx do
    {:ok, second, :recorded} =
      Dispatches.create(request(ctx.repo, %{request_id: "second", after_dispatch: ctx.first.id}))

    {:ok, _} = Grants.revoke(ctx.grant, "human:operator")
    assert Dispatches.follow(Dispatches.get(second.id)) == {:called_off, "grant_revoked"}
    assert Runs.detail(Dispatches.get(second.id))["next"] =~ "its grant was revoked"
  end

  test "only an IMPLEMENT of this session that can still complete is followed", ctx do
    follow = fn overrides ->
      Dispatches.create(request(ctx.repo, Map.merge(%{request_id: "x"}, overrides)))
    end

    assert {:error, :after_not_found} = follow.(%{after_dispatch: Ecto.UUID.generate()})
    assert {:error, :after_not_found} = follow.(%{after_dispatch: "not-an-id"})

    assert {:error, :after_implement_only} =
             follow.(%{purpose: "explore", after_dispatch: ctx.first.id})

    {:ok, other} =
      Grants.create(
        %{
          session_id: "s2",
          repository_root: ctx.grant.repository_root,
          models: ["codex:gpt-6-luna"],
          purposes: ["implement"],
          max_dispatches: 1,
          max_parallel: 1,
          max_total_seconds: 3_600,
          max_dispatch_seconds: 1_800,
          unread_usage: 0
        },
        "human:operator"
      )

    assert {:error, :after_not_found} =
             follow.(%{session_id: other.session_id, after_dispatch: ctx.first.id})

    cancel_execution!(ctx.first)

    assert {:error, {:after_unusable, "cancelled"}} = follow.(%{after_dispatch: ctx.first.id})
    assert Repo.aggregate(Shoestring.Dispatches.Dispatch, :count) == 1

    assert Dispatch.message({:after_unusable, "cancelled"}, %{}) =~
             "no commit to start from"
  end

  test "--after and `after` reach the request, for IMPLEMENT only", ctx do
    fields = %{
      session_id: "s1",
      repository: ctx.repo,
      purpose: "implement",
      worker: "codex:gpt-6-luna",
      title: "T",
      brief: @brief
    }

    assert {:ok, %{after_dispatch: nil} = plain} = Dispatch.build_request(fields)
    assert {:ok, chained} = Dispatch.build_request(Map.put(fields, :after, ctx.first.id))
    assert chained.after_dispatch == ctx.first.id
    # Following another is another request.
    assert chained.request_id != plain.request_id

    assert {:error, "--after is only for --purpose implement"} =
             Dispatch.build_request(%{fields | purpose: "explore"} |> Map.put(:after, "x"))

    assert {:ok, %{"dispatch_id" => id, "state" => "chained", "after" => after_id}} =
             Shoestring.Coordinator.Tools.call(
               "dispatch",
               %{
                 "purpose" => "implement",
                 "worker" => "codex:gpt-6-luna",
                 "title" => "Then subtract",
                 "brief" => @brief,
                 "after" => ctx.first.id
               },
               %{session_id: "s1", repository: ctx.repo}
             )

    assert after_id == ctx.first.id
    assert Dispatches.get(id).state == "chained"
  end
end
