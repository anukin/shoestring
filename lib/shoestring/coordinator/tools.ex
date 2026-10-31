defmodule Shoestring.Coordinator.Tools do
  @moduledoc """
  The tools a coordinator conversation calls over MCP (iteration 15, package
  B). Each is an iteration 14 coordinator command, called through the same
  domain functions and returning the same JSON:

    * `dispatch` — `shoestring dispatch` (with `dry_run`).
    * `runs_list`, `runs_show`, `runs_log`, `runs_cancel` — `shoestring runs`.
    * `capacity` — `shoestring capacity`.
    * `advice` — `shoestring advice`.
    * `read_inbox` — the session's inbox (`Shoestring.Conversations.inbox/1`),
      which has no command.

  The session and repository come from the caller's token binding
  (`Shoestring.Coordinator.ToolTokens`), never from arguments, so a
  coordinator acts only under its own grant, in its own repository, and sees
  only its own session's dispatches. Grants and admission decide as they do
  for the commands; nothing here records a human decision. `wait` has no
  tool: the conversation engine wakes the coordinator when a dispatch
  settles.
  """

  alias Shoestring.CLI.Commands.{Capacity, Dispatch, Runs}
  alias Shoestring.Dispatches

  @list %{"type" => "array", "items" => %{"type" => "string"}}
  @dispatch_id %{"type" => "string", "description" => "A dispatch id from this session"}

  @tools [
    %{
      "name" => "dispatch",
      "description" =>
        "Hand one task to Shoestring under this session's grant. IMPLEMENT runs as a sandboxed " <>
          "Elf on WORKER in a private copy of the repository at HEAD; the checks decide " <>
          "acceptance and the result is a verified commit (the person's checkout is never " <>
          "changed). EXPLORE answers the brief read-only in one call; REVIEW has a model of " <>
          "another vendor review a completed IMPLEMENT (`of`). A retry with the same " <>
          "request_id returns the same dispatch. `dry_run` checks the grant and plan and " <>
          "records nothing. A dispatch the grant does not cover is refused; nothing is queued.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "purpose" => %{"type" => "string", "enum" => ["implement", "explore", "review"]},
          "worker" => %{
            "type" => "string",
            "description" => "PROVIDER:MODEL, e.g. codex:gpt-6-luna"
          },
          "title" => %{"type" => "string", "description" => "One line"},
          "brief" => %{
            "type" => "string",
            "description" => "What the worker reads (up to 16000 characters)"
          },
          "effort" => %{"type" => "string"},
          "reviewer" => %{
            "type" => "string",
            "description" =>
              "IMPLEMENT only: PROVIDER:MODEL of another vendor that reviews the change"
          },
          "of" => %{
            "type" => "string",
            "description" => "REVIEW only: the completed IMPLEMENT dispatch"
          },
          "files" => Map.put(@list, "description", "Files the task should change"),
          "stay_out" => Map.put(@list, "description", "Paths the task must not change"),
          "accept" => Map.put(@list, "description", "Acceptance criteria"),
          "gates" => Map.put(@list, "description", "Named gates to run"),
          "tests" => Map.put(@list, "description", "Test files to run"),
          "attempts" => %{"type" => "integer", "minimum" => 1, "description" => "Default 1"},
          "minutes" => %{"type" => "integer", "minimum" => 1, "description" => "Default 30"},
          "batch" => %{"type" => "string"},
          "batch_size" => %{"type" => "integer", "minimum" => 1},
          "request_id" => %{"type" => "string"},
          "dry_run" => %{"type" => "boolean"}
        },
        "required" => ["purpose", "worker", "title", "brief"]
      }
    },
    %{
      "name" => "runs_list",
      "description" => "This session's dispatches with their states.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "runs_show",
      "description" =>
        "One dispatch: attempts and time used, what a waiting dispatch waits for, and once " <>
          "it completes the verified commit, its checks and the commands to take it; for " <>
          "EXPLORE and REVIEW, its report.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"dispatch" => @dispatch_id},
        "required" => ["dispatch"]
      }
    },
    %{
      "name" => "runs_log",
      "description" =>
        "What happened to a dispatch, oldest first, from the recorded history (never the " <>
          "worker's transcript). Pass `last_sequence` back as `after` for what happened since.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "dispatch" => @dispatch_id,
          "after" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["dispatch"]
      }
    },
    %{
      "name" => "runs_cancel",
      "description" =>
        "Cancel one dispatch of this session; everything it started is reaped and other " <>
          "dispatches keep running.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"dispatch" => @dispatch_id, "reason" => %{"type" => "string"}},
        "required" => ["dispatch", "reason"]
      }
    },
    %{
      "name" => "capacity",
      "description" => "Each provider's usage reading and outlook against the standing reserves.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "advice",
      "description" =>
        "What finished runs of each kind looked like (tokens, first-try acceptance, " <>
          "duration), with sample counts. It never changes admission.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "read_inbox",
      "description" =>
        "Every time one of this session's dispatches settled (completed, failed, " <>
          "cancelled, waiting, held or needs you), oldest first, and whether a turn " <>
          "has delivered it. Shoestring starts a turn with new entries when you are idle.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @strings ~w(purpose worker title brief effort reviewer of batch request_id)
  @lists ~w(files stay_out accept gates tests)
  @integers ~w(attempts minutes batch_size)

  @doc "The tool definitions, as MCP `tools/list` returns them."
  def list, do: @tools

  @doc """
  Calls tool `name` with `arguments` for `binding`. `{:ok, data}` (the
  command's JSON as data) or `{:error, message}` (its refusal).
  """
  @spec call(String.t(), map(), Shoestring.Coordinator.ToolTokens.binding()) ::
          {:ok, term()} | {:error, String.t()}
  def call("dispatch", args, binding) do
    with {:ok, fields} <- dispatch_fields(args, binding),
         {:ok, request} <- Dispatch.build_request(fields) do
      if args["dry_run"] == true, do: dry_run(request), else: create(request)
    end
  end

  def call("runs_list", _args, binding),
    do: {:ok, Enum.map(Dispatches.list(binding.session_id), &Dispatch.summary/1)}

  def call("runs_show", args, binding) do
    with {:ok, dispatch} <- own_dispatch(args, binding) do
      _ = Dispatches.advance(dispatch)
      {:ok, Runs.detail(dispatch)}
    end
  end

  def call("runs_log", args, binding) do
    with {:ok, dispatch} <- own_dispatch(args, binding),
         {:ok, after_sequence} <- non_negative(args["after"]) do
      {:ok, Runs.log(dispatch, after_sequence)}
    end
  end

  def call("runs_cancel", args, binding) do
    with {:ok, dispatch} <- own_dispatch(args, binding),
         {:ok, reason} <- required_string(args, "reason") do
      case Dispatches.cancel(dispatch, reason) do
        {:ok, _} ->
          {:ok, Dispatch.summary(dispatch)}

        {:error, :not_started} ->
          {:error, "That dispatch never started; there is nothing to cancel."}

        {:error, reason} ->
          {:error, "Not cancelled: #{inspect(reason, limit: 8)}"}
      end
    end
  end

  def call("capacity", _args, _binding), do: {:ok, Capacity.report()}
  def call("advice", _args, _binding), do: {:ok, Shoestring.Advice.report(Shoestring.Repo)}
  def call("read_inbox", _args, binding), do: Shoestring.Conversations.inbox(binding.session_id)
  def call(name, _args, _binding), do: {:error, "Unknown tool: #{name}"}

  defp dry_run(request) do
    case Dispatches.dry_run(request) do
      {:ok, report} -> {:ok, Map.put(report, "capacity", Capacity.for_provider(request.provider))}
      {:error, reason} -> {:error, Dispatch.message(reason, request)}
    end
  end

  defp create(request) do
    case Dispatches.create(request) do
      {:ok, dispatch, outcome} ->
        {:ok, Dispatch.created(dispatch, outcome)}

      {:error, reason} ->
        {:error, Dispatch.message(reason, request)}
    end
  end

  defp dispatch_fields(args, binding) do
    with :ok <- required(args, ~w(purpose worker title brief)),
         :ok <- typed(args, @strings, &is_binary/1, "a string"),
         :ok <- typed(args, @lists, &string_list?/1, "a list of strings"),
         :ok <- typed(args, @integers, &(is_integer(&1) and &1 > 0), "a positive integer") do
      fields =
        for key <- @strings ++ @lists ++ @integers, Map.has_key?(args, key), into: %{} do
          {String.to_existing_atom(key), args[key]}
        end

      {:ok, Map.merge(fields, %{session_id: binding.session_id, repository: binding.repository})}
    end
  end

  defp required(args, keys) do
    case Enum.find(keys, &(not (is_binary(args[&1]) and args[&1] != ""))) do
      nil -> :ok
      key -> {:error, "dispatch needs `#{key}`"}
    end
  end

  defp typed(args, keys, valid?, kind) do
    case Enum.find(
           keys,
           &(Map.has_key?(args, &1) and not is_nil(args[&1]) and not valid?.(args[&1]))
         ) do
      nil -> :ok
      key -> {:error, "`#{key}` must be #{kind}"}
    end
  end

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp own_dispatch(args, binding) do
    with {:ok, id} <- required_string(args, "dispatch") do
      case Dispatches.get(id) do
        %{session_id: session} = dispatch when session == binding.session_id -> {:ok, dispatch}
        _ -> {:error, "Dispatch not found in this session: #{id}"}
      end
    end
  end

  defp required_string(args, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "`#{key}` is required"}
    end
  end

  defp non_negative(nil), do: {:ok, 0}
  defp non_negative(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative(_value), do: {:error, "`after` must be a non-negative integer"}
end
