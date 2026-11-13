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
    * `decisions_list`, `decisions_show` — `shoestring decision list|show`
      for this session's plans (iteration 19). Read-only: there is no tool
      that answers a decision; only the person chooses.

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
          "records nothing. A dispatch the grant does not cover is refused; nothing is queued. " <>
          "EXTERNAL (only when the grant allows it; no agent or worker) is work a person or a " <>
          "program does outside Shoestring's guarantee, in a worktree Shoestring makes, accepted " <>
          "by the checks: propose it only when the work cannot run as a sandboxed worker (a " <>
          "desktop app, a signed-in browser). It always waits for the person to start it, and " <>
          "only the person completes or abandons it; tell them the brief and the budget.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "purpose" => %{
            "type" => "string",
            "enum" => ["implement", "explore", "review", "external"]
          },
          "agent" => %{
            "type" => "string",
            "description" =>
              "An agent of the session's team, by slug or job (explorer, implementer, " <>
                "reviewer): its model and effort are used. Give this or `worker`."
          },
          "worker" => %{
            "type" => "string",
            "description" => "PROVIDER:MODEL, e.g. codex:gpt-6-luna. Give this or `agent`."
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
          "minutes" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" =>
              "Time the dispatch may take. IMPLEMENT default 30. EXPLORE and REVIEW default " <>
                "to the grant's per-dispatch limit; size them to the question (a narrow " <>
                "lookup needs minutes, a broad audit more). A finished dispatch counts only " <>
                "the time it took against the grant."
          },
          "tasks" => %{
            "type" => "array",
            "minItems" => 2,
            "maxItems" => 8,
            "description" =>
              "IMPLEMENT only: a batch of tasks that may run at once, each in its own " <>
                "worktree, sharing the brief, checks and reviewer. Each changes only its own " <>
                "`files`; overlapping or shared files (lockfiles, configuration, migrations) " <>
                "are refused. The result is one commit per task.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "title" => %{"type" => "string"},
                "brief" => %{"type" => "string", "description" => "This task only (1000 chars)"},
                "files" => Map.put(@list, "description", "Files or directories it changes")
              },
              "required" => ["title", "files"]
            }
          },
          "lessons" =>
            Map.put(
              @list,
              "description",
              "Codes of approved lessons to give the worker with the brief (at most 5)"
            ),
          "after" => %{
            "type" => "string",
            "description" =>
              "IMPLEMENT and EXTERNAL: another IMPLEMENT or EXTERNAL dispatch of this session to follow. This one " <>
                "waits (state `chained`, its room reserved) and starts from that one's " <>
                "verified commit once it completes, instead of HEAD; taking its commit takes " <>
                "both. Called off if that one is cancelled."
          },
          "units" =>
            Map.put(
              @list,
              "description",
              "EXTERNAL only: NAME=N for each grant unit to reserve (default: each unit's " <>
                "per-dispatch reserve)"
            ),
          "batch" => %{"type" => "string"},
          "batch_size" => %{"type" => "integer", "minimum" => 1},
          "request_id" => %{"type" => "string"},
          "dry_run" => %{"type" => "boolean"}
        },
        "required" => ["purpose", "title", "brief"]
      }
    },
    %{
      "name" => "decisions_list",
      "description" =>
        "The decisions this session's plans wait on the person to choose among a task's " <>
          "candidates, and recent answers: question, each option's key and label, state. " <>
          "Read-only: only the person answers a decision; tell them.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "decisions_show",
      "description" =>
        "One decision of this session's plans: its question, options, state, who answered " <>
          "and the web page where the person sees the candidates. Read-only.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "decision" => %{
            "type" => "string",
            "description" => "A decision id from decisions_list"
          }
        },
        "required" => ["decision"]
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
    },
    %{
      "name" => "lessons_search",
      "description" =>
        "This repository's lessons the person approved, best match for `query` first (the " <>
          "newest without one). Cite one in a dispatch's `lessons` for its worker to see it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string", "description" => "Words to match"}}
      }
    },
    %{
      "name" => "lessons_propose",
      "description" =>
        "Propose a lesson for this repository: one rule a worker can follow, that cost time " <>
          "and will be true again, not already in the repository's documents. Name its " <>
          "source: `dispatch` (one of this session's) or `quote` (the person's own words in " <>
          "this chat, exactly). Approved at once when Shoestring's checks pass (at most 1024 " <>
          "bytes, secrets removed, not a repeat), unless it is much like an approved lesson: " <>
          "then it waits for `lessons_decide`. The person sees it and may reword or retire it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{"type" => "string", "description" => "The rule, in a sentence or two"},
          "why" => %{"type" => "string", "description" => "What it cost, briefly"},
          "dispatch" => %{"type" => "string", "description" => "Source: a dispatch id"},
          "quote" => %{"type" => "string", "description" => "Source: the person's words"}
        },
        "required" => ["text"]
      }
    },
    %{
      "name" => "lessons_decide",
      "description" =>
        "Decide a lesson a worker proposed (runs_show lists a dispatch's), or one of yours " <>
          "that waits because it is much like an approved lesson: `approve` (with `text` to " <>
          "reword it), `reject` (with a `note`), or `replace` (approve it and retire the " <>
          "approved lesson `replaces`). Keep only what is durable, actionable, not already " <>
          "documented, and earned.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "code" => %{"type" => "string"},
          "decision" => %{"type" => "string", "enum" => ["approve", "reject", "replace"]},
          "text" => %{"type" => "string", "description" => "approve or replace: rewording"},
          "note" => %{"type" => "string", "description" => "reject: why"},
          "replaces" => %{"type" => "string", "description" => "replace: the older code"}
        },
        "required" => ["code", "decision"]
      }
    }
  ]

  @strings ~w(purpose agent worker title brief effort reviewer of after batch request_id)
  @lists ~w(files stay_out accept gates tests lessons units)
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
      # What its worker proposed is read here and when it settles, never on a
      # screen's refresh.
      _ = Shoestring.Lessons.Harvest.dispatch(dispatch)
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

  def call("lessons_search", args, binding) do
    with :ok <- typed(args, ~w(query), &is_binary/1, "a string") do
      case Shoestring.Grants.active(binding.session_id) do
        nil ->
          {:error, "This session has no grant."}

        grant ->
          {:ok,
           Enum.map(Shoestring.Lessons.search(grant.repository_root, args["query"]), fn lesson ->
             %{"code" => lesson.code, "text" => lesson.text, "cited" => lesson.cite_count}
           end)}
      end
    end
  end

  def call("lessons_propose", args, binding) do
    with :ok <- typed(args, ~w(text why dispatch quote), &is_binary/1, "a string") do
      proposer = %{session_id: binding.session_id, role: "coordinator"}

      case Shoestring.Lessons.propose(args, proposer) do
        {:ok, lesson} ->
          {:ok,
           %{
             "code" => lesson.code,
             "state" => lesson.state,
             "text" => lesson.text,
             "similar_to" => lesson.similar_to,
             "next" =>
               if(lesson.state == "approved",
                 do: "Approved; cite it in a dispatch's `lessons`.",
                 else:
                   "Much like #{Enum.join(lesson.similar_to, ", ")}: decide it with " <>
                     "lessons_decide (approve, reject, or replace the older one)."
               )
           }}

        {:error, reason} ->
          {:error, Shoestring.CLI.Commands.Lessons.message(reason)}
      end
    end
  end

  def call("lessons_decide", args, binding) do
    with {:ok, code} <- required_string(args, "code"),
         {:ok, decision} <- required_string(args, "decision"),
         :ok <- typed(args, ~w(text note replaces), &is_binary/1, "a string"),
         %Shoestring.Grants.Grant{} = grant <-
           Shoestring.Grants.active(binding.session_id) || {:error, "This session has no grant."} do
      case Shoestring.Lessons.decide(
             code,
             decision,
             Shoestring.Authority.grant_identity(grant.id),
             text: args["text"],
             note: args["note"],
             replaces: args["replaces"]
           ) do
        {:ok, lesson} ->
          {:ok, %{"code" => lesson.code, "state" => lesson.state, "text" => lesson.text}}

        {:error, reason} ->
          {:error, Shoestring.CLI.Commands.Lessons.message(reason)}
      end
    end
  end

  def call("decisions_list", _args, binding),
    do: {:ok, Enum.map(session_decisions(binding), &decision_view/1)}

  def call("decisions_show", args, binding) do
    with {:ok, id} <- required_string(args, "decision") do
      case Enum.find(session_decisions(binding), &(&1.id == id)) do
        nil -> {:error, "No such decision in this session."}
        decision -> {:ok, decision_view(decision)}
      end
    end
  end

  def call(name, _args, _binding), do: {:error, "Unknown tool: #{name}"}

  # The decisions of the goals this session's dispatches run, newest first.
  defp session_decisions(binding) do
    case binding.session_id |> Dispatches.list() |> Enum.map(& &1.goal_id) |> Enum.uniq() do
      [] -> []
      goal_ids -> Shoestring.Decisions.list(goal_ids: goal_ids, limit: 50)
    end
  end

  defp decision_view(decision) do
    %{
      "decision_id" => decision.id,
      "goal_id" => decision.goal_id,
      "task" => decision.plan_task_id,
      "question" => decision.question,
      "note" => decision.note,
      "options" => Enum.map(decision.options, &Map.take(&1, ~w(key label media_type))),
      "allow_reject" => decision.allow_reject,
      "state" => decision.state,
      "answer" => decision.answer_key,
      "answer_note" => decision.answer_note,
      "decided_by" => decision.decided_by,
      "page_url" => Shoestring.CLI.Commands.Decision.page_url(decision),
      "who_answers" =>
        "the person: on the web goal page, the chat screen, or shoestring decision answer"
    }
  end

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
    with :ok <- required(args, ~w(purpose title brief)),
         :ok <- agent_or_worker(args),
         :ok <- typed(args, @strings, &is_binary/1, "a string"),
         :ok <- typed(args, @lists, &string_list?/1, "a list of strings"),
         :ok <- typed(args, @integers, &(is_integer(&1) and &1 > 0), "a positive integer"),
         :ok <-
           typed(
             args,
             ["tasks"],
             &(is_list(&1) and Enum.all?(&1, fn t -> is_map(t) end)),
             "a list of tasks"
           ) do
      fields =
        for key <- @strings ++ @lists ++ @integers, Map.has_key?(args, key), into: %{} do
          {String.to_existing_atom(key), args[key]}
        end

      fields =
        case args["tasks"] do
          nil -> fields
          tasks -> Map.put(fields, :tasks, tasks)
        end

      {:ok, Map.merge(fields, %{session_id: binding.session_id, repository: binding.repository})}
    end
  end

  defp agent_or_worker(%{"purpose" => "external"}), do: :ok

  defp agent_or_worker(args) do
    if is_binary(args["agent"]) or is_binary(args["worker"]),
      do: :ok,
      else: {:error, "dispatch needs `agent` or `worker`"}
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
