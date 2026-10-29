defmodule Shoestring.CLI.ChatTest do
  @moduledoc """
  `shoestring chat` and the coordinator launch: rendered instructions, each
  CLI's command, the launch script run against a fake CLI, and the grant a
  new session asks for. No coordinator CLI, provider or network runs.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{AgentProfiles, ConfigurationFixtures, Coordinator, Grants, ModelCatalog, Repo}
  alias Shoestring.CLI.Commands.Chat
  alias Shoestring.CLI.Refusal

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "a.py"), "")
    {_, 0} = System.cmd("git", ["-C", repo, "init", "-q", "-b", "main"])

    {:ok, _} = ModelCatalog.add("claude", "opus")
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")

    roles = [
      %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
      %{"name" => "Worker", "provider" => "codex", "model" => "gpt-6-luna"},
      %{"name" => "Reviewer", "provider" => "claude", "model" => "opus"}
    ]

    {:ok, agent} =
      AgentProfiles.create(
        ConfigurationFixtures.agent_attrs(%{
          "roles" => roles,
          "instructions" => "Prefer small diffs."
        })
      )

    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => agent.id})

    %{repo: repo, dir: dir}
  end

  defp context(ctx, opts \\ []) do
    %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      cwd: ctx.repo,
      installation: :checkout,
      service: Keyword.get(opts, :service, fn -> :ok end),
      start_hint: "mix phx.server",
      interactive?: fn -> Keyword.get(opts, :interactive, true) end,
      find: fn name -> "/usr/local/bin/#{name}" end
    }
  end

  defp answer(text), do: send(self(), {:mix_shell_input, :prompt, text})

  # A checkout's database path is set only when its repository opens
  # (`Shoestring.State.configure_repo!/0`), and the service check compares
  # that database's fingerprint (`Shoestring.Health.instance/0`).
  defp checkout(context) do
    config = Application.fetch_env!(:shoestring, Repo)
    Application.put_env(:shoestring, Repo, Keyword.delete(config, :database))
    on_exit(fn -> Application.put_env(:shoestring, Repo, config) end)

    %{
      context
      | service: fn -> Shoestring.Health.instance() && :ok end,
        with_repo: fn fun ->
          Application.put_env(:shoestring, Repo, config)
          fun.(Repo)
        end
    }
  end

  test "the instructions name the session, the grant, the routing and the agent's own text" do
    grant = %Grants.Grant{
      id: Ecto.UUID.generate(),
      models: ["codex:gpt-6-luna"],
      purposes: ["implement"],
      max_dispatches: 5,
      max_parallel: 2
    }

    text =
      Coordinator.instructions(%{
        session: "session-abc",
        grant: grant,
        roles: [
          %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
          %{"name" => "Worker", "provider" => "codex", "model" => "gpt-6-luna"}
        ],
        agent_instructions: "Prefer small diffs.",
        command: "/x/bin/shoestring"
      })

    refute text =~ "{{"
    assert text =~ "Session `session-abc`"
    assert text =~ "Grant `#{grant.id}`: models codex:gpt-6-luna"
    assert text =~ "The person's agent suggests: Worker codex:gpt-6-luna."
    assert text =~ "/x/bin/shoestring dispatch --purpose implement"
    assert text =~ "Never run `/x/bin/shoestring grant`"
    assert String.ends_with?(text, "Prefer small diffs.\n")

    no_grant =
      Coordinator.instructions(%{session: "s", grant: nil, roles: [], command: "shoestring"})

    assert no_grant =~ "No grant yet"
  end

  test "each CLI gets the model and the instructions its own way" do
    assert %{argv: argv, env: [{"SHOESTRING_SESSION", "s"}]} =
             Coordinator.launch("claude", "opus", "high", "text", "/i.md", "s")

    assert argv == [
             "claude",
             "--model",
             "opus",
             "--append-system-prompt-file",
             "/i.md",
             "--name",
             "Shoestring s",
             "--effort",
             "high"
           ]

    assert %{argv: ["codex", "-m", "gpt-6-luna", "-c", instructions | _]} =
             Coordinator.launch("codex", "gpt-6-luna", nil, "a '''quoted''' text", "/i.md", "s")

    assert instructions == "developer_instructions='''\na ' ' 'quoted' ' ' text'''"

    assert %{argv: ["opencode"], env: [{"OPENCODE_CONFIG_CONTENT", config} | _]} =
             Coordinator.launch("opencode", "opencode/glm-5", nil, "t", "/i.md", "s")

    assert Jason.decode!(config) == %{"model" => "opencode/glm-5", "instructions" => ["/i.md"]}
  end

  test "the launch script execs the CLI with every argument intact", %{dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "codex"), """
    #!/bin/sh
    printf 'session=%s\\n' "$SHOESTRING_SESSION"
    printf 'cwd=%s\\n' "$(pwd -P)"
    for arg in "$@"; do printf 'arg=[%s]\\n' "$arg"; done
    """)

    File.chmod!(Path.join(bin, "codex"), 0o755)
    text = "Line one\nIt's \"quoted\" $HOME `x`"
    launch = Coordinator.launch("codex", "gpt-6-luna", nil, text, "/i.md", "s 1")
    script = Path.join(dir, "launch.sh")
    File.write!(script, Coordinator.script(launch, dir))

    {output, 0} =
      System.cmd("sh", [script], env: [{"PATH", bin <> ":" <> System.get_env("PATH")}])

    assert output =~ "session=s 1\n"

    assert output =~
             "cwd=#{Path.expand(dir) |> then(&elem(System.cmd("realpath", [&1]), 0)) |> String.trim()}\n"

    assert output =~ "arg=[developer_instructions='''\n#{text}''']\n"
    refute File.exists?(script)
  end

  test "chat needs a person at a terminal and a running service", ctx do
    assert_raise Refusal, ~r/A coordinator cannot grant itself/, fn ->
      Chat.run([], context(ctx, interactive: false))
    end

    assert_raise Refusal, ~r/not running/, fn ->
      Chat.run([], context(ctx, service: fn -> {:error, :service_unreachable} end))
    end
  end

  test "with --external, a new session asks for its grant, then writes the launch", ctx do
    answer("n")

    assert_raise Refusal, ~r/Not started: the session needs a grant/, fn ->
      Chat.run(["--session", "chat-1", "--external"], context(ctx))
    end

    assert Grants.list() == []

    launch = Path.join(ctx.dir, "launch.sh")
    answer("y")
    Chat.run(["--session", "chat-1", "--external", "--launch-file", launch], context(ctx))

    assert %{
             models: ["codex:gpt-6-luna", "claude:opus"],
             purposes: ["explore", "implement", "review"],
             max_turns: 20
           } =
             Grants.active("chat-1")

    assert_received {:mix_shell, :error, ["  Coordinator turns: 20"]}

    script = File.read!(launch)
    assert script =~ "SHOESTRING_SESSION=chat-1"
    assert script =~ "claude --model opus --append-system-prompt-file"

    instructions =
      [Shoestring.State.root(), "chat", "chat-1", "instructions.md"]
      |> Path.join()
      |> File.read!()

    assert instructions =~ "Session `chat-1`"
    assert instructions =~ Path.join(File.cwd!(), "bin/shoestring") <> " dispatch"
    assert instructions =~ "Prefer small diffs."

    # The same session again: its grant is reused, nothing is asked.
    assert_received {:mix_shell, :prompt, ["Grant this and start? [y/N] "]}
    assert_received {:mix_shell, :prompt, ["Grant this and start? [y/N] "]}

    Chat.run(
      ["--session", "chat-1", "--external", "--coordinator", "codex:gpt-6-luna"],
      context(ctx)
    )

    assert_receive {:mix_shell, :info, [json]}

    assert %{"session_id" => "chat-1", "argv" => ["codex", "-m", "gpt-6-luna" | _]} =
             Jason.decode!(json)

    refute_received {:mix_shell, :prompt, ["Grant this and start? [y/N] "]}

    Chat.run(["list"], context(ctx))
    assert_receive {:mix_shell, :info, [json]}

    assert [%{"session_id" => "chat-1", "coordinator" => "codex:gpt-6-luna", "dispatches" => 0}] =
             Jason.decode!(json)
  end

  test "from a checkout, chat --external checks the service once its repository is open", ctx do
    launch = Path.join(ctx.dir, "launch.sh")
    answer("y")

    Chat.run(
      ["--session", "chat-2", "--external", "--launch-file", launch],
      checkout(context(ctx))
    )

    assert File.read!(launch) =~ "SHOESTRING_SESSION=chat-2"
  end

  test "a coordinator must be able to coordinate, be enabled and be installed", ctx do
    assert_raise Refusal, ~r/claude:sonnet is not an enabled model/, fn ->
      Chat.run(["--coordinator", "claude:sonnet"], context(ctx))
    end

    assert_raise Refusal, ~r/The codex CLI is not on PATH/, fn ->
      Chat.run(["--coordinator", "codex:gpt-6-luna"], %{context(ctx) | find: fn _ -> nil end})
    end
  end

  describe "the chat screen" do
    setup ctx do
      client = Path.join(ctx.dir, "shoestring-chat")
      File.write!(client, "#!/bin/sh\n")
      %{client: client}
    end

    defp screen(ctx, opts \\ []), do: Map.put(context(ctx, opts), :chat_client, ctx.client)

    test "opens the conversation, its instructions and its token, then runs the client", ctx do
      launch = Path.join(ctx.dir, "launch.sh")
      answer("y")
      Chat.run(["--session", "chat-3", "--launch-file", launch], screen(ctx))

      assert %{max_turns: 20} = Grants.active("chat-3")

      assert %{provider: "claude", model: "opus", repository_root: root} =
               conversation = Shoestring.Conversations.get("chat-3")

      assert root == Grants.active("chat-3").repository_root

      token_file = Shoestring.Conversations.ChatToken.path("chat-3")
      assert Bitwise.band(File.stat!(token_file).mode, 0o777) == 0o600
      token = File.read!(token_file)

      script = File.read!(launch)
      assert script =~ ctx.client
      assert script =~ ~r"--url ws://127\.0\.0\.1:\d+/chat/socket"
      assert script =~ "--session chat-3"
      assert script =~ "--token-file " <> token_file
      refute script =~ token

      instructions = File.read!(Shoestring.Conversations.instructions_path("chat-3"))
      assert instructions =~ "Session `chat-3`"
      assert instructions =~ "`read_inbox`"
      assert instructions =~ "20 of your turns"
      assert instructions =~ "Prefer small diffs."
      refute instructions =~ "bin/shoestring"

      # Reattaching asks nothing and keeps the conversation and its token.
      assert_received {:mix_shell, :prompt, ["Grant this and start? [y/N] "]}
      Chat.run(["--session", "chat-3"], screen(ctx))
      assert_receive {:mix_shell, :info, [json]}
      assert %{"session_id" => "chat-3", "argv" => [_client | _]} = Jason.decode!(json)
      refute_received {:mix_shell, :prompt, _}
      assert Shoestring.Conversations.get("chat-3").id == conversation.id
      assert File.read!(token_file) == token
    end

    test "needs a coordinator that converses, with an explicit model", ctx do
      {:ok, _} = ModelCatalog.add("opencode", "openai/test-model")

      assert_raise Refusal,
                   ~r/opencode cannot coordinate in the chat screen yet.*--external/,
                   fn ->
                     Chat.run(["--coordinator", "opencode:openai/test-model"], screen(ctx))
                   end

      assert_raise Refusal, ~r/needs an explicit coordinator model/, fn ->
        Chat.run(["--coordinator", "claude:default"], screen(ctx))
      end
    end

    test "a session keeps its coordinator", ctx do
      {:ok, _} = ModelCatalog.add("claude", "sonnet")
      answer("y")
      Chat.run(["--session", "chat-4"], screen(ctx))

      assert_raise Refusal, ~r/already has claude:opus as its coordinator/, fn ->
        Chat.run(["--session", "chat-4", "--coordinator", "claude:sonnet"], screen(ctx))
      end
    end

    test "refuses before asking anything when the client is not installed", ctx do
      context = Map.put(context(ctx), :chat_client, Path.join(ctx.dir, "missing"))

      assert_raise Refusal, ~r/The chat client is not installed.*--external/, fn ->
        Chat.run(["--session", "chat-5"], context)
      end

      refute_received {:mix_shell, :prompt, _}
      assert Grants.active("chat-5") == nil
    end
  end
end
