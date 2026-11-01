defmodule Shoestring.Dispatches.Explore.CodexExecTest do
  @moduledoc """
  The Codex explorer against a scripted stand-in executable that records its
  argv and answers with one shell command and a report; the real CLI and the
  network are never used.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Dispatches.Explore.CodexExec

  @codex """
  import json, os, sys
  with open(os.path.join(os.environ["STANDIN_DIR"], "call.json"), "w") as f:
      json.dump({"argv": sys.argv[1:], "git_config_global": os.environ.get("GIT_CONFIG_GLOBAL")}, f)
  def emit(event): print(json.dumps(event), flush=True)
  emit({"type": "thread.started", "thread_id": "00000000-0000-4000-8000-000000000000"})
  emit({"type": "turn.started"})
  # What codex-cli 0.166.0 reports for a command its code-mode `exec` ran.
  emit({"type": "item.started", "item": {"id": "item_0", "type": "command_execution",
        "command": "/bin/zsh -c 'cat README.md'", "status": "in_progress"}})
  emit({"type": "item.completed", "item": {"id": "item_0", "type": "command_execution",
        "command": "/bin/zsh -c 'cat README.md'", "exit_code": 0, "status": "completed"}})
  emit({"type": "item.completed", "item": {"id": "item_1", "type": "agent_message",
        "text": json.dumps({"summary": "read"})}})
  emit({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 5}})
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "shoestring-explorer-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(dir, "repo"))
    File.write!(Path.join(dir, "codex"), "#!/usr/bin/env python3\n" <> @codex)
    File.chmod!(Path.join(dir, "codex"), 0o755)
    System.put_env("STANDIN_DIR", dir)

    on_exit(fn ->
      System.delete_env("STANDIN_DIR")
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "the shell stays reachable through code mode, under the read-only sandbox", c do
    input = %{
      "workdir" => Path.join(c.dir, "repo"),
      "model" => "gpt-explore",
      "prompt" => "Explore.",
      "schema" => %{"type" => "object"},
      "effort" => nil,
      "timeout_ms" => 60_000,
      "max_output_tokens" => 4096
    }

    test = self()
    progress = &send(test, {:step, &1})

    assert {:ok, _report} =
             CodexExec.explore(input, endpoint: Path.join(c.dir, "codex"), progress: progress)

    assert_received {:step, "Ran /bin/zsh -c 'cat README.md'"}

    call = c.dir |> Path.join("call.json") |> File.read!() |> Jason.decode!()
    argv = Map.fetch!(call, "argv")
    # Git reads no configuration from the denied home directory.
    assert call["git_config_global"] == "/dev/null"

    disabled = argv |> Enum.chunk_every(2, 1, :discard) |> Enum.flat_map(&disabled/1)

    assert "code_mode" in disabled and "apps" in disabled
    refute "code_mode_host" in disabled
    # Before 2026-11-01 `--sandbox read-only`, under which a command could
    # read the whole home directory; now a read-only profile with home denied.
    refute "--sandbox" in argv
    workdir = Shoestring.Harness.CodexAppServer.GitSandbox.physical_path(input["workdir"])
    home = Shoestring.Harness.CodexAppServer.GitSandbox.physical_path(System.user_home!())
    assert ~s(default_permissions="shoestring_run") in argv

    [table] =
      Enum.filter(argv, &String.starts_with?(&1, "permissions.shoestring_run.filesystem="))

    assert table =~ Jason.encode!(home) <> ~s(="deny")
    assert table =~ Jason.encode!(workdir) <> ~s(="read")
    assert table =~ ~s(":root"="read")
    refute table =~ "write"
    assert ~s(approval_policy="never") in argv
  end

  defp disabled(["--disable", feature]), do: [feature]
  defp disabled(_pair), do: []

  test "tokens fail a call only against an allowance it was made with", c do
    input = %{
      "workdir" => Path.join(c.dir, "repo"),
      "model" => "gpt-explore",
      "prompt" => "Explore.",
      "schema" => %{"type" => "object"},
      "effort" => nil,
      "timeout_ms" => nil
    }

    endpoint = [endpoint: Path.join(c.dir, "codex")]

    # A coordinator's call (version 2): no allowance and no deadline.
    assert {:ok, %{output_tokens: 5}} = CodexExec.explore(input, endpoint)

    # A call recorded before iteration 16 keeps its allowance.
    assert {:error, :output_limit} =
             CodexExec.explore(
               Map.merge(input, %{"max_output_tokens" => 4, "timeout_ms" => 60_000}),
               endpoint
             )
  end
end
