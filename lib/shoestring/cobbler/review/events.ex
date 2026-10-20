defmodule Shoestring.Cobbler.Review.Events do
  @moduledoc "Strict validation of cross-review events beyond their registered field schemas."
  alias Shoestring.Cobbler.Review.Findings
  alias Shoestring.Harness.{Contract, Security}

  @human ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/
  @sha ~r/\A[0-9a-f]{64}\z/
  @commit ~r/\A[0-9a-f]{40,64}\z/

  def validate("cobbler.plan.task.review_requested", p) do
    check(
      p["round"] in 1..3 and p["attempt"] >= 1 and sha?(p["packet_digest"]) and
        commit?(p["base_commit"]) and commit?(p["commit"]) and configuration?(p["configuration"]),
      :review_requested
    )
  end

  def validate("cobbler.plan.review.confirmed", p),
    do: check(human?(p["confirmed_by"]) and p["attempt"] >= 1, :confirmed_by)

  def validate("cobbler.plan.review.attempt.started", p),
    do: check(p["call"] in 1..2 and p["output_token_allowance"] in 1..8192, :call)

  def validate("cobbler.plan.task.reviewed", p) do
    check(
      p["outcome"] in ~w(approved changes_requested failed) and sha?(p["packet_digest"]) and
        commit?(p["commit"]) and result?(p),
      :reviewed
    )
  end

  def validate("cobbler.plan.review.decided", p) do
    with {:ok, _} <- Contract.text(p["reason"], :reason, max: 2000) do
      check(human?(p["decided_by"]) and p["decision"] in ~w(accept reject retry), :decided_by)
    end
  end

  def validate("cobbler.plan.task.review_blocked", p) do
    with {:ok, _} <- Contract.text(p["reason"], :reason, max: 2000) do
      check(
        p["gate"] == "cross_review" and p["retry_state"] in ~w(retry escalate needs_user) and
          commit?(p["commit"]) and (is_nil(p["duration_ms"]) or p["duration_ms"] >= 0),
        :review_blocked
      )
    end
  end

  def validate(_type, _payload), do: :ok

  # The findings of a completed review revalidate on replay: canonical JSON,
  # secret-free, and a blocking count that matches the findings themselves.
  defp result?(%{"outcome" => "failed"} = p),
    do: is_nil(p["findings_json"]) and is_nil(p["blocking_count"])

  defp result?(p) do
    with json when is_binary(json) <- p["findings_json"],
         {:ok, %{"findings" => findings} = result} <- Jason.decode(json),
         [] <- Security.scan_term(result),
         count = Enum.count(findings, &Findings.blocking?/1) do
      blocking? = count > 0
      requested? = p["outcome"] == "changes_requested"

      count == p["blocking_count"] and requested? == blocking? and
        result["outcome"] == p["outcome"]
    else
      _ -> false
    end
  end

  defp configuration?(%{"version" => "1"} = config) do
    Security.scan_term(config) == [] and
      (is_binary(config["unavailable"]) or
         (is_binary(config["provider_id"]) and config["max_rounds"] in 1..3 and
            config["max_output_tokens"] in 1..8192 and sha?(config["endpoint_digest"])))
  end

  defp configuration?(_config), do: false

  defp human?(value), do: is_binary(value) and Regex.match?(@human, value)
  defp sha?(value), do: is_binary(value) and Regex.match?(@sha, value)
  defp commit?(value), do: is_binary(value) and Regex.match?(@commit, value)

  defp check(true, _field), do: :ok
  defp check(_false, field), do: Contract.invalid(field, "must be a bounded cross-review fact")
end
