defmodule Shoestring.Dispatches.Explore.CodexExec do
  @moduledoc """
  A read-only Codex EXPLORE call: one `codex exec --json` in the private copy
  of the repository, with the `read-only` sandbox (no writes, no network),
  no approvals, no web search, no project documents, user configuration and
  rules ignored, an ephemeral session, every feature but the shell (reached
  through code mode's `exec` from codex-cli 0.166.0) disabled and the report
  schema as `--output-schema`. The shell lets it read and search files.

  The JSONL stream is read by `Shoestring.Harness.FrameCollector`, which
  keeps only the frames the result is read from (commands and their output
  are progress, never kept): a provider error, a non-zero exit or a missing
  result fails closed, as does a kept stream over its bound. A file change or
  any tool other than a command fails as `explorer_wrote` or
  `explorer_used_tools`; the report is the last agent message. The call runs
  until its `timeout_ms` (none when nil) or until it is cancelled; its
  output tokens are recorded, and fail it only when `max_output_tokens` is
  given.

  UNVERIFIED in a live call; the request it sends was checked offline
  (`plans/evidence/14-coordinator-orchestration/`).
  """
  @behaviour Shoestring.Dispatches.Explore.Adapter

  alias Shoestring.Dispatches.Explore
  alias Shoestring.Dispatches.Explore.Progress
  alias Shoestring.Elves.PortRunner
  alias Shoestring.Harness.FrameCollector
  alias Shoestring.Harness.CodexAppServer.GitSandbox

  @max_stream_bytes 8_388_608
  @deadline_margin_ms 5_000
  @minimum_deadline_ms 1_000

  # The code-mode host stays enabled: from codex-cli 0.166.0 the shell is
  # reached only through code mode's `exec`. Commands run under Shoestring's
  # read-only permission profile (`GitSandbox.read_only_permissions/2`): the
  # repository copy readable, the home directory denied, nothing writable.
  @disabled_features ~w(apps plugins remote_plugin computer_use browser_use code_mode
    multi_agent multi_agent_v2 memories hooks workspace_dependencies goals
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
        ["--skip-git-repo-check", "--cd", workdir] ++
        GitSandbox.config_flags(GitSandbox.read_only_permissions([workdir])) ++
        ["--json", "--color", "never", "--output-schema", schema] ++
        config_flags(instructions, input["effort"]) ++
        Enum.flat_map(@disabled_features, &["--disable", &1]) ++
        [input["prompt"]]

    # Git reads no configuration from the home directory the profile denies.
    case PortRunner.spawn(argv,
           cd: workdir,
           max_output_bytes: @max_stream_bytes,
           env: Shoestring.Harness.ClaudeHeadless.Sandbox.git_env()
         ) do
      {:ok, runner} ->
        runner
        |> FrameCollector.collect(
          deadline_ms: deadline(input["timeout_ms"]),
          keep: &kept?/1,
          each: Progress.each(&Progress.codex/1, Keyword.get(opts, :progress))
        )
        |> decode(input["max_output_tokens"])

      {:error, _reason} ->
        {:error, :transport_error}
    end
  end

  defp deadline(nil), do: nil
  defp deadline(ms), do: max(ms - @deadline_margin_ms, @minimum_deadline_ms)

  # Commands, their output and reasoning are progress only.
  defp kept?(%{"item" => %{"type" => kind}})
       when kind in ["error", "reasoning", "command_execution", "todo_list"],
       do: false

  defp kept?(_frame), do: true

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

  defp decode({:error, _} = error, _limit), do: error

  defp decode({:ok, frames}, limit) do
    frames
    |> Enum.reduce_while(%{answer: nil, tokens: nil}, &event({:ok, &1}, &2))
    |> case do
      {:error, _} = error ->
        error

      %{answer: answer, tokens: tokens} when is_binary(answer) and is_integer(tokens) ->
        if is_nil(limit) or tokens <= limit,
          do: {:ok, %{json: answer, output_tokens: tokens}},
          else: {:error, :output_limit}

      _ ->
        {:error, :invalid_transport_response}
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
