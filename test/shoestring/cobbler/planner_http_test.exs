defmodule Shoestring.Cobbler.PlannerHttpTest do
  @moduledoc """
  Hermetic tests for the production planner adapter boundary.

  Only pure functions are exercised — configuration resolution, request
  body construction, and response decoding — so no network is used and no
  credential is needed. The live `plan/2` transport path is deliberately
  untested here: invoking it would spend provider quota, and its contract
  (bounded timeout, capped body, secret-free errors) is documented in
  `docs/planner-boundary.md`.
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
end
