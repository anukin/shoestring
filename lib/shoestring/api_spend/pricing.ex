defmodule Shoestring.ApiSpend.Pricing do
  @moduledoc "Frozen, operator-reviewed upper rates for one text-only standard Responses request."
  @version "openai-standard-upper-2026-10-20-v1"
  @entry %{
    "version" => @version,
    "model" => "gpt-6-luna",
    "effective_from" => "2026-10-20",
    "valid_until" => "2026-11-20",
    "context_tokens" => 1_050_000,
    "maximum_output_tokens" => 128_000,
    # Conservative upper rates, not a bill estimate: rounded above documented
    # long-context/cache-write and regional standard rates. No tools, fast
    # service, media, conversations, background jobs or automatic retries.
    "input_microusd_per_million" => 300_000,
    "output_microusd_per_million" => 1_000_000
  }
  def version, do: @version
  def entry, do: @entry

  def quote(config, %DateTime{} = now) do
    entry = Map.get(config, :price_override, @entry)
    output = Map.get(config, :max_output_tokens, 4096)

    with true <- valid_entry?(entry),
         true <- config[:accepted_price_version] == entry["version"],
         true <- config[:model] == entry["model"],
         true <- is_integer(output) and output > 0 and output <= entry["maximum_output_tokens"],
         {:ok, first} <- Date.from_iso8601(entry["effective_from"]),
         {:ok, last} <- Date.from_iso8601(entry["valid_until"]),
         true <-
           Date.compare(first, DateTime.to_date(now)) != :gt and
             Date.compare(last, DateTime.to_date(now)) != :lt do
      pricing = Map.put(entry, "output_token_limit", output)
      {:ok, pricing, amount(pricing, pricing["context_tokens"], output)}
    else
      _ -> {:error, :pricing_not_reviewed_or_compatible}
    end
  end

  def usage_amount(pricing, %{"input_tokens" => input, "output_tokens" => output}) do
    if is_integer(input) and input >= 0 and input <= pricing["context_tokens"] and
         is_integer(output) and output >= 0 and output <= pricing["output_token_limit"],
       do: {:ok, amount(pricing, input, output)},
       else: {:error, :usage_outside_reserved_bounds}
  end

  def usage_amount(_, _), do: {:error, :missing_usage}

  defp amount(pricing, input, output),
    do:
      div(
        input * pricing["input_microusd_per_million"] +
          output * pricing["output_microusd_per_million"] + 999_999,
        1_000_000
      )

  defp valid_entry?(entry) when is_map(entry) do
    Enum.sort(Map.keys(entry)) == Enum.sort(Map.keys(@entry)) and
      entry["model"] == @entry["model"] and
      is_binary(entry["version"]) and Regex.match?(~r/\A[a-z0-9.-]{1,100}\z/, entry["version"]) and
      Enum.all?(
        ~w(context_tokens maximum_output_tokens input_microusd_per_million output_microusd_per_million),
        fn key -> is_integer(entry[key]) and entry[key] in 1..10_000_000_000 end
      ) and
      entry["context_tokens"] >= @entry["context_tokens"] and
      entry["maximum_output_tokens"] <= @entry["maximum_output_tokens"] and
      entry["input_microusd_per_million"] >= @entry["input_microusd_per_million"] and
      entry["output_microusd_per_million"] >= @entry["output_microusd_per_million"] and
      is_binary(entry["effective_from"]) and is_binary(entry["valid_until"])
  end

  defp valid_entry?(_), do: false
end
