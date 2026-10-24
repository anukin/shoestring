defmodule Shoestring.CLI.MainTest do
  @moduledoc """
  The `shoestring` dispatcher both installations run: exit statuses, the
  stdout/stderr contract (`Mix.Shell.Process`: `:info` is stdout, `:error` is
  stderr), `--json`, and the installed command's state and service refusals.
  `do` runs with the fixture planner, a real temporary Git repository and an
  injected service check. No provider, network or service.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.AgentProfiles
  alias Shoestring.CLI.{Main, Messages, Repository}
  alias Shoestring.Cobbler.Intake
  import Shoestring.Test.PlanFixtures, only: [task: 4]

  @request "Make add return the sum of its arguments."

  defp run(argv, opts \\ []) do
    Main.run(argv, Keyword.merge([shell: Mix.Shell.Process, service: fn -> :ok end], opts))
  end

  # {stdout lines, stderr lines} written since the last call.
  defp output(stdout \\ [], stderr \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> output([line | stdout], stderr)
      {:mix_shell, :error, [line]} -> output(stdout, [line | stderr])
    after
      0 -> {Enum.reverse(stdout), Enum.reverse(stderr)}
    end
  end

  defp answer(text), do: send(self(), {:mix_shell_input, :prompt, text})

  describe "dispatch" do
    test "usage, help and unknown commands" do
      assert run([]) == 2
      assert {[], [usage]} = output()
      assert usage =~ "usage: shoestring COMMAND"
      assert usage =~ "Service commands:"

      assert run(["help"]) == 0
      assert {[usage], []} = output()
      assert usage =~ "usage: shoestring COMMAND"

      assert run(["help"], installation: :checkout) == 0
      assert {[usage], []} = output()
      refute usage =~ "Service commands:"

      assert run(["bogus"]) == 2
      assert {[], ["shoestring: unknown command 'bogus'", _usage]} = output()
    end

    test "every command describes itself on stdout" do
      for name <- Main.commands(), flag <- ["--help", "-h"] do
        assert run([name, flag]) == 0
        assert {[help], []} = output()
        assert help =~ "shoestring #{name}"
        refute help =~ "mix shoestring"
      end

      assert run(["help", "result"]) == 0
      assert {[help], []} = output()
      assert help =~ "shoestring result GOAL"
    end

    test "invalid arguments are one line on stderr and exit 2, before any state is read" do
      no_repo = fn _ -> flunk("state must not be opened for invalid arguments") end

      for argv <- [
            ["do"],
            ["do", "fix it", "--yes"],
            ["follow"],
            ["result", "a", "b"],
            ["checks", "goal", "--output", "x"],
            ["review", "decide", "goal", "task"],
            ["goals", "create"],
            ["plans", "show"],
            ["execution", "status"],
            ["agents", "show", "a", "b"],
            ["models", "add", "claude"],
            ["reservations", "show", "not-a-uuid"]
          ] do
        assert run(argv, with_repo: no_repo) == 2, inspect(argv)
        [name | _] = argv
        assert output() == {[], ["Invalid arguments. See shoestring #{name} --help"]}
      end
    end

    test "a relative --file is read from the caller's directory" do
      goal = Shoestring.Test.CobblerHelpers.create_goal!()
      dir = Path.join(System.tmp_dir!(), "shoestring-cli-file-#{Ecto.UUID.generate()}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "plan.json"), "[]")

      argv = ["plans", "propose", goal.id, "--file", "plan.json", "--request-id", "r1"]
      argv = argv ++ ["--by", "human:me"]

      assert run(argv, cwd: dir) == 1
      assert output() == {[], ["Malformed plan JSON; expected an object"]}

      assert run(argv, cwd: System.tmp_dir!()) == 1
      assert output() == {[], ["Unable to read plan file"]}
    end

    test "a refusal is one line on stderr, exit 1, with nothing on stdout" do
      assert run(["follow", "not-a-goal"]) == 1
      assert output() == {[], ["GOAL must be a goal id; see shoestring goals list"]}

      goal = Shoestring.Test.CobblerHelpers.create_goal!()
      assert run(["result", goal.id]) == 1
      assert output() == {[], ["The goal has not completed yet."]}
    end
  end

  describe "--json" do
    test "commands that print data print one JSON document on stdout and nothing on stderr" do
      assert run(["goals", "create", "--title", "Ship it", "--json"]) == 0
      assert {[json], []} = output()
      assert %{"id" => goal_id, "title" => "Ship it"} = Jason.decode!(json)

      assert run(["goals", "list", "--json"]) == 0
      assert {[json], []} = output()
      assert [%{"id" => ^goal_id}] = Jason.decode!(json)

      {:ok, _} =
        AgentProfiles.save_settings(AgentProfiles.settings(), %{
          "claude_models" => "default\nopus"
        })

      assert run(["agents", "create", "builder", "--worker", "claude:opus"]) == 0
      assert {[_snapshot], []} = output()

      assert run(["agents", "list"]) == 0
      assert output() == {["builder\tbuilder\trevision 1"], []}

      assert run(["agents", "list", "--json"]) == 0
      assert {[json], []} = output()
      assert Jason.decode!(json) == [%{"slug" => "builder", "name" => "builder", "revision" => 1}]
    end
  end

  describe "the installed command's state" do
    test "a missing database is refused in one line, without creating state" do
      empty = Path.join(System.tmp_dir!(), "shoestring-cli-empty-#{Ecto.UUID.generate()}")
      previous = System.get_env("SHOESTRING_TEST_STATE_DIR")
      System.put_env("SHOESTRING_TEST_STATE_DIR", empty)

      on_exit(fn ->
        if previous,
          do: System.put_env("SHOESTRING_TEST_STATE_DIR", previous),
          else: System.delete_env("SHOESTRING_TEST_STATE_DIR")
      end)

      assert run(["goals", "list"]) == 1
      assert output() == {[], [Messages.message(:database_missing)]}
      refute File.exists?(empty)
    end

    test "only a database at exactly this code's schema is opened" do
      up = {:up, 20_260_101_000_000, "create_goals"}
      assert Repository.schema_state([up]) == :current

      assert Repository.schema_state([up, {:down, 20_260_102_000_000, "add_column"}]) ==
               {:error, :database_needs_init}

      assert Repository.schema_state([up, {:up, 20_270_101_000_000, "** FILE NOT FOUND **"}]) ==
               {:error, :database_newer}

      for reason <- [:database_needs_init, :database_newer] do
        message = Messages.message(reason)
        refute message =~ "Refused:"
        refute message =~ "\n"
      end
    end

    test "the current test database opens for the installed command" do
      assert run(["goals", "list"]) == 0
      assert output() == {["[]"], []}
    end
  end

  describe "the service" do
    test "following an unfinished goal without the service says how to start it" do
      goal = Shoestring.Test.CobblerHelpers.create_goal!()
      down = fn -> {:error, :service_unreachable} end

      assert run(["follow", goal.id], service: down) == 1

      assert output() ==
               {[],
                [
                  "The Shoestring service is not running. Start it in another terminal: " <>
                    "shoestring start"
                ]}

      assert run(["follow", goal.id], service: down, installation: :checkout) == 1
      assert {[], [line]} = output()
      assert line =~ "mix phx.server"
    end
  end

  describe "do" do
    setup do
      repo = Path.join(System.tmp_dir!(), "shoestring-cli-do-#{Ecto.UUID.generate()}")
      File.mkdir_p!(Path.join(repo, "test"))
      File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
      File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
      git!(repo, ["init", "-q", "-b", "main"])
      git!(repo, ["add", "."])
      git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])

      {:ok, _} =
        AgentProfiles.save_settings(AgentProfiles.settings(), %{
          "claude_models" => "default\nopus"
        })

      {:ok, agent} =
        AgentProfiles.create(%{
          "name" => "Builder",
          "slug" => "builder",
          "purpose" => "Carry out approved plan tasks.",
          "instructions" => "Stay in scope.",
          "roles" => [
            %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
            %{"name" => "Worker", "provider" => "claude", "model" => "opus"}
          ]
        })

      {:ok, _} =
        AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => agent.id})

      previous = Application.get_env(:shoestring, :planner)

      Application.put_env(:shoestring, :planner,
        adapter: :fixture,
        model: "fixture-v1",
        responses: [{:ok, plan_json(repo), 30}]
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:shoestring, :planner, previous),
          else: Application.delete_env(:shoestring, :planner)
      end)

      %{repo: repo}
    end

    test "the conversation goes to stderr and stdout carries only the goal id", c do
      # Planning is held without a capacity reading: confirm the one call, then approve.
      answer("y")
      answer("y")
      assert run(["do", @request, "--no-follow"], cwd: c.repo) == 0

      {stdout, stderr} = output()
      assert [goal_id] = stdout
      assert {:ok, _} = Ecto.UUID.cast(goal_id)

      assert "Goal #{goal_id}" in stderr
      assert Enum.any?(stderr, &String.starts_with?(&1, "Plan revision 1"))
      assert "  1. add: Implement add" in stderr
      assert "Follow it with: shoestring follow #{goal_id}" in stderr
      refute Enum.any?(stderr, &(&1 == goal_id))
    end

    test "--json prints the queued goal as one object", c do
      answer("y")
      answer("y")
      assert run(["do", @request, "--no-follow", "--json"], cwd: c.repo) == 0

      {[json], stderr} = output()

      assert %{"goal_id" => goal_id, "state" => "queued", "revision" => 1, "execution_id" => _} =
               Jason.decode!(json)

      assert "Goal #{goal_id}" in stderr
    end

    test "declining exits 3 and records nothing to run", c do
      answer("y")
      answer("n")
      assert run(["do", @request, "--json"], cwd: c.repo) == 3
      {[json], stderr} = output()
      assert %{"goal_id" => goal_id, "state" => "declined"} = Jason.decode!(json)
      assert Enum.any?(stderr, &String.starts_with?(&1, "Not approved; nothing runs."))
      assert Repo.all(Oban.Job) == []
      assert {:ok, _} = Ecto.UUID.cast(goal_id)
    end

    test "a relative --repo resolves against the caller's directory", c do
      assert run(["do", @request, "--repo", "missing-subdir"], cwd: c.repo) == 1
      assert output() == {[], [Messages.message(:not_a_directory)]}
    end
  end

  defp plan_json(repo) do
    {:ok, facts} = Intake.repository(repo)
    {:ok, gates} = Intake.gates(facts)
    {:ok, contract} = Intake.goal_contract(@request, facts, gates)

    Jason.encode!(%{
      "version" => 1,
      "goal" => contract,
      "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 1_200},
      "tasks" => [
        task("add", "Implement add", [], %{
          "gates" => gates,
          "hints" => %{"files" => ["calc.py"], "symbols" => ["add"]},
          "expected_artifacts" => ["calc.py"],
          "execution" => %{"max_attempts" => 1, "max_duration_seconds" => 600}
        })
      ]
    })
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    :ok
  end
end
