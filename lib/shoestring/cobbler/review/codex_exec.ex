defmodule Shoestring.Cobbler.Review.CodexExec do
  @moduledoc """
  A tool-free Codex review: one `codex exec --json` call with the flag set of
  the reviewed isolated proposal capture (`tools/planner_eval/codex_proposal.py`):
  ephemeral, user configuration and rules ignored, read-only sandbox, no
  approvals, no web search, no project documents, every tool feature
  disabled, and the findings schema as `--output-schema`.

  The child runs in its own process group from an empty working directory
  and is killed as a group on overrun. The JSONL stream is bounded: any tool
  or unexpected item, a provider error, an oversized frame or answer, more
  than one final message, a non-zero exit or a missing result fails closed.
  Lines that are not JSON objects are stderr diagnostics (the runner merges
  the streams) and are discarded unparsed. Only the final message text and
  the reported output token count leave this module.

  Codex has no output allowance flag; the reported `output_tokens` is checked
  against the allowance after the call (`:output_limit`).

  VERIFIED live on codex-cli 0.163.0 (2026-10-17, three calls, see
  `plans/evidence/08-verification-cross-review/`): with `--output-schema` the
  final message was a findings object that passed `Review.Findings`.
  """
  @behaviour Shoestring.Cobbler.Review.Adapter

  alias Shoestring.Cobbler.Review.Adapter
  alias Shoestring.Elves.PortRunner

  @max_stream_bytes 8_388_608
  @max_frame_bytes 1_048_576
  @max_answer_bytes 65_536
  @deadline_margin_ms 5_000
  @minimum_deadline_ms 1_000

  @disabled_features ~w(shell_tool unified_exec shell_snapshot apps plugins remote_plugin
    computer_use browser_use code_mode code_mode_host multi_agent multi_agent_v2 memories hooks
    workspace_dependencies goals sleep_tool view_image image_generation tool_suggest
    request_permissions_tool unbounded_connection_retries)

  @impl true
  def review(input, opts) do
    scratch = Path.join(System.tmp_dir!(), "shoestring-reviewer-#{Ecto.UUID.generate()}")
    workdir = Path.join(scratch, "cwd")
    File.mkdir_p!(workdir)
    schema = Path.join(scratch, "schema.json")
    instructions = Path.join(scratch, "instructions.md")
    File.write!(schema, Jason.encode!(input["schema"]))
    File.write!(instructions, Adapter.system_prompt())

    argv =
      [Keyword.get(opts, :endpoint, "codex"), "--no-daemon", "exec"] ++
        ["--model", input["model"], "--ephemeral", "--ignore-user-config", "--ignore-rules"] ++
        ["--skip-git-repo-check", "--sandbox", "read-only", "--cd", workdir] ++
        ["--json", "--color", "never", "--output-schema", schema] ++
        config_flags(instructions) ++
        Enum.flat_map(@disabled_features, &["--disable", &1]) ++
        [input["packet_json"]]

    deadline = max(input["timeout_ms"] - @deadline_margin_ms, @minimum_deadline_ms)

    case PortRunner.spawn(argv, cd: workdir, max_output_bytes: @max_stream_bytes) do
      {:ok, runner} -> runner |> collect(deadline) |> decode(input["max_output_tokens"])
      {:error, _reason} -> {:error, :transport_error}
    end
  end

  defp config_flags(instructions) do
    [
      ~s(approval_policy="never"),
      "agents.enabled=false",
      ~s(web_search="disabled"),
      "project_doc_max_bytes=0",
      ~s(model_reasoning_effort="medium"),
      ~s(model_reasoning_summary="none"),
      "analytics.enabled=false",
      "check_for_update_on_startup=false",
      "model_instructions_file=" <> Jason.encode!(instructions)
    ]
    |> Enum.flat_map(&["-c", &1])
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

        if bytes > @max_stream_bytes do
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
    |> Enum.reduce_while(%{answer: nil, tokens: nil}, &frame/2)
    |> case do
      {:error, _} = error ->
        error

      %{answer: answer, tokens: tokens} when is_binary(answer) and is_integer(tokens) ->
        if tokens <= limit,
          do: {:ok, %{json: answer, output_tokens: tokens}},
          else: {:error, :output_limit}

      _ ->
        {:error, :invalid_transport_response}
    end
  end

  defp frame(line, acc) do
    cond do
      byte_size(line) > @max_frame_bytes -> {:halt, {:error, :output_too_large}}
      not String.starts_with?(line, "{") -> {:cont, acc}
      true -> line |> Jason.decode() |> event(acc)
    end
  end

  defp event({:ok, %{"type" => type} = event}, acc)
       when type in ["item.started", "item.updated", "item.completed"] do
    case event["item"] do
      # Non-fatal startup diagnostics arrive as error items; their text is
      # discarded. A top-level error or a failed turn stays fatal.
      %{"type" => "error"} ->
        {:cont, acc}

      %{"type" => "reasoning"} ->
        {:cont, acc}

      %{"type" => "agent_message"} = item ->
        cond do
          type != "item.completed" -> {:cont, acc}
          not is_binary(item["text"]) -> {:halt, {:error, :invalid_transport_response}}
          byte_size(item["text"]) > @max_answer_bytes -> {:halt, {:error, :output_too_large}}
          acc.answer != nil -> {:halt, {:error, :invalid_transport_response}}
          true -> {:cont, %{acc | answer: item["text"]}}
        end

      _tool_or_unknown ->
        {:halt, {:error, :reviewer_used_tools}}
    end
  end

  defp event({:ok, %{"type" => "turn.completed"} = event}, acc) do
    case get_in(event, ["usage", "output_tokens"]) do
      tokens when is_integer(tokens) and tokens >= 0 -> {:cont, %{acc | tokens: tokens}}
      _ -> {:halt, {:error, :invalid_transport_response}}
    end
  end

  defp event({:ok, %{"type" => type}}, acc) when type in ["thread.started", "turn.started"],
    do: {:cont, acc}

  defp event({:ok, %{"type" => type}}, _acc) when type in ["turn.failed", "error"],
    do: {:halt, {:error, :transport_error}}

  defp event(_other, _acc), do: {:halt, {:error, :invalid_transport_response}}
end
