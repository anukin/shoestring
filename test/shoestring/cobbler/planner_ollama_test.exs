defmodule Shoestring.Cobbler.PlannerOllamaTest do
  use ExUnit.Case, async: true
  alias Shoestring.Cobbler.Planner.{Configuration, Ollama, Schema}
  import Shoestring.Test.PlanFixtures

  defp input do
    %{
      "model" => "fixture-local",
      "projection" => %{"goal_contract" => goal()},
      "schema" => Schema.for_goal(goal()),
      "validation_errors" => [],
      "max_output_tokens" => 64,
      "timeout_ms" => 1000
    }
  end

  defp options(plug), do: [endpoint: "http://127.0.0.1:11434", plug: plug]

  test "configured model receives strict structured output request without tools or thinking" do
    plug = fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/generate"
      body = conn.body_params
      assert body["model"] == "fixture-local"
      assert body["format"] == input()["schema"]
      assert body["options"]["num_predict"] == 64
      assert body["stream"] == false
      assert body["think"] == false
      refute Map.has_key?(body, "tools")

      Req.Test.json(conn, %{
        "done" => true,
        "done_reason" => "stop",
        "response" => "{}",
        "eval_count" => 3,
        "thinking" => "private-reasoning-marker"
      })
    end

    assert {:ok, %{json: "{}", output_tokens: 3} = result} =
             Ollama.generate(input(), options(plug))

    refute inspect(result) =~ "private-reasoning-marker"
    assert result.json == "{}"
  end

  test "HTTP refusal and transport timeout each make exactly one call" do
    owner = self()

    for status <- [429, 503, 500, 302] do
      plug = fn conn ->
        send(owner, {:called, status})

        conn
        |> Plug.Conn.put_resp_header("location", "http://localhost/elsewhere")
        |> Plug.Conn.send_resp(status, "private-error-marker")
      end

      assert {:error, _} = Ollama.generate(input(), options(plug))
      assert_received {:called, ^status}
      refute_received {:called, ^status}
    end

    plug = fn conn ->
      send(owner, :transport_called)
      Req.Test.transport_error(conn, :timeout)
    end

    assert {:error, :transport_error} = Ollama.generate(input(), options(plug))
    assert_received :transport_called
    refute_received :transport_called
  end

  test "oversized response fails instead of returning a truncated plan" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 131_073)) end
    assert {:error, :output_too_large} = Ollama.generate(input(), options(plug))
  end

  test "chunked response obeys the whole-body cap" do
    plug = fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("x", 100_000))
      {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("y", 31_073))
      conn
    end

    assert {:error, :output_too_large} = Ollama.generate(input(), options(plug))
  end

  test "missing usage, unfinished output and output-limit results are refused" do
    for result <- [
          %{"done" => true, "response" => "{}"},
          %{"done" => false, "response" => "{}", "eval_count" => 3},
          %{"done" => true, "response" => "{}", "eval_count" => 65},
          %{"done" => true, "response" => "{}", "eval_count" => 3, "done_reason" => "length"}
        ] do
      assert {:error, _} =
               Ollama.generate(input(), options(fn conn -> Req.Test.json(conn, result) end))
    end
  end

  test "remote endpoints, credentials and provider selection outside the registry fail closed" do
    for endpoint <- [
          "https://example.com",
          "http://user:pass@localhost",
          "http://localhost/path",
          "http://localhost?redirect=example.com"
        ] do
      assert {:error, :invalid_planner_endpoint} =
               Configuration.load(
                 config: [adapter: :ollama, model: "fixture-local", endpoint: endpoint]
               )
    end

    assert {:error, :unsupported_planner_adapter} =
             Configuration.load(config: [adapter: "untrusted-module", model: "fixture"])

    assert {:ok, config} = Configuration.load(config: [adapter: :ollama, model: "fixture-local"])
    assert config.public["support_tier"] == "reactive_only"
    assert config.public["max_attempts"] == 2
  end
end
