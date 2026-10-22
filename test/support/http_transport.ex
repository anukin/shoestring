defmodule Shoestring.Test.HTTPTransport do
  @moduledoc "Synthetic HTTP schemas only. No network, provider process or captured output."
  def request(_method, url, body, _headers, opts) do
    if opts[:notify], do: send(opts[:notify], {:http_request, self(), URI.parse(url).path, body})

    if opts[:hold] == true and String.ends_with?(url, "/responses") do
      receive do
        :complete -> :ok
      after
        5_000 -> raise "Synthetic transport was not released"
      end
    end

    case {URI.parse(url).path, opts[:scenario]} do
      {_, :failure} ->
        {:error, :http_transport_uncertain}

      {_, :quota} ->
        {:ok, 429, %{"error" => %{"message" => "Synthetic refusal"}}}

      {"/v1/responses", _} ->
        {:ok, 200,
         %{
           "model" => "gpt-6-luna",
           "service_tier" => "default",
           "status" => "completed",
           "output" => [
             %{"type" => "reasoning", "summary" => [%{"text" => "synthetic-private-thinking"}]},
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Visible answer token=synthetic-private-value"
                 }
               ]
             }
           ],
           "usage" =>
             if(opts[:missing_usage],
               do: nil,
               else: %{"input_tokens" => 1000, "output_tokens" => 500}
             )
         }}

      {"/api/version", _} ->
        {:ok, 200, %{"version" => "0.30.0"}}

      {"/api/tags", _} ->
        {:ok, 200,
         %{
           "models" => [
             %{
               "name" => "fixture:local",
               "digest" => String.duplicate("a", 64),
               "size" => 100,
               "details" => %{"format" => "gguf"},
               "remote_host" => if(opts[:cloud], do: "cloud.example", else: nil)
             }
           ]
         }}

      {"/api/show", _} ->
        {:ok, 200, %{"details" => %{"format" => "gguf"}}}

      {"/api/generate", _} ->
        {:ok, 200,
         %{
           "model" => "fixture:local",
           "done" => true,
           "done_reason" => "stop",
           "thinking" => "synthetic-private-thinking",
           "response" => "Visible local answer"
         }}
    end
  end
end
