# Explicitly authorized review of a prebuilt immutable packet. Never part of
# the hermetic gate. Sending real repository code needs authorization for
# that payload and provider, in addition to a live call budget.
#
# Required: ITER8_PACKET_REVIEW_INPUT, ITER8_PACKET_REVIEW_DIGEST,
# ITER8_PACKET_REVIEW_ROOT (a new directory), ITER8_PACKET_REVIEW_PROVIDER
# (claude|codex). Put the shared provider budget wrappers first on PATH.
# This driver never collects a new diff or an implementation transcript.

alias Shoestring.Cobbler.PlanContract
alias Shoestring.Cobbler.Review.{ClaudeHeadless, CodexExec, Findings}

json = System.fetch_env!("ITER8_PACKET_REVIEW_INPUT") |> File.read!()
true = byte_size(json) <= 1_048_576
packet = Jason.decode!(json)
digest = PlanContract.digest(packet)
true = digest == System.fetch_env!("ITER8_PACKET_REVIEW_DIGEST")
1 = packet["version"]
provider = System.fetch_env!("ITER8_PACKET_REVIEW_PROVIDER")

{adapter, model} =
  case provider do
    "claude" -> {ClaudeHeadless, "opus"}
    "codex" -> {CodexExec, "gpt-6-luna"}
  end

root = System.fetch_env!("ITER8_PACKET_REVIEW_ROOT") |> Path.expand()
false = File.exists?(root)
File.mkdir_p!(root)
File.write!(Path.join(root, "packet.json"), json)

started = System.monotonic_time(:millisecond)

result =
  adapter.review(
    %{
      "packet_json" => json,
      "schema" => Findings.schema(),
      "model" => model,
      "max_output_tokens" => 8192,
      "timeout_ms" => 240_000
    },
    endpoint: provider
  )

summary =
  case result do
    {:ok, %{json: answer, output_tokens: tokens}} ->
      case Findings.validate(answer, packet) do
        {:ok, findings} ->
          %{result: "validated", findings: findings, output_tokens: tokens}

        {:error, reason} ->
          %{result: "validation_failed", reason: inspect(reason), output_tokens: tokens}
      end

    {:error, reason} ->
      %{result: "transport_failed", reason: inspect(reason)}
  end

summary =
  Map.merge(summary, %{
    base: packet["base_commit"],
    commit: packet["commit"],
    reviewer: provider,
    model: model,
    packet_digest: digest,
    elapsed_ms: System.monotonic_time(:millisecond) - started,
    defect_seeded: false
  })

File.write!(Path.join(root, "result.json"), Jason.encode!(summary, pretty: true))
IO.puts(Jason.encode!(summary))
