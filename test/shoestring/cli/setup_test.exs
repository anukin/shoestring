defmodule Shoestring.CLI.SetupTest do
  @moduledoc """
  `shoestring setup`, `shoestring doctor` and the start-up model refresh.
  Readiness and model listings are injected; no harness CLI runs.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{AgentProfiles, ModelCatalog, Repo}
  alias Shoestring.CLI.Commands.{Doctor, Setup}
  alias Shoestring.ModelCatalog.StartupRefresh

  @listing %{
    "claude" => [%{"model" => "opus", "default" => false}, %{"model" => "sonnet"}],
    "codex" => [%{"model" => "gpt-6-luna"}, %{"model" => "gpt-6.1-sol", "default" => true}],
    "opencode" => [%{"model" => "opencode/glm-5"}]
  }

  setup do
    test = self()

    Application.put_env(:shoestring, :model_lister, fn provider, _opts ->
      send(test, {:listed, provider})
      {:ok, %{models: Map.fetch!(@listing, provider), skipped: 0}}
    end)

    on_exit(fn -> Application.delete_env(:shoestring, :model_lister) end)
  end

  defp readiness(states \\ %{}) do
    Map.new(~w(claude codex opencode), fn id ->
      {id, %{"readiness" => Map.get(states, id, "ready"), "cli_version" => "1.0.0"}}
    end)
  end

  defp context(opts \\ []) do
    %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      interactive?: fn -> Keyword.get(opts, :interactive, false) end,
      readiness: fn -> Keyword.get_lazy(opts, :readiness, &readiness/0) end,
      probe: fn -> %{} end
    }
  end

  defp json! do
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp roles(snapshot),
    do:
      Map.new(
        snapshot["configuration"]["roles"],
        &{&1["name"], "#{&1["provider"]}:#{&1["model"]}"}
      )

  test "without a terminal it refuses unless told the Worker and --yes, before changing anything" do
    for args <- [[], ["--worker", "codex:gpt-6-luna"], ["--yes"]] do
      assert_raise Shoestring.CLI.Refusal, ~r/Without a terminal pass --worker/, fn ->
        Setup.run(args, context())
      end
    end

    refute_received {:listed, _}
    assert ModelCatalog.entries() == []
    assert AgentProfiles.list() == []
  end

  test "refreshes installed harnesses and saves a default agent with a cross-vendor reviewer" do
    readiness = readiness(%{"opencode" => "binary_missing"})
    Setup.run(["--worker", "codex:gpt-6-luna", "--yes"], context(readiness: readiness))

    assert_received {:listed, "claude"}
    assert_received {:listed, "codex"}
    refute_received {:listed, "opencode"}

    output = json!()
    assert output["changed"] == true
    assert [%{"provider" => "claude"}, %{"provider" => "codex"}] = output["models"]

    assert roles(output["agent"]) == %{
             "Coordinator" => "claude:opus",
             "Worker" => "codex:gpt-6-luna",
             "Reviewer" => "claude:opus"
           }

    assert {:ok, %{"configuration" => %{"slug" => "builder"}}} = AgentProfiles.default_snapshot()

    # The same choices again: nothing new is saved.
    Setup.run(["--worker", "codex:gpt-6-luna", "--yes"], context(readiness: readiness))
    assert %{"changed" => false, "agent" => %{"revision" => 1}} = json!()
  end

  test "interactively it suggests each role, takes answers and asks before saving" do
    send(self(), {:mix_shell_input, :prompt, ""})
    send(self(), {:mix_shell_input, :prompt, "claude:sonnet"})
    send(self(), {:mix_shell_input, :prompt, ""})
    send(self(), {:mix_shell_input, :prompt, "n"})

    assert_raise Shoestring.CLI.Refusal, "Not saved.", fn ->
      Setup.run([], context(interactive: true))
    end

    assert_received {:mix_shell, :prompt, ["Coordinator [claude:opus]: "]}
    assert_received {:mix_shell, :prompt, ["Worker [codex:gpt-6.1-sol]: "]}
    # A Claude Worker is reviewed by Codex, its own default model first.
    assert_received {:mix_shell, :prompt, ["Reviewer [codex:gpt-6.1-sol]: "]}
    assert AgentProfiles.list() == []

    for answer <- ["", "", "none", "y"], do: send(self(), {:mix_shell_input, :prompt, answer})
    Setup.run(["--agent", "solo", "--skip-refresh"], context(interactive: true))

    assert roles(json!()["agent"]) == %{
             "Coordinator" => "claude:opus",
             "Worker" => "codex:gpt-6.1-sol"
           }
  end

  test "keeps an existing agent's other team roles and warns about a same-vendor reviewer" do
    Setup.run(["--worker", "codex:gpt-6-luna", "--yes"], context())
    _ = json!()
    {:ok, agent} = {:ok, AgentProfiles.get_by_slug("builder")}

    {:ok, _} =
      AgentProfiles.update(agent, %{
        "roles" =>
          Enum.map(agent.roles, &Map.take(Map.from_struct(&1), [:name, :provider, :model])) ++
            [%{name: "Scribe", provider: "claude", model: "sonnet"}]
      })

    Setup.run(
      [
        "--worker",
        "codex:gpt-6-luna",
        "--reviewer",
        "codex:gpt-6.1-sol",
        "--yes",
        "--skip-refresh"
      ],
      context()
    )

    assert_received {:mix_shell, :error,
                     [
                       "The Reviewer's model is the same vendor as the Worker's: cross-review will wait for you."
                     ]}

    assert %{"Reviewer" => "codex:gpt-6.1-sol", "Scribe" => "claude:sonnet"} =
             roles(json!()["agent"])
  end

  test "doctor reports each agent CLI and the recorded models" do
    {:ok, _} = ModelCatalog.refresh("codex", now: ~U[2026-10-25 12:00:00.000000Z])
    Doctor.run([], context())

    assert %{
             "agents" => %{"claude" => %{"readiness" => _}},
             "models" => %{
               "codex" => %{
                 "recorded" => 2,
                 "enabled" => 3,
                 "last_listed_at" => "2026-10-25T12:00:00.000000Z"
               },
               "opencode" => %{"recorded" => 0, "last_listed_at" => nil}
             }
           } = json!()
  end

  test "the start-up refresh lists only installed harnesses with a stale catalog" do
    now = ~U[2026-10-25 12:00:00.000000Z]
    {:ok, _} = ModelCatalog.refresh("codex", now: DateTime.add(now, -3600))
    {:ok, _} = ModelCatalog.refresh("claude", now: DateTime.add(now, -2 * 86_400))
    flush_listed()

    installed = fn name -> if name in ~w(claude codex), do: "/usr/bin/#{name}" end

    assert [{"claude", {:ok, _}}] = StartupRefresh.run(now: now, find: installed)
    assert_received {:listed, "claude"}
    refute_received {:listed, _}
  end

  defp flush_listed do
    receive do
      {:listed, _} -> flush_listed()
    after
      0 -> :ok
    end
  end
end
