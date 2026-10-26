defmodule Shoestring.Harnesses.ModelListingTest do
  @moduledoc """
  Model listing: parsing the replies each harness CLI gave on 2026-10-25
  (excerpts in `test/fixtures/model_listing/`) and the exchange itself
  against small local fake CLIs. No provider CLI runs.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Harnesses.ModelListing

  @fixtures Path.expand("../../fixtures/model_listing", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  describe "parse" do
    test "Codex: every visible model, its efforts and the default" do
      %{"data" => data} = fixture("codex_model_list_result.json")
      assert {:ok, %{models: models, skipped: 0}} = ModelListing.parse("codex", data)
      assert length(models) == 7

      assert %{
               "display_name" => "GPT-6-Luna",
               "efforts" => ["low", "medium", "high", "xhigh", "max"],
               "default_effort" => "medium",
               "default" => false
             } = Enum.find(models, &(&1["model"] == "gpt-6-luna"))

      assert [%{"model" => "gpt-6.1-sol"}] = Enum.filter(models, & &1["default"])

      hidden = [Map.put(hd(data), "hidden", true)]
      assert {:ok, %{models: []}} = ModelListing.parse("codex", hidden)
    end

    test "opencode: every model option, no efforts, and its current model as default" do
      reply = fixture("opencode_session_new_config_options.json")
      assert {:ok, %{models: models, skipped: 0}} = ModelListing.parse("opencode", reply)
      assert length(models) == 150
      assert Enum.all?(models, &(&1["efforts"] == [] and String.contains?(&1["model"], "/")))

      assert [%{"model" => "opencode-go/iceman-contributor-free"}] =
               Enum.filter(models, & &1["default"])
    end

    test "Claude Code: aliases with the model they resolve to and their efforts" do
      assert {:ok, %{models: models, skipped: 0}} =
               ModelListing.parse("claude", fixture("claude_initialize_models.json"))

      assert length(models) == 13

      assert %{
               "resolves_to" => "claude-opus-5-5",
               "efforts" => ["low", "medium", "high", "xhigh", "max"],
               "default" => false
             } = Enum.find(models, &(&1["model"] == "opus"))

      assert %{"efforts" => []} = Enum.find(models, &(&1["model"] == "claude-haiku-4-5-20251001"))
      assert %{"default" => true} = Enum.find(models, &(&1["model"] == "default"))
    end

    test "unusable entries are counted, names are cleaned, and an oversized list fails" do
      reply = %{
        "models" => [
          %{"value" => "opus", "displayName" => "Opus\e[31m \u0007 5"},
          %{"value" => "two words"},
          %{"value" => nil},
          %{"value" => "opus", "displayName" => "duplicate"}
        ]
      }

      assert {:ok, %{models: [%{"display_name" => "Opus[31m  5"}], skipped: 2}} =
               ModelListing.parse("claude", reply)

      many = %{"models" => for(n <- 1..501, do: %{"value" => "model-#{n}"})}
      assert ModelListing.parse("claude", many) == {:error, :too_many_models}

      assert ModelListing.parse("opencode", %{"configOptions" => []}) ==
               {:error, :unexpected_reply}

      assert ModelListing.parse("codex", %{}) == {:error, :unexpected_reply}
    end
  end

  describe "list against a local fake CLI" do
    @tag :tmp_dir
    test "Codex pages through nextCursor", %{tmp_dir: dir} do
      cli =
        fake_cli(dir, """
        for line in sys.stdin:
            frame = json.loads(line)
            if frame.get("method") == "initialize":
                reply({"id": frame["id"], "result": {}})
            elif frame.get("method") == "model/list":
                if frame["params"].get("cursor") == "p2":
                    reply({"id": frame["id"], "result": {"data": [{"model": "b"}], "nextCursor": None}})
                else:
                    reply({"id": frame["id"], "result": {"data": [{"model": "a", "isDefault": True}], "nextCursor": "p2"}})
        """)

      assert {:ok, %{models: [%{"model" => "a", "default" => true}, %{"model" => "b"}]}} =
               ModelListing.list("codex", executable: cli)
    end

    @tag :tmp_dir
    test "opencode ignores a request from the CLI that reuses an id", %{tmp_dir: dir} do
      cli =
        fake_cli(dir, """
        for line in sys.stdin:
            frame = json.loads(line)
            if frame["method"] == "initialize":
                reply({"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": 1}})
            elif frame["method"] == "session/new":
                reply({"jsonrpc": "2.0", "id": 2, "method": "session/request_permission", "params": {}})
                print("not json", flush=True)
                options = [{"value": "opencode/x", "name": "X"}]
                reply({"jsonrpc": "2.0", "id": 2, "result": {"sessionId": "ses_1",
                       "configOptions": [{"id": "model", "currentValue": "opencode/x", "options": options}]}})
        """)

      assert {:ok, %{models: [%{"model" => "opencode/x", "default" => true}]}} =
               ModelListing.list("opencode", executable: cli)
    end

    @tag :tmp_dir
    test "Claude Code answers initialize with its models", %{tmp_dir: dir} do
      cli =
        fake_cli(dir, """
        for line in sys.stdin:
            frame = json.loads(line)
            reply({"type": "system", "subtype": "init"})
            reply({"type": "control_response", "response": {"subtype": "success",
                   "request_id": frame["request_id"],
                   "response": {"account": {"email": "x@example.com"}, "models": [{"value": "opus"}]}}})
        """)

      assert {:ok, %{models: [%{"model" => "opus"}]}} =
               ModelListing.list("claude", executable: cli)
    end

    @tag :tmp_dir
    test "an error reply is refused, and silence times out with the CLI stopped", %{tmp_dir: dir} do
      refusing =
        fake_cli(dir, """
        for line in sys.stdin:
            frame = json.loads(line)
            reply({"id": frame["id"], "error": {"message": "not signed in"}})
        """)

      assert ModelListing.list("codex", executable: refusing) == {:error, :listing_refused}

      pid_file = Path.join(dir, "silent.pid")

      silent =
        fake_cli(dir, """
        open(#{inspect(pid_file)}, "w").write(str(os.getpid()))
        for line in sys.stdin:
            pass
        """)

      assert ModelListing.list("codex", executable: silent, timeout_ms: 300) == {:error, :timeout}
      os_pid = pid_file |> File.read!() |> String.trim()
      assert {_, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
      assert status != 0
    end

    test "a harness with no listing is refused before anything starts" do
      assert ModelListing.list("gemini") == {:error, :unsupported_harness}
    end
  end

  defp fake_cli(dir, body) do
    path = Path.join(dir, "fake-#{System.unique_integer([:positive])}")

    File.write!(path, """
    #!/usr/bin/env python3
    import json, os, sys

    def reply(frame):
        print(json.dumps(frame), flush=True)

    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end
end
