defmodule Shoestring.Harness.ClaudeHeadless.ConversationTest do
  # Not async: one test sets ANTHROPIC_API_KEY in this OS process's environment.
  use ExUnit.Case, async: false

  import Shoestring.Harness.ConversationContractSuite, only: [next_event: 1, events_until: 2]

  alias Shoestring.Harness.ClaudeHeadless.Conversation
  alias Shoestring.Harness.Error

  @cli Path.expand("../../../support/fake_claude_converse.py", __DIR__)
  @token "tok-test-not-a-secret-0001"

  setup context do
    dir = Path.join(System.tmp_dir!(), "conversation-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    log = Path.join(dir, "cli.jsonl")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    Map.merge(context, %{log: log, repo: repo})
  end

  defp spec(context, overrides) do
    Map.merge(
      %{
        owner: self(),
        workdir: context.repo,
        model: "opus",
        effort: "high",
        instructions: "COORDINATOR-INSTRUCTIONS",
        tools: %{url: "http://127.0.0.1:4999/mcp", token: @token}
      },
      overrides
    )
  end

  defp open!(context, overrides \\ %{}, opts \\ []) do
    {:ok, pid} =
      Conversation.start_link(
        spec(context, overrides),
        [executable: @cli, env: [{"FAKE_CLAUDE_LOG", context.log}]] ++ opts
      )

    on_exit(fn -> Conversation.close(pid) end)
    %{type: :session} = next_event(pid)
    pid
  end

  defp launches(context) do
    context.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  test "Claude's usage reports become capacity readings and nothing else", context do
    test = self()

    sink = fn snapshot ->
      send(test, {:reading, snapshot})
      {:ok, :recorded, snapshot}
    end

    pid = open!(context, %{}, capacity_sink: sink)
    :ok = Conversation.send_turn(pid, "t1", "USAGE")
    events = events_until(pid, :turn_completed)

    assert_receive {:reading, snapshot}
    assert %{"capacity:cli_version" => "2.1.312"} = snapshot.extensions

    assert [%{kind: "five_hour", used_percent: 83.0}, %{kind: "seven_day", used_percent: 40.0}] =
             snapshot.windows
             |> Enum.sort_by(& &1.kind)
             |> Enum.map(&Map.take(&1, [:kind, :used_percent]))

    assert Enum.map(events, & &1.type) -- [:turn_started] == [:text, :turn_completed]

    # A turn with no report records nothing.
    :ok = Conversation.send_turn(pid, "t2", "SAY hi")
    events_until(pid, :turn_completed)
    refute_received {:reading, _}
  end

  describe "argv/3" do
    test "is read-only, keeps MCP reachable and never carries the token" do
      paths = %{mcp_config: "/private/mcp.json", instructions: "/private/instructions.md"}

      argv =
        Conversation.argv(
          %{model: "opus", effort: "high", tools: %{url: "u", token: @token}},
          paths,
          "sid"
        )

      assert "--tools=Read,Grep,Glob" in argv

      assert ["--allowedTools", "mcp__shoestring"] ==
               Enum.slice(argv, Enum.find_index(argv, &(&1 == "--allowedTools")), 2)

      assert ["--mcp-config", "/private/mcp.json"] ==
               Enum.slice(argv, Enum.find_index(argv, &(&1 == "--mcp-config")), 2)

      assert "--strict-mcp-config" in argv and "--restricted" in argv

      assert ["--setting-sources", ""] ==
               Enum.slice(argv, Enum.find_index(argv, &(&1 == "--setting-sources")), 2)

      assert ["--permission-mode", "dontAsk"] ==
               Enum.slice(argv, Enum.find_index(argv, &(&1 == "--permission-mode")), 2)

      # --safe-mode would also turn off MCP servers (Phase 0).
      refute "--safe-mode" in argv
      refute Enum.any?(argv, &String.contains?(&1, @token))
      assert ["--session-id", "sid"] == Enum.take(argv, -2)
    end

    test "resumes with --resume and allows no MCP tool without an endpoint" do
      paths = %{mcp_config: "/private/mcp.json", instructions: nil}
      argv = Conversation.argv(%{model: "opus", resume: "sid"}, paths, "sid")

      assert ["--resume", "sid"] == Enum.take(argv, -2)
      refute "--allowedTools" in argv
      refute "--append-system-prompt-file" in argv
      refute "--effort" in argv
      assert Conversation.mcp_config(%{model: "opus"}) == %{"mcpServers" => %{}}
    end
  end

  test "launches in the repository with a private 0600 tool config and removes it on close",
       context do
    pid = open!(context)
    [launch] = launches(context)

    assert launch["cwd"] |> Path.expand() |> real() == real(context.repo)
    assert launch["mcp"]["mode"] == "0o600"

    assert launch["mcp"]["content"]["mcpServers"]["shoestring"]["headers"]["Authorization"] ==
             "Bearer " <> @token

    refute Enum.any?(launch["argv"], &String.contains?(&1, @token))

    assert ["--effort", "high"] ==
             Enum.slice(launch["argv"], Enum.find_index(launch["argv"], &(&1 == "--effort")), 2)

    private = Path.dirname(launch["mcp"]["path"])
    assert File.dir?(private)
    assert %File.Stat{mode: mode} = File.stat!(private)
    assert Bitwise.band(mode, 0o777) == 0o700
    assert File.read!(Path.join(private, "instructions.md")) == "COORDINATOR-INSTRUCTIONS"

    :ok = Conversation.close(pid)
    refute File.exists?(private)
  end

  test "removes ANTHROPIC_API_KEY so the coordinator never uses a paid key", context do
    previous = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-test-not-a-key")

    on_exit(fn ->
      if previous,
        do: System.put_env("ANTHROPIC_API_KEY", previous),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)

    _pid = open!(context)
    assert [%{"api_key_set" => false}] = launches(context)
  end

  test "forwards visible text and tool names, never reasoning or tool input and output",
       context do
    pid = open!(context)

    :ok = Conversation.send_turn(pid, "t1", "THINK")
    events = events_until(pid, :turn_completed)
    assert [%{text: "visible"}] = Enum.filter(events, &(&1.type == :text))

    :ok = Conversation.send_turn(pid, "t2", "CALL mcp__shoestring__dispatch")
    events = events ++ events_until(pid, :turn_completed)

    rendered = inspect(events, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ "hidden reasoning"
    refute rendered =~ "secret_input"
    refute rendered =~ "tool output never forwarded"
    assert rendered =~ "mcp__shoestring__dispatch"
  end

  test "reports Claude's token usage on the completed turn", context do
    pid = open!(context)
    :ok = Conversation.send_turn(pid, "t1", "SAY hi")

    assert %{usage: usage} = List.last(events_until(pid, :turn_completed))

    assert usage == %{
             "input_tokens" => 12,
             "output_tokens" => 3,
             "cache_read_input_tokens" => 7,
             "cache_creation_input_tokens" => 0
           }
  end

  test "refuses an effort the model does not offer before any turn", context do
    assert {:error, %Error{code: "effort_not_offered"}} =
             Conversation.start_link(spec(context, %{model: "sonnet", effort: "high"}),
               executable: @cli
             )

    assert {:error, %Error{code: "invalid_tools"}} =
             Conversation.start_link(
               spec(context, %{tools: %{url: "http://example.com/mcp", token: @token}}),
               executable: @cli
             )
  end

  test "Claude's echo of an unknown model is not an offer; a hand-added model can be allowed",
       context do
    assert {:error, %Error{code: "model_not_offered"}} =
             Conversation.start_link(spec(context, %{model: "claude-new-1"}), executable: @cli)

    {:ok, pid} =
      Conversation.start_link(spec(context, %{model: "claude-new-1", effort: nil}),
        executable: @cli,
        allow_unlisted_model: true
      )

    on_exit(fn -> Conversation.close(pid) end)
    assert %{type: :session} = next_event(pid)

    assert {:ok, pid} =
             Conversation.start_link(spec(context, %{model: "claude-opus-5-5"}), executable: @cli)

    on_exit(fn -> Conversation.close(pid) end)
  end

  test "reports a new session id when Claude reports one", context do
    pid = open!(context)
    :ok = Conversation.send_turn(pid, "t1", "REKEY 99999999-0000-4000-8000-000000000000")

    events = events_until(pid, :turn_completed)

    assert %{provider_session_id: "99999999-0000-4000-8000-000000000000"} =
             Enum.find(events, &(&1.type == :session))

    assert %{provider_session_id: "99999999-0000-4000-8000-000000000000"} =
             Conversation.status(pid)
  end

  test "an oversized line closes the conversation instead of truncating it", context do
    pid = open!(context)
    ref = Process.monitor(pid)
    :ok = Conversation.send_turn(pid, "t1", "BIG 5000000")

    assert %{type: :closed, reason: :oversized_frame, turn_id: "t1"} =
             List.last(events_until(pid, :closed))

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  test "resuming a session refuses a silently substituted provider session", context do
    session = "11111111-2222-4333-8444-555555555555"
    pid = open!(context, %{resume: session})
    :ok = Conversation.send_turn(pid, "t1", "REKEY 99999999-0000-4000-8000-000000000000")
    events = events_until(pid, :closed)
    assert %{type: :closed, turn_id: "t1", reason: :provider_session_changed} = List.last(events)
    refute Enum.any?(events, &(&1.type == :session))
    refute Enum.any?(events, &(&1.type == :turn_completed))
  end

  test "a CLI that exits mid-turn closes the conversation and names the open turn", context do
    pid = open!(context)
    ref = Process.monitor(pid)
    :ok = Conversation.send_turn(pid, "t1", "EXIT 3")

    assert %{type: :closed, reason: {:exited, {:exit_status, 3}}, turn_id: "t1"} =
             List.last(events_until(pid, :closed))

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  test "close reaps processes the CLI started", context do
    pid = open!(context, %{}, exit_wait_ms: 200)
    :ok = Conversation.send_turn(pid, "t1", "SPAWN")
    _ = events_until(pid, :turn_completed)

    child = Enum.find_value(launches(context), & &1["spawned"])
    assert alive?(child)

    :ok = Conversation.close(pid)
    refute alive?(child)
  end

  test "the owner going away closes the conversation and reaps it", context do
    test = self()

    owner =
      spawn(fn ->
        {:ok, pid} =
          Conversation.start_link(spec(context, %{owner: self()}),
            executable: @cli,
            env: [{"FAKE_CLAUDE_LOG", context.log}],
            exit_wait_ms: 200
          )

        Process.unlink(pid)
        send(test, {:conversation, pid})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:conversation, pid}, 5_000
    ref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  defp real(path) do
    case System.cmd("realpath", [path], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> path
    end
  end
end
