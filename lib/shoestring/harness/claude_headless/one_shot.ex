defmodule Shoestring.Harness.ClaudeHeadless.OneShot do
  @moduledoc """
  One tool-free structured `claude --print --output-format json` call, shared
  by the planner and the reviewer: every tool disabled (`--tools=`), no MCP
  servers, no saved session, the schema passed as `--json-schema` and the
  prompt as the last argument.

  The child runs in its own process group (`Shoestring.Elves.PortRunner`)
  from an empty working directory, so it sees no repository and no project
  instructions. An EXPLORE call (`Shoestring.Dispatches.Explore.ClaudeHeadless`)
  instead names read-only `:tools`, its `:workdir` (a private copy of the
  repository) and `:extra_args`. This module enforces its own deadline (the caller's timeout
  minus a margin, at least one second) and kills the whole group on overrun;
  killing the calling task alone could leave a `claude` process spending
  quota. `CLAUDE_CODE_MAX_OUTPUT_TOKENS` carries the charged output allowance,
  and the reported `usage.output_tokens` is returned for the caller to check.

  Output over the byte cap fails as `:output_too_large`, never truncated. Only
  the result JSON leaves this module; the rest of the result, including any
  provider identifiers, is discarded in memory. The result is accepted as
  `structured_output` or as JSON text in `result` (VERIFIED for planning in
  the 7A live run: `structured_output`). Nothing is classified as a quota
  refusal: no refusal shape has been captured, so a provider error is a
  transport error.
  """
  alias Shoestring.Elves.PortRunner

  @max_output_bytes 262_144
  @deadline_margin_ms 5_000
  @minimum_deadline_ms 1_000

  @type input :: %{
          required(:endpoint) => String.t(),
          required(:model) => String.t(),
          required(:schema) => map(),
          required(:system_prompt) => String.t(),
          required(:prompt) => String.t(),
          required(:max_output_tokens) => pos_integer(),
          required(:timeout_ms) => pos_integer(),
          required(:scratch_prefix) => String.t(),
          optional(:tools) => String.t(),
          optional(:workdir) => Path.t(),
          optional(:extra_args) => [String.t()]
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
      "json",
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

    env = [
      {"CLAUDE_CODE_MAX_OUTPUT_TOKENS", Integer.to_string(input.max_output_tokens)},
      {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}
    ]

    deadline = max(input.timeout_ms - @deadline_margin_ms, @minimum_deadline_ms)

    case PortRunner.spawn(argv, cd: workdir, env: env, max_output_bytes: @max_output_bytes) do
      {:ok, runner} -> runner |> collect(deadline) |> decode(input.max_output_tokens)
      {:error, _reason} -> {:error, :transport_error}
    end
  end

  defp collect(runner, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect(runner, deadline, [], 0)
  end

  defp collect(%PortRunner{port: port} = runner, deadline, chunks, bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        bytes = bytes + byte_size(data)

        if bytes > @max_output_bytes do
          _ = PortRunner.terminate(runner)
          {:error, :output_too_large}
        else
          collect(runner, deadline, [chunks, data], bytes)
        end

      {^port, {:exit_status, 0}} ->
        _ = PortRunner.close(runner)
        {:ok, IO.iodata_to_binary(chunks)}

      {^port, {:exit_status, _status}} ->
        _ = PortRunner.close(runner)
        {:error, :transport_error}
    after
      remaining ->
        _ = PortRunner.terminate(runner)
        {:error, :transport_timeout}
    end
  end

  defp decode({:error, _} = error, _limit), do: error

  defp decode({:ok, output}, limit) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value({:error, :invalid_transport_response}, &result(&1, limit))
  end

  defp result(line, limit) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = result} -> structured(result, limit)
      _ -> nil
    end
  end

  defp structured(
         %{"is_error" => false, "subtype" => "success", "usage" => usage} = result,
         limit
       ) do
    with tokens when is_integer(tokens) and tokens >= 0 <- usage["output_tokens"],
         true <- tokens <= limit || :output_limit,
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
