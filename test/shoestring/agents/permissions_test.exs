defmodule Shoestring.Agents.PermissionsTest do
  @moduledoc """
  What a person adds to an implementer agent's sandbox: which additions are
  accepted, what a session records of them, how the Agents page words them,
  and what each provider's sandbox is given. Local git only; no provider CLI.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{Agents, ModelCatalog, Worktrees}
  alias Shoestring.Agents.{Agent, Permissions}
  alias Shoestring.Harness.ClaudeHeadless.Sandbox
  alias Shoestring.Harness.CodexAppServer.GitSandbox

  @home "/Users/person"
  @state "/Users/person/Library/Application Support/Shoestring"

  setup do
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    {:ok, _} = ModelCatalog.add("claude", "opus")
    :ok
  end

  defp check(attrs) do
    %Agent{}
    |> Ecto.Changeset.cast(Permissions.normalize(attrs), [:kind, :provider | Permissions.fields()])
    |> Permissions.validate(home: @home, state: @state)
  end

  defp base(provider, kind \\ "implementer"), do: %{"kind" => kind, "provider" => provider}

  defp error(changeset),
    do: changeset.errors |> Enum.map(fn {_f, {message, _}} -> message end) |> Enum.join("; ")

  test "folders and hosts come from one entry per line; empty is nothing added" do
    changeset =
      check(
        Map.merge(base("claude"), %{
          "read_paths" => "/data/fixtures\n\n  /Users/person/datasets  \n",
          "write_paths" => "/Users/person/scratch",
          "network_hosts" => "github.com\r\n*.npmjs.org"
        })
      )

    assert changeset.valid?, error(changeset)

    assert Ecto.Changeset.get_field(changeset, :read_paths) == [
             "/data/fixtures",
             "/Users/person/datasets"
           ]

    assert Ecto.Changeset.get_field(changeset, :network_hosts) == ["github.com", "*.npmjs.org"]

    assert check(Map.merge(base("claude"), %{"read_paths" => "", "network_hosts" => ""})).valid?
    assert Permissions.snapshot(%{read_paths: [], write_paths: [], network_hosts: []}) == nil
  end

  test "never home itself, above it, or Shoestring's own state; full paths only" do
    for {path, message} <- [
          {"/", "home folder"},
          {"/Users", "home folder"},
          {@home, "home folder"},
          {@state, "Shoestring's own state"},
          {@state <> "/worktrees/run-1", "Shoestring's own state"},
          {"/Users/person/Library", "Shoestring's own state"},
          {"~/data", "full path"},
          {"data", "full path"},
          {"/Users/person/a/../b", "full path"},
          {"/Users/person/data/", "full path"}
        ] do
      for field <- ["read_paths", "write_paths"] do
        changeset = check(Map.put(base("claude"), field, path))
        refute changeset.valid?, "#{field} #{path}"
        assert error(changeset) =~ message, "#{field} #{path}: #{error(changeset)}"
      end
    end

    paths = Enum.map_join(1..11, "\n", &"/data/#{&1}")
    assert error(check(Map.put(base("claude"), "read_paths", paths))) =~ "at most 10"
  end

  test "Codex takes only every host; Claude takes host names; opencode and other jobs take nothing" do
    assert check(Map.put(base("codex"), "network_hosts", "*")).valid?

    assert error(check(Map.put(base("codex"), "network_hosts", "github.com"))) =~
             "Codex cannot limit its network"

    for bad <- ["*", "https://github.com", "github.com:443", "GitHub.com", "localhost"],
        do: refute(check(Map.put(base("claude"), "network_hosts", bad)).valid?, bad)

    assert error(check(Map.put(base("opencode"), "read_paths", "/data"))) =~ "fixed"

    for kind <- ~w(coordinator explorer reviewer),
        do:
          assert(
            error(check(Map.put(base("claude", kind), "write_paths", "/data"))) =~
              "only an implementer"
          )
  end

  # 1571f8e let Claude workers ask but still listed "Ask for more" under
  # what a Claude implementer cannot do.
  test "an implementer that may ask reads so, for Codex and Claude; opencode never asks" do
    for provider <- ["codex", "claude"] do
      abilities = Agents.abilities(%{kind: "implementer", provider: provider, may_ask: true})

      assert Enum.any?(abilities.can, &String.starts_with?(&1, "Ask you, while it works")),
             provider

      refute Enum.any?(abilities.cannot, &String.starts_with?(&1, "Ask for more")), provider

      off = Agents.abilities(%{kind: "implementer", provider: provider, may_ask: false})
      refute Enum.any?(off.can, &String.starts_with?(&1, "Ask you, while it works")), provider
    end
  end

  # "Allow for this agent": exact commands only, never a compound one.
  test "a rule is one plain command; compound shell commands are refused" do
    assert Permissions.ruleable?("/bin/zsh -lc 'curl -sS https://example.invalid/notes'")
    assert Permissions.ruleable?("npm install --offline")

    for compound <- [
          "a; b",
          "a && b",
          "a || b",
          "a | b",
          "a & ",
          "echo `id`",
          "echo $(id)",
          "a\nb",
          "a\rb",
          " padded",
          "",
          String.duplicate("x", 501),
          nil
        ] do
      refute Permissions.ruleable?(compound), inspect(compound)
    end

    cast = fn attrs ->
      %Agent{}
      |> Ecto.Changeset.cast(Permissions.normalize(attrs), [:kind, :provider, :allowed_commands])
      |> Permissions.validate(home: @home, state: @state)
    end

    ok = cast.(Map.put(base("claude"), "allowed_commands", "npm test\n\n make lint \n"))
    assert ok.valid?
    assert Ecto.Changeset.get_field(ok, :allowed_commands) == ["npm test", "make lint"]

    assert error(cast.(Map.put(base("codex"), "allowed_commands", "make && make install"))) =~
             "one plain command"

    assert error(
             cast.(
               Map.put(
                 base("codex"),
                 "allowed_commands",
                 Enum.map_join(1..21, "\n", &"echo #{&1}")
               )
             )
           ) =~
             "at most 20 commands"

    assert error(cast.(Map.put(base("opencode"), "allowed_commands", "npm test"))) =~ "fixed"

    assert error(cast.(Map.put(base("claude", "reviewer"), "allowed_commands", "npm test"))) =~
             "only an implementer"
  end

  test "a saved agent's additions reach its team snapshot and read plainly on the page" do
    {:ok, agent} =
      Agents.create(%{
        "name" => "Builder",
        "slug" => "builder-net",
        "kind" => "implementer",
        "provider" => "codex",
        "model" => "gpt-6-luna",
        "write_paths" => "/data/out",
        "network_hosts" => "*"
      })

    # An implementer may ask by default; that is recorded too.
    assert Permissions.snapshot(agent) == %{
             "write_paths" => ["/data/out"],
             "network_hosts" => ["*"],
             "may_ask" => true
           }

    assert Permissions.snapshot(%{agent | write_paths: [], network_hosts: [], may_ask: false}) ==
             nil

    abilities = Agents.abilities(agent)
    assert "Also read and write /data/out" in abilities.can
    assert "Use the network, any host (Codex cannot limit hosts)" in abilities.can
    refute Enum.any?(abilities.cannot, &String.starts_with?(&1, "Use the network"))
    # What it was not given still reads as cannot.
    assert "Read your home folder" in abilities.cannot

    plain = Agents.abilities(%{agent | write_paths: [], network_hosts: []})
    assert Enum.any?(plain.cannot, &String.starts_with?(&1, "Use the network"))
  end

  describe "the sandboxes" do
    setup do
      base = Path.join(System.tmp_dir!(), "shoestring-perm-#{Ecto.UUID.generate()}")
      source = Path.join(base, "source")
      File.mkdir_p!(source)
      git!(source, ["init", "-q", "-b", "main"])
      File.write!(Path.join(source, "a.txt"), "a\n")
      git!(source, ["add", "."])

      git!(source, [
        "-c",
        "user.name=T",
        "-c",
        "user.email=t@x",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        "b"
      ])

      root = Path.join(base, "worktrees")

      {:ok, wt} =
        Worktrees.create(source, Ecto.UUID.generate(), "HEAD",
          private_git: true,
          worktrees_dir: root
        )

      on_exit(fn -> File.rm_rf!(base) end)
      %{wt: wt, root: root, home: Path.join(base, "home")}
    end

    @added %{
      "read_paths" => ["/data/fixtures"],
      "write_paths" => ["/data/out"],
      "network_hosts" => ["github.com"]
    }

    test "Claude's settings gain the folders and hosts; without additions they stay narrow",
         ctx do
      prepare = fn permissions ->
        {:ok, sandbox} =
          Sandbox.prepare(ctx.wt.path, ctx.wt.workspace_ref,
            worktrees_dir: ctx.root,
            home: ctx.home,
            permissions: permissions
          )

        Sandbox.release(sandbox.temp_dir)
        sandbox.settings["sandbox"]
      end

      narrow = prepare.(nil)
      wide = prepare.(@added)

      assert narrow["network"]["allowedDomains"] == []
      refute "/data/out" in narrow["filesystem"]["allowWrite"]
      assert wide["network"]["allowedDomains"] == ["github.com"]

      assert wide["filesystem"]["allowWrite"] ==
               narrow["filesystem"]["allowWrite"] ++ ["/data/out"]

      assert wide["filesystem"]["allowRead"] ==
               narrow["filesystem"]["allowRead"] ++ ["/data/fixtures", "/data/out"]

      # The run's own roots and the denials are unchanged.
      assert wide["filesystem"]["denyRead"] == narrow["filesystem"]["denyRead"]
      assert wide["filesystem"]["denyWrite"] == narrow["filesystem"]["denyWrite"]
      assert wide["allowUnsandboxedCommands"] == false
    end

    test "Codex's profile gains the folders and, for *, the network; never fewer of its own roots",
         ctx do
      {:ok, policy} = GitSandbox.policy(ctx.wt.path, ctx.wt.workspace_ref, ctx.root)
      fs = fn profile -> profile["permissions"]["shoestring_run"]["filesystem"] end

      narrow = GitSandbox.permissions(policy, ctx.home)
      wide = GitSandbox.permissions(policy, ctx.home, %{@added | "network_hosts" => ["*"]})

      refute Map.has_key?(narrow["permissions"]["shoestring_run"], "network")
      assert wide["permissions"]["shoestring_run"]["network"] == %{"enabled" => true}
      assert fs.(wide)["/data/fixtures"] == "read"
      assert fs.(wide)["/data/out"] == "write"
      for root <- policy["writableRoots"], do: assert(fs.(wide)[root] == "write")

      # An addition naming one of the run's own roots cannot make it read-only.
      [worktree | _] = policy["writableRoots"]
      clash = GitSandbox.permissions(policy, ctx.home, %{"read_paths" => [worktree]})
      assert fs.(clash)[worktree] == "write"
    end
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
end
