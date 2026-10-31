defmodule Shoestring.Harness.ClaudeHeadless.OneShot do
  @moduledoc """
  One tool-free structured `claude --print --output-format stream-json` call,
  shared by the planner and the reviewer: every tool disabled (`--tools=`), no
  MCP servers, no saved session, the schema passed as `--json-schema` and the
  prompt as the last argument.

  stream-json, unlike json, carries Claude's own usage reports
  (`rate_limit_event`); each becomes a capacity reading
  (`Shoestring.Harness.ClaudeHeadless.CapacityReading`, sink `:capacity_sink`).
  The final `result` frame has the same members as json's single result,
  `structured_output` included (VERIFIED offline with Claude Code 2.1.316
  against a scripted model).

  The child runs in its own process group (`Shoestring.Elves.PortRunner`)
  from an empty working directory, so it sees no repository and no project
  instructions. An EXPLORE call (`Shoestring.Dispatches.Explore.ClaudeHeadless`)
  instead names read-only `:tools`, its `:workdir` (a private copy of the
  repository) and `:extra_args`. This module enforces its own deadline (the caller's timeout
  minus a margin, at least one second; none when `:timeout_ms` is nil) and
  kills the whole group on overrun or when the collecting process is sent
  `{:cancel_call, reason}` (`Shoestring.Harness.FrameCollector`); killing the
  calling task alone could leave a `claude` process spending quota. When
  `:max_output_tokens` is given, `CLAUDE_CODE_MAX_OUTPUT_TOKENS` carries it
  and the reported `usage.output_tokens` is checked against it; otherwise the
  count is only returned.

  A tool-free call keeps every frame; a call with tools keeps only the frames
  the result is read from (the model's messages and tool results, an
  EXPLORE's file contents among them, are progress only). A line over
  #{div(8_388_608, 1_048_576)} MiB, or kept frames over #{div(8_388_608, 1_048_576)} MiB fail as
  `:output_too_large`, never truncated. Only
  the result JSON leaves this module; the rest of the result, including any
  provider identifiers, is discarded in memory. The result is accepted as
  `structured_output` or as JSON text in `result` (VERIFIED for planning in
  the 7A live run: `structured_output`). Nothing is classified as a quota
  refusal: no refusal shape has been captured, so a provider error is a
  transport error.
  """
  alias Shoestring.Elves.PortRunner
  alias Shoestring.Dispatches.Explore.Progress
  alias Shoestring.Harness.ClaudeHeadless.CapacityReading
  alias Shoestring.Harness.FrameCollector

  @max_output_bytes 8_388_608
  @deadline_margin_ms 5_000
  @minimum_deadline_ms 1_000

  @type input :: %{
          required(:endpoint) => String.t(),
          required(:model) => String.t(),
          required(:schema) => map(),
          required(:system_prompt) => String.t(),
          required(:prompt) => String.t(),
          required(:max_output_tokens) => pos_integer() | nil,
          required(:timeout_ms) => pos_integer() | nil,
          required(:scratch_prefix) => String.t(),
          optional(:tools) => String.t(),
          optional(:workdir) => Path.t(),
          optional(:extra_args) => [String.t()],
          optional(:capacity_sink) => module() | (term() -> term()) | nil,
          optional(:progress) => (String.t() -> term()) | nil
        }

  @spec call(input()) ::
          {:ok, %{json: String.t(), output_tokens: non_neg_integer()}} | {:error, atom()}
  def call(input) do
    workdir =
      Map.get_lazy(input, :workdir, fn ->
        dir = Path.join(System.tmp_dir!(), "#{input.scratch_prefix}-#{Ecto.UUID.generate()}")
        File.mkdir_p!(dir)
        dir
      end)

    argv = [
      input.endpoint,
      "--print",
      "--output-format",
      "stream-json",
      "--verbose",
      "--model",
      input.model,
      "--tools=" <> Map.get(input, :tools, ""),
      "--strict-mcp-config",
      "--no-session-persistence"
    ]

    argv =
      argv ++
        Map.get(input, :extra_args, []) ++
        [
          "--json-schema",
          Jason.encode!(input.schema),
          "--system-prompt",
          input.system_prompt,
          input.prompt
        ]

    env =
      [{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}] ++
        if input.max_output_tokens,
          do: [{"CLAUDE_CODE_MAX_OUTPUT_TOKENS", Integer.to_string(input.max_output_tokens)}],
          else: []

    case PortRunner.spawn(argv, cd: workdir, env: env, max_output_bytes: @max_output_bytes) do
      {:ok, runner} ->
        sink = Map.get_lazy(input, :capacity_sink, &CapacityReading.default_sink/0)

        runner
        |> FrameCollector.collect(
          deadline_ms: deadline(input.timeout_ms),
          keep: if(Map.get(input, :tools, "") == "", do: fn _frame -> true end, else: &kept?/1),
          each: Progress.each(&Progress.claude/1, Map.get(input, :progress)),
          max_kept_bytes: @max_output_bytes,
          max_line_bytes: @max_output_bytes
        )
        |> decode(input.max_output_tokens, sink)

      {:error, _reason} ->
        {:error, :transport_error}
    end
  end

  defp deadline(nil), do: nil
  defp deadline(ms), do: max(ms - @deadline_margin_ms, @minimum_deadline_ms)

  # With tools (an EXPLORE), the model's messages and the tools' results are
  # progress only. A tool-free call keeps every frame, so its whole output
  # counts against the bound.
  defp kept?(%{"type" => type}) when type in ["assistant", "user", "stream_event"], do: false
  defp kept?(_frame), do: true

  defp decode({:error, _} = error, _limit, _sink), do: error

  defp decode({:ok, frames}, limit, sink) do
    version = Enum.find_value(frames, &CapacityReading.version/1)
    Enum.each(frames, &CapacityReading.record(&1, version, sink))

    frames
    |> Enum.reverse()
    |> Enum.find_value({:error, :invalid_transport_response}, &result(&1, limit))
  end

  defp result(%{"type" => "result"} = result, limit), do: structured(result, limit)
  defp result(_frame, _limit), do: nil

  defp structured(
         %{"is_error" => false, "subtype" => "success", "usage" => usage} = result,
         limit
       ) do
    with tokens when is_integer(tokens) and tokens >= 0 <- usage["output_tokens"],
         true <- (is_nil(limit) or tokens <= limit) || :output_limit,
         {:ok, json} <- json(result) do
      {:ok, %{json: json, output_tokens: tokens}}
    else
      :output_limit -> {:error, :output_limit}
      _ -> {:error, :invalid_transport_response}
    end
  end

  defp structured(_result, _limit), do: {:error, :transport_error}

  defp json(%{"structured_output" => value}) when is_map(value), do: {:ok, Jason.encode!(value)}
  defp json(%{"result" => text}) when is_binary(text) and text != "", do: {:ok, text}
  defp json(_result), do: :error
end
