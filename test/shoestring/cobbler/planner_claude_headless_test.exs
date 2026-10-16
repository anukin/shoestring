defmodule Shoestring.Cobbler.PlannerClaudeHeadlessTest do
  @moduledoc """
  The Claude planner adapter against a scripted stand-in executable; the real
  `claude` CLI and the network are never used. Scratch directories are kept.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.Planner.ClaudeHeadless

  @plan %{"version" => 1, "tasks" => []}

  # The stand-in records its argv, cwd and token env, then behaves per MODE.
  @script """
  import json, os, sys, time
  out = os.environ["STANDIN_DIR"]
  with open(os.path.join(out, "call.json"), "w") as f:
      json.dump({"argv": sys.argv[1:], "cwd": os.getcwd(), "pgid": os.getpgid(0),
                 "max_tokens": os.environ.get("CLAUDE_CODE_MAX_OUTPUT_TOKENS")}, f)
  mode = os.environ["STANDIN_MODE"]
  plan = {"version": 1, "tasks": []}
  def result(**extra):
      r = {"type": "result", "subtype": "success", "is_error": False,
           "session_id": "00000000-0000-4000-8000-000000000000",
           "usage": {"output_tokens": 12}}
      r.update(extra)
      print(json.dumps(r))
  if mode == "structured":
      print("warning: something on stderr", file=sys.stderr)
      result(result="", structured_output=plan)
  elif mode == "text":
      result(result=json.dumps(plan))
  elif mode == "error":
      result(subtype="error_during_execution", is_error=True)
  elif mode == "exit":
      sys.exit(3)
  elif mode == "over_limit":
      result(result=json.dumps(plan), usage={"output_tokens": 5000})
  elif mode == "no_usage":
      result(result=json.dumps(plan), usage={})
  elif mode == "flood":
      sys.stdout.write("x" * 300000); sys.stdout.flush()
  elif mode == "hang":
      with open(os.path.join(out, "pid"), "w") as f: f.write(str(os.getpid()))
      time.sleep(60)
  elif mode == "silent":
      pass
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "shoestring-claude-planner-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "claude")
    File.write!(script, "#!/usr/bin/env python3\n" <> @script)
    File.chmod!(script, 0o755)
    %{dir: dir, script: script}
  end

  defp generate(context, mode, input \\ %{}) do
    System.put_env("STANDIN_DIR", context.dir)
    System.put_env("STANDIN_MODE", mode)

    input =
      Map.merge(
        %{
          "projection" => %{"goal_id" => "g"},
          "schema" => %{"type" => "object"},
          "model" => "opus",
          "attempt" => 1,
          "max_output_tokens" => 4096,
          "timeout_ms" => 60_000,
          "validation_errors" => []
        },
        input
      )

    ClaudeHeadless.generate(input, endpoint: context.script)
  end

  defp call(context), do: context.dir |> Path.join("call.json") |> File.read!() |> Jason.decode!()

  # Env vars are process-global for the OS, so these cases run in one test.
  test "launch, results and failures", context do
    assert {:ok, %{json: json, output_tokens: 12}} = generate(context, "structured")
    assert Jason.decode!(json) == @plan

    call = call(context)
    argv = call["argv"]

    for flag <- ["--print", "--tools=", "--strict-mcp-config", "--no-session-persistence"],
        do: assert(flag in argv)

    assert ["--output-format", "json"] == Enum.slice(argv, 1, 2)
    assert Enum.at(argv, Enum.find_index(argv, &(&1 == "--model")) + 1) == "opus"

    assert Enum.at(argv, Enum.find_index(argv, &(&1 == "--json-schema")) + 1) ==
             ~s({"type":"object"})

    assert Jason.decode!(List.last(argv)) == %{
             "projection" => %{"goal_id" => "g"},
             "validation_errors" => []
           }

    # Empty scratch working directory, its own process group, token cap in env.
    assert File.ls!(call["cwd"]) == []
    refute call["cwd"] == File.cwd!()
    assert call["max_tokens"] == "4096"

    assert {:ok, %{json: text, output_tokens: 12}} = generate(context, "text")
    assert Jason.decode!(text) == @plan

    assert {:error, :transport_error} = generate(context, "error")
    assert {:error, :transport_error} = generate(context, "exit")
    assert {:error, :output_limit} = generate(context, "over_limit")
    assert {:error, :invalid_transport_response} = generate(context, "no_usage")
    assert {:error, :invalid_transport_response} = generate(context, "silent")
    assert {:error, :output_too_large} = generate(context, "flood")

    # Overrun: the adapter kills the whole group itself, before the planner's
    # task timeout would (timeout_ms minus a 5 s margin, floor 1 s).
    {elapsed_us, result} =
      :timer.tc(fn -> generate(context, "hang", %{"timeout_ms" => 6_000}) end)

    assert result == {:error, :transport_timeout}
    assert elapsed_us < 5_500_000
    pid = context.dir |> Path.join("pid") |> File.read!() |> String.trim()
    assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end
end
