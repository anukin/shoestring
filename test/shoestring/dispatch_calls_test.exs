defmodule Shoestring.DispatchCallsTest do
  @moduledoc """
  EXPLORE and REVIEW dispatches (iteration 14 package D) as one admitted
  call each, with stand-in explorers and reviewers
  (`Shoestring.Test.ExploreStandIn`, `Shoestring.Test.ReviewStandIn`): a real
  temporary Git repository, Oban in manual testing mode, no provider and no
  network. Scratch repositories are kept.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{Dispatches, Grants, ModelCatalog, Repo}
  alias Shoestring.Dispatches.{Call, Calls, Explore}
  alias Shoestring.Test.ExploreStandIn

  @brief """
  EXPLORE - why does test/test_calc.py fail?
  Contract: findings with file:line evidence.
  """

  setup do
    repo = Path.join(System.tmp_dir!(), "shoestring-calls-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(repo)

    {:ok, _} = ModelCatalog.add("claude", "opus")
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    {:ok, _} = ModelCatalog.add("opencode", "opencode/fixture-free")

    {:ok, grant} =
      Grants.create(
        %{
          session_id: "s1",
          repository_root: facts.root,
          models: ["claude:opus", "codex:gpt-6-luna", "opencode:opencode/fixture-free"],
          purposes: ["explore", "implement", "review"],
          max_dispatches: 6,
          max_parallel: 3,
          max_total_seconds: 7_200,
          max_dispatch_seconds: 3_600,
          unread_usage: 2
        },
        "human:operator"
      )

    %{repo: repo, root: facts.root, head: facts.head, grant: grant}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp explore(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "s1",
        request_id: "e1",
        purpose: "explore",
        provider: "claude",
        model: "opus",
        title: "Why does the calc test fail",
        brief: @brief,
        repository: ctx.repo
      },
      overrides
    )
  end

  defp step(dispatch, scenario \\ :report) do
    Calls.step(dispatch.id,
      adapters: %{{"explore", "claude"} => ExploreStandIn},
      adapter_opts: [test_pid: self(), scenario: scenario]
    )
  end

  # Admission holds every Claude call for a confirmation; the grant's
  # pre-approval gives it.
  defp admitted!(dispatch) do
    assert {:snooze, 30} = step(dispatch)
    assert Dispatches.state(dispatch) == "held"
    assert Dispatches.advance(dispatch) == :confirmed
    assert Calls.get(dispatch.id).confirmed_by == "grant:#{dispatch.grant_id}"
    # Confirmed, it waits for its job's next check, not for a person.
    assert Dispatches.state(dispatch) == "queued"
  end

  test "an explore dispatch is one confirmed call on a private copy, with a checked report",
       ctx do
    assert {:ok, dispatch, :recorded} = Dispatches.create(explore(ctx))
    assert dispatch.goal_id == nil
    assert dispatch.plan["purpose"] == "explore"
    assert dispatch.plan["base"] == ctx.head
    assert Dispatches.state(dispatch) == "queued"

    assert [%Oban.Job{worker: "Shoestring.Dispatches.CallWorker", args: %{"dispatch_id" => id}}] =
             Repo.all(Oban.Job)

    assert id == dispatch.id
    admitted!(dispatch)
    assert :done = step(dispatch)

    assert_received {:explore_input, input}
    assert input["model"] == "opus"
    assert input["schema"] == Explore.schema()
    assert input["prompt"] =~ @brief
    workdir = input["workdir"]
    assert String.starts_with?(workdir, Shoestring.State.path(:worktrees))
    refute Path.expand(workdir) == Path.expand(ctx.repo)

    assert %Call{state: "completed", output_tokens: 120} = call = Calls.get(dispatch.id)
    # No Claude reading yet: the grant confirmed an unknown capacity.
    assert call.admission["reason_code"] == "confirmed_unknown_capacity"
    assert Dispatches.state(dispatch) == "completed"

    report = Calls.report(call)
    assert report["supported_findings"] == 1

    assert [
             %{
               "supported" => true,
               "evidence" => [%{"supported" => true}, %{"supported" => true}]
             },
             %{"supported" => false, "evidence" => [%{"line" => 999, "supported" => false}]},
             %{
               "supported" => false,
               "evidence" => [%{"path" => "missing.py", "supported" => false}]
             }
           ] = report["findings"]

    # Secret-looking text is redacted; the rest of the question stays.
    assert [question] = report["open_questions"]
    assert question =~ "Should add() accept floats?"
    refute question =~ "sk-test-1234567890"

    # The user's checkout is untouched.
    assert File.read!(Path.join(ctx.repo, "calc.py")) =~ "NotImplementedError"
    assert {"", 0} = System.cmd("git", ["-C", ctx.repo, "status", "--porcelain"])

    # The same request replays the same dispatch.
    assert {:ok, ^dispatch, :replayed} = Dispatches.create(explore(ctx))

    # `runs log` tells the call's history from its timestamps.
    Shoestring.CLI.Commands.Runs.run(["log", dispatch.id], %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end
    })

    assert_receive {:mix_shell, :info, [json]}

    assert Enum.map(Jason.decode!(json)["entries"], & &1["line"]) == [
             "Dispatched: explore with claude:opus.",
             "Usage confirmed by grant:#{dispatch.grant_id}.",
             "Latest admission: admit (confirmed_unknown_capacity).",
             "The call started.",
             "The call completed (120 output tokens)."
           ]
  end

  test "what the explorer does while it runs is kept with the call and shown in its log",
       ctx do
    assert {:ok, dispatch, :recorded} = Dispatches.create(explore(ctx))
    admitted!(dispatch)
    assert :done = step(dispatch, :progress)

    assert %Call{progress: %{"total" => 55, "steps" => steps}} = Calls.get(dispatch.id)
    assert length(steps) == 50

    lines = Enum.map(Shoestring.CLI.Commands.Runs.log(dispatch, 0)["entries"], & &1["line"])
    assert "… 5 earlier steps not kept." in lines
    assert "Ran step 6" in lines and "Ran step 55" in lines
    refute "Ran step 5" in lines
    # The steps come after the call started and before it finished.
    started = Enum.find_index(lines, &(&1 == "The call started."))
    assert started < Enum.find_index(lines, &(&1 == "Ran step 6"))
    assert List.last(lines) =~ "The call completed"

    # A step reported after the call ended is not kept.
    :ok = Calls.record_progress(Calls.get(dispatch.id).id, "late")
    assert %Call{progress: %{"total" => 55}} = Calls.get(dispatch.id)
  end

  test "an explorer that writes, an oversized report or a failed call keeps no report", ctx do
    for {scenario, code, n} <- [
          {:write, "explorer_wrote", 1},
          {:oversized, "report_too_large", 2},
          {{:error, :transport_timeout}, "transport_timeout", 3}
        ] do
      {:ok, _} = Grants.extend(ctx.grant, %{add_unread_usage: 1}, "human:operator")
      {:ok, dispatch, :recorded} = Dispatches.create(explore(ctx, %{request_id: "e#{n}"}))
      admitted!(dispatch)

      Calls.step(dispatch.id,
        adapters: %{{"explore", "claude"} => ExploreStandIn},
        adapter_opts: [scenario: scenario]
      )

      assert %Call{state: "failed", error_code: ^code, report_json: nil} = Calls.get(dispatch.id)
      assert Dispatches.state(dispatch) == "failed"
      assert Dispatches.settled?("failed")
    end
  end

  test "a breached reserve defers a call; a call found running was lost and is never resent",
       ctx do
    now = DateTime.utc_now()
    resets = now |> DateTime.add(3_600) |> DateTime.to_unix()

    {:ok, reading} =
      Shoestring.Harness.Capacity.normalize(
        :claude,
        :headless_stream_json,
        %{
          "type" => "rate_limit_event",
          "rate_limit_info" => %{
            "status" => "allowed",
            "unifiedWindows" => %{
              "five_hour" => %{"utilization" => 0.95, "resetsAt" => resets, "status" => "allowed"},
              "seven_day" => %{"utilization" => 0.1, "resetsAt" => resets, "status" => "allowed"}
            }
          }
        },
        version: "2.1.310",
        now: now,
        captured_at: now,
        adapter_id: "claude_headless_stream_json",
        scope: "subscription"
      )

    {:ok, _, _} = Shoestring.Harness.Observatory.ingest(reading, now: now)

    {:ok, dispatch, :recorded} = Dispatches.create(explore(ctx))
    assert {:snooze, seconds} = step(dispatch)
    assert seconds > 3_000
    assert %Call{state: "waiting", defer_until: until} = Calls.get(dispatch.id)
    assert DateTime.to_unix(until) == resets
    assert Dispatches.state(dispatch) == "waiting"
    # Nothing to confirm: a breach is not an unread-usage hold.
    assert Dispatches.advance(dispatch) == :none

    {:ok, lost, :recorded} = Dispatches.create(explore(ctx, %{request_id: "e2"}))
    Calls.get(lost.id) |> Ecto.Changeset.change(state: "running") |> Repo.update!()
    assert :done = step(lost)
    refute_received {:explore_input, _}
    assert %Call{state: "failed", error_code: "call_lost"} = Calls.get(lost.id)
  end

  test "a held call's advice names what confirms it: a pre-approval, a person, or nothing",
       ctx do
    detail = fn dispatch -> Shoestring.CLI.Commands.Runs.detail(dispatch) end

    {:ok, first, :recorded} = Dispatches.create(explore(ctx))
    assert {:snooze, 30} = step(first)
    held = detail.(first)
    assert held["state"] == "held"
    assert held["next"] =~ "the grant's next unread-usage pre-approval confirms it"
    refute held["next"] =~ "grants extend"

    assert Dispatches.advance(first) == :confirmed
    assert detail.(first)["state"] == "queued"
    assert detail.(first)["next"] == nil

    # The grant's second and last pre-approval, then none.
    {:ok, second, :recorded} = Dispatches.create(explore(ctx, %{request_id: "e2"}))
    assert {:snooze, 30} = step(second)
    assert Dispatches.advance(second) == :confirmed

    {:ok, third, :recorded} = Dispatches.create(explore(ctx, %{request_id: "e3"}))
    assert {:snooze, 30} = step(third)
    assert Dispatches.advance(third) == :none
    assert detail.(third)["state"] == "held"
    assert detail.(third)["next"] =~ "shoestring grants extend #{ctx.grant.id} --unread-usage 1"

    {:ok, _} = Shoestring.Grants.revoke(ctx.grant, "human:operator")
    assert detail.(third)["next"] =~ "its grant is revoked"
    assert detail.(third)["next"] =~ "shoestring runs cancel #{third.id} --reason TEXT"
    refute detail.(third)["next"] =~ "grants extend"
  end

  test "a call is cancelled under its grant until it finishes", ctx do
    {:ok, dispatch, :recorded} = Dispatches.create(explore(ctx))
    assert {:ok, %Call{state: "cancelled"}} = Dispatches.cancel(dispatch, "Superseded.")
    assert Dispatches.state(dispatch) == "cancelled"
    assert :done = step(dispatch)
    refute_received {:explore_input, _}
    assert {:error, :already_finished} = Dispatches.cancel(dispatch, "Again.")
  end

  test "explore and review need a harness that can, the grant, and a completed implement",
       ctx do
    assert {:error, {:harness_cannot, "opencode", :explore}} =
             Dispatches.create(
               explore(ctx, %{provider: "opencode", model: "opencode/fixture-free"})
             )

    {:ok, _} = Grants.revoke(ctx.grant, "human:operator")

    {:ok, _} =
      Grants.create(
        %{
          session_id: "s1",
          repository_root: ctx.root,
          models: ["claude:opus"],
          purposes: ["implement"],
          max_dispatches: 3,
          max_parallel: 2,
          max_total_seconds: 7_200,
          max_dispatch_seconds: 3_600,
          unread_usage: 0
        },
        "human:operator"
      )

    assert {:error, {:outside_grant, :purpose}} = Dispatches.create(explore(ctx))
    assert Repo.aggregate(Call, :count) == 0

    {:ok, implement, :recorded} =
      Dispatches.create(%{
        session_id: "s1",
        request_id: "i1",
        purpose: "implement",
        provider: "claude",
        model: "opus",
        title: "Make add return the sum",
        brief: "IMPLEMENT - make add() return the sum\n",
        repository: ctx.repo
      })

    review = fn overrides ->
      Dispatches.create(
        Map.merge(
          %{
            session_id: "s1",
            request_id: "r1",
            purpose: "review",
            provider: "codex",
            model: "gpt-6-luna",
            title: "Review the sum",
            brief: "REVIEW - check the sum\n",
            repository: ctx.repo,
            target: implement.id
          },
          overrides
        )
      )
    end

    assert {:error, {:review_target_not_completed, "queued"}} = review.(%{})

    assert {:error, {:reviewer_same_vendor, "claude:opus"}} =
             review.(%{provider: "claude", model: "opus"})

    assert {:error, :review_target_not_found} = review.(%{session_id: "s2"})
    assert {:error, :review_target_not_found} = review.(%{target: Ecto.UUID.generate()})
    assert {:error, {:invalid_dispatch, :target}} = review.(%{target: nil})
  end
end
