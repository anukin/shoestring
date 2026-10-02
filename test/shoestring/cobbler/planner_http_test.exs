defmodule Shoestring.Cobbler.PlannerHttpTest do
  @moduledoc """
  Hermetic tests for the production planner adapter boundary.

  Pure functions (`configured/1`, `request_body/2`, `decode_response/1`)
  are exercised directly, and the live `plan/2` transport path runs the
  real `Req` client against a loopback stub server — no provider, no
  credential, no quota, no network beyond localhost. A real endpoint is
  never contacted: validating against one would spend provider quota.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.PlannerHttp

  describe "configured/1" do
    test "a missing endpoint is not configured and consumes no quota" do
      assert {:error, :planner_not_configured} = PlannerHttp.configured([])
    end

    test "an endpoint without any credential is not configured" do
      assert {:error, :planner_not_configured} =
               PlannerHttp.configured(
                 endpoint: "https://planner.example.invalid/v1/chat/completions"
               )
    end

    test "an endpoint with a key resolves the effective configuration" do
      assert {:ok, config} =
               PlannerHttp.configured(
                 endpoint: "https://planner.example.invalid/v1/chat/completions",
                 model: "planner-small",
                 api_key: "synthetic-key"
               )

      assert config.endpoint == "https://planner.example.invalid/v1/chat/completions"
      assert config.model == "planner-small"
      assert config.api_key == "synthetic-key"
      assert is_integer(config.timeout_ms) and config.timeout_ms > 0
      assert is_integer(config.max_body) and config.max_body > 0
    end

    test "a credential may come from the configured environment variable" do
      System.put_env("SHOESTRING_PLANNER_HTTP_TEST_KEY", "synthetic-env-key")

      assert {:ok, config} =
               PlannerHttp.configured(
                 endpoint: "https://planner.example.invalid/v1/chat/completions",
                 api_key_env: "SHOESTRING_PLANNER_HTTP_TEST_KEY"
               )

      assert config.api_key == "synthetic-env-key"
    after
      System.delete_env("SHOESTRING_PLANNER_HTTP_TEST_KEY")
    end
  end

  describe "request_body/2" do
    test "builds a strict JSON-object chat-completions body" do
      body =
        PlannerHttp.request_body(%{"goal" => %{"statement" => "Keep the gate green."}}, %{
          model: "planner-small"
        })

      assert body["model"] == "planner-small"
      assert body["response_format"] == %{"type" => "json_object"}

      assert [%{"role" => "system", "content" => system}, %{"role" => "user", "content" => user}] =
               body["messages"]

      assert system =~ "single JSON object"
      assert user =~ "Keep the gate green."
    end
  end

  describe "decode_response/1" do
    test "a JSON object string decodes to the plan map" do
      response = %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(%{"version" => 1})}}]
      }

      assert {:ok, %{"version" => 1}} = PlannerHttp.decode_response(response)
    end

    test "an already-decoded object passes through" do
      response = %{"choices" => [%{"message" => %{"content" => %{"version" => 1}}}]}

      assert {:ok, %{"version" => 1}} = PlannerHttp.decode_response(response)
    end

    test "a refusal is distinct from a transport-shaped error" do
      response = %{"choices" => [%{"message" => %{"refusal" => "declined"}}]}

      assert {:error, {:refused, %{"reason" => "model_refused"}}} =
               PlannerHttp.decode_response(response)
    end

    test "non-object content and unknown shapes are invalid responses, never raw echoes" do
      array = %{"choices" => [%{"message" => %{"content" => "[1, 2]"}}]}

      assert {:error, {:invalid_response, %{"reason" => "not_an_object"}}} =
               PlannerHttp.decode_response(array)

      garbage = %{"choices" => [%{"message" => %{"content" => "not json"}}]}

      assert {:error, {:invalid_response, %{"reason" => "invalid_json"}}} =
               PlannerHttp.decode_response(garbage)

      assert {:error, {:invalid_response, %{"reason" => "unexpected_shape"}}} =
               PlannerHttp.decode_response(%{"unexpected" => true})
    end
  end

  describe "identity/0" do
    test "reports a fixed synthetic attribution, never a provider claim" do
      assert %{identity: "http-planner", version: "1", model: model} = PlannerHttp.identity()
      assert is_binary(model)
    end
  end

  describe "plan/2 against a loopback stub (no provider, no quota)" do
    test "a 2xx envelope decodes through the real Req transport" do
      envelope = %{"choices" => [%{"message" => %{"content" => %{"version" => 1}}}]}
      raw = Jason.encode!(envelope)

      with_stub(200, raw, fn endpoint ->
        assert {:ok, %{"version" => 1}} = PlannerHttp.plan(%{"goal" => "x"}, plan_opts(endpoint))
      end)
    end

    test "a non-2xx status is a transport error carrying only the status" do
      with_stub(500, "boom", fn endpoint ->
        assert {:error, {:transport, %{"reason" => "http_status", "status" => 500}}} =
                 PlannerHttp.plan(%{"goal" => "x"}, plan_opts(endpoint))
      end)
    end

    test "invalid JSON is an invalid response, never a raw echo" do
      with_stub(200, "not json", fn endpoint ->
        assert {:error, {:invalid_response, %{"reason" => "invalid_json"}}} =
                 PlannerHttp.plan(%{"goal" => "x"}, plan_opts(endpoint))
      end)
    end

    test "an oversized body fails before decoding" do
      with_stub(200, String.duplicate("x", 64), fn endpoint ->
        assert {:error, {:transport, %{"reason" => "oversized_body"}}} =
                 PlannerHttp.plan(
                   %{"goal" => "x"},
                   plan_opts(endpoint, max_body: 16)
                 )
      end)
    end

    test "a refused connection is a transport error" do
      endpoint = closed_endpoint()

      assert {:error, {:transport, %{"reason" => reason}}} =
               PlannerHttp.plan(%{"goal" => "x"}, plan_opts(endpoint))

      assert reason in ["transport", "request_failed"]
    end
  end

  defp plan_opts(endpoint, extra \\ []) do
    [endpoint: endpoint, model: "planner-small", api_key: "synthetic-key", timeout_ms: 5_000] ++
      extra
  end

  # Serves exactly one canned HTTP response on loopback, then closes. The
  # request is fully consumed first so the client never sees a reset.
  defp with_stub(status, raw_body, fun) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    server = Task.async(fn -> serve_once(listen, status, raw_body) end)

    try do
      fun.("http://127.0.0.1:#{port}/v1/chat/completions")
    after
      assert :ok = Task.await(server, 5_000)
    end
  end

  defp serve_once(listen, status, raw_body) do
    with {:ok, socket} <- :gen_tcp.accept(listen, 5_000),
         {:ok, headers, rest} <- read_headers(socket, ""),
         :ok <- read_request_body(socket, headers, rest),
         :ok <- send_response(socket, status, raw_body) do
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
      :ok
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} ->
        data = acc <> chunk

        case :binary.split(data, "\r\n\r\n") do
          [headers, rest] -> {:ok, headers, rest}
          [_incomplete] -> read_headers(socket, data)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_request_body(socket, headers, rest) do
    wanted = content_length(headers) - byte_size(rest)
    discard(socket, max(wanted, 0))
  end

  defp discard(_socket, 0), do: :ok

  defp discard(socket, wanted) do
    case :gen_tcp.recv(socket, min(wanted, 65_536), 5_000) do
      {:ok, chunk} -> discard(socket, wanted - byte_size(chunk))
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
      [_, digits] -> String.to_integer(digits)
      _other -> 0
    end
  end

  defp send_response(socket, status, raw_body) do
    head =
      "HTTP/1.1 #{status} #{status_phrase(status)}\r\n" <>
        "content-type: application/json\r\n" <>
        "content-length: #{byte_size(raw_body)}\r\n" <>
        "connection: close\r\n\r\n"

    :gen_tcp.send(socket, head <> raw_body)
  end

  defp status_phrase(200), do: "OK"
  defp status_phrase(_status), do: "Error"

  # A port that was just closed: connecting to it must refuse without
  # touching any real server.
  defp closed_endpoint do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    "http://127.0.0.1:#{port}/v1/chat/completions"
  end
end
