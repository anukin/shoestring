defmodule Shoestring.Cobbler.ReviewAdaptersTest do
  @moduledoc """
  The Codex and Claude reviewer adapters against scripted stand-in
  executables; the real CLIs and the network are never used. The stand-ins
  record their argv and working directory, then behave per mode.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Cobbler.Review.{ClaudeHeadless, CodexExec, Findings, Fixture}

  @findings ~s({"verdict":"approve","summary":"Fine.","findings":[]})

  @codex """
  import json, os, sys, time
  out = os.environ["STANDIN_DIR"]
  with open(os.path.join(out, "call.json"), "w") as f:
      json.dump({"argv": sys.argv[1:], "cwd": os.getcwd(), "cwd_entries": os.listdir(os.getcwd())}, f)
  mode = os.environ["STANDIN_MODE"]
  answer = os.environ["STANDIN_ANSWER"]
  def emit(event): print(json.dumps(event), flush=True)
  def message(text): emit({"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": text}})
  def done(tokens=42): emit({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": tokens}})
  if mode == "ok":
      print("2026-10-17T00:00:00Z WARN a stderr diagnostic line", flush=True)
      emit({"type": "thread.started", "thread_id": "00000000-0000-4000-8000-000000000000"})
      emit({"type": "turn.started"})
      emit({"type": "item.completed", "item": {"id": "item_0", "type": "error", "message": "startup diagnostic"}})
      emit({"type": "item.completed", "item": {"id": "item_r", "type": "reasoning", "text": "hidden"}})
      message(answer)
      done()
  elif mode == "tool":
      emit({"type": "item.started", "item": {"id": "item_1", "type": "command_execution", "command": "ls"}})
      message(answer); done()
  elif mode == "two_messages":
      message(answer); message(answer); done()
  elif mode == "turn_failed":
      emit({"type": "turn.failed", "error": {"message": "boom"}})
  elif mode == "exit":
      message(answer); done(); sys.exit(2)
  elif mode == "no_usage":
      message(answer)
  elif mode == "over_limit":
      message(answer); done(9000)
  elif mode == "bad_json":
      print("{not json", flush=True)
  elif mode == "hang":
      with open(os.path.join(out, "pid"), "w") as f: f.write(str(os.getpid()))
      time.sleep(60)
  """

  @claude """
  import json, os, sys
  out = os.environ["STANDIN_DIR"]
  with open(os.path.join(out, "call.json"), "w") as f:
      json.dump({"argv": sys.argv[1:], "cwd": os.getcwd()}, f)
  print(json.dumps({"type": "result", "subtype": "success", "is_error": False,
                    "usage": {"output_tokens": 7}, "result": "",
                    "structured_output": json.loads(os.environ["STANDIN_ANSWER"])}))
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "shoestring-reviewer-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    for {name, body} <- [{"codex", @codex}, {"claude", @claude}] do
      File.write!(Path.join(dir, name), "#!/usr/bin/env python3\n" <> body)
      File.chmod!(Path.join(dir, name), 0o755)
    end

    System.put_env("STANDIN_DIR", dir)
    System.put_env("STANDIN_ANSWER", @findings)

    on_exit(fn ->
      for key <- ~w(STANDIN_DIR STANDIN_MODE STANDIN_ANSWER), do: System.delete_env(key)
    end)

    %{dir: dir}
  end

  test "codex: a tool-free, read-only, ephemeral call from an empty directory", c do
    assert {:ok, %{json: @findings, output_tokens: 42}} = codex(c, "ok")
    call = call(c)
    argv = call["argv"]

    assert Enum.take(argv, 2) == ["--no-daemon", "exec"]

    for flag <- ~w(--ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check --json),
        do: assert(flag in argv)

    assert after_flag(argv, "--sandbox") == "read-only"
    assert after_flag(argv, "--model") == "gpt-review"
    # The child reports the resolved path (/var is /private/var on macOS).
    assert after_flag(argv, "--cd") ==
             String.replace_prefix(call["cwd"], "/private/var/", "/var/")

    assert call["cwd_entries"] == []
    assert ~s(approval_policy="never") in argv
    assert ~s(web_search="disabled") in argv
    assert "project_doc_max_bytes=0" in argv

    disabled =
      argv
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(&(hd(&1) == "--disable"))
      |> Enum.map(&List.last/1)

    for feature <-
          ~w(shell_tool unified_exec apps plugins browser_use computer_use multi_agent memories hooks),
        do: assert(feature in disabled)

    # The findings schema is passed as a file; the packet is the prompt.
    schema = after_flag(argv, "--output-schema")
    assert Jason.decode!(File.read!(schema)) == Findings.schema()
    assert List.last(argv) == ~s({"packet":true})
  end

  test "codex: tools, extra messages, failures and bounds fail closed", c do
    assert {:error, :reviewer_used_tools} = codex(c, "tool")
    assert {:error, :invalid_transport_response} = codex(c, "two_messages")
    assert {:error, :transport_error} = codex(c, "turn_failed")
    assert {:error, :transport_error} = codex(c, "exit")
    assert {:error, :invalid_transport_response} = codex(c, "no_usage")
    assert {:error, :output_limit} = codex(c, "over_limit")
    assert {:error, :invalid_transport_response} = codex(c, "bad_json")

    # Overrun: the adapter kills the whole group itself, before the caller's
    # task timeout would (timeout minus a 5 s margin, floor 1 s).
    {elapsed_us, result} = :timer.tc(fn -> codex(c, "hang", %{"timeout_ms" => 6_000}) end)
    assert result == {:error, :transport_timeout}
    assert elapsed_us < 5_500_000
    pid = c.dir |> Path.join("pid") |> File.read!() |> String.trim()
    assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "claude: the planner's tool-free call with the findings schema and the packet", c do
    input = input(%{"model" => "opus"})

    assert {:ok, %{json: json, output_tokens: 7}} =
             ClaudeHeadless.review(input, endpoint: Path.join(c.dir, "claude"))

    assert Jason.decode!(json) == Jason.decode!(@findings)
    argv = call(c)["argv"]
    assert "--tools=" in argv
    assert "--no-session-persistence" in argv
    assert Jason.decode!(after_flag(argv, "--json-schema")) == Findings.schema()
    assert after_flag(argv, "--system-prompt") =~ "code review function"
    assert List.last(argv) == ~s({"packet":true})
    assert File.ls!(call(c)["cwd"]) == []
  end

  test "fixture: seeded markers become blocking findings at their added lines" do
    diff = """
    diff --git a/calc.py b/calc.py
    --- a/calc.py
    +++ b/calc.py
    @@ -1,2 +1,3 @@
     def add(a, b):
    -    raise NotImplementedError
    +    x = 1
    +    return a - b  # #{Fixture.marker()} subtracts
    """

    packet = %{
      "diff" => diff,
      "changed_files" => [%{"path" => "calc.py"}],
      "repository_files" => []
    }

    {:ok, %{json: json}} = Fixture.review(%{"packet_json" => Jason.encode!(packet)}, [])

    assert {:ok, %{"outcome" => "changes_requested", "findings" => [finding]}} =
             Findings.validate(json, packet)

    assert finding["path"] == "calc.py"
    assert finding["line"] == 3
    assert finding["claim"] == "subtracts"
    assert finding["reference"] == "supported"
  end

  defp codex(c, mode, input \\ %{}) do
    System.put_env("STANDIN_MODE", mode)

    CodexExec.review(input(Map.merge(%{"model" => "gpt-review"}, input)),
      endpoint: Path.join(c.dir, "codex")
    )
  end

  defp input(overrides) do
    Map.merge(
      %{
        "packet_json" => ~s({"packet":true}),
        "schema" => Findings.schema(),
        "max_output_tokens" => 4096,
        "timeout_ms" => 60_000
      },
      overrides
    )
  end

  defp call(c), do: c.dir |> Path.join("call.json") |> File.read!() |> Jason.decode!()

  defp after_flag(argv, flag), do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)
end
