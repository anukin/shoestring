defmodule Shoestring.Dispatches.Explore.CodexExec do
  @moduledoc """
  A read-only Codex EXPLORE call: one `codex exec --json` in the private copy
  of the repository, with the `read-only` sandbox (no writes, no network),
  no approvals, no web search, no project documents, user configuration and
  rules ignored, an ephemeral session, every feature but the shell disabled
  and the report schema as `--output-schema`. The shell lets it read and
  search files.

  The JSONL stream is bounded like the reviewer's
  (`Shoestring.Cobbler.Review.CodexExec`): an oversized frame or answer, a
  provider error, a non-zero exit or a missing result fails closed. A file
  change or any tool other than a command fails as `explorer_wrote` or
  `explorer_used_tools`; the report is the last agent message.

  UNVERIFIED in a live call; the request it sends was checked offline
  (`plans/evidence/14-coordinator-orchestration/`).
  """
  @behaviour Shoestring.Dispatches.Explore.Adapter

  alias Shoestring.Dispatches.Explore
  alias Shoestring.Elves.PortRunner

  @max_stream_bytes 8_388_608
  @max_frame_bytes 1_048_576
  @deadline_margin_ms 5_000
  @minimum_deadline_ms 1_000

  @disabled_features ~w(apps plugins remote_plugin computer_use browser_use code_mode
    code_mode_host multi_agent multi_agent_v2 memories hooks workspace_dependencies goals
    sleep_tool view_image image_generation tool_suggest request_permissions_tool
    unbounded_connection_retries)

  @impl true
  def explore(input, opts) do
    scratch = Path.join(System.tmp_dir!(), "shoestring-explorer-#{Ecto.UUID.generate()}")
    File.mkdir_p!(scratch)
    schema = Path.join(scratch, "schema.json")
    instructions = Path.join(scratch, "instructions.md")
    File.write!(schema, Jason.encode!(input["schema"]))
    File.write!(instructions, Explore.system_prompt())
    workdir = input["workdir"]

    argv =
      [Keyword.get(opts, :endpoint, "codex"), "--no-daemon", "exec"] ++
        ["--model", input["model"], "--ephemeral", "--ignore-user-config", "--ignore-rules"] ++
        ["--skip-git-repo-check", "--sandbox", "read-only", "--cd", workdir] ++
        ["--json", "--color", "never", "--output-schema", schema] ++
        config_flags(instructions, input["effort"]) ++
        Enum.flat_map(@disabled_features, &["--disable", &1]) ++
        [input["prompt"]]

    deadline = max(input["timeout_ms"] - @deadline_margin_ms, @minimum_deadline_ms)

    case PortRunner.spawn(argv, cd: workdir, max_output_bytes: @max_stream_bytes) do
      {:ok, runner} -> runner |> collect(deadline) |> decode(input["max_output_tokens"])
      {:error, _reason} -> {:error, :transport_error}
    end
  end

  defp config_flags(instructions, effort) do
    [
      ~s(approval_policy="never"),
      "agents.enabled=false",
      ~s(web_search="disabled"),
      "project_doc_max_bytes=0",
      ~s(model_reasoning_effort="#{effort || "medium"}"),
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
      %{"type" => kind} when kind in ["error", "reasoning", "command_execution", "todo_list"] ->
        {:cont, acc}

      %{"type" => "agent_message"} = item ->
        cond do
          type != "item.completed" ->
            {:cont, acc}

          not is_binary(item["text"]) ->
            {:halt, {:error, :invalid_transport_response}}

          byte_size(item["text"]) > Explore.max_report_bytes() ->
            {:halt, {:error, :report_too_large}}

          true ->
            {:cont, %{acc | answer: item["text"]}}
        end

      %{"type" => "file_change"} ->
        {:halt, {:error, :explorer_wrote}}

      _tool_or_unknown ->
        {:halt, {:error, :explorer_used_tools}}
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
