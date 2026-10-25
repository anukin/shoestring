defmodule Shoestring.CLI.WorkLoop do
  @moduledoc """
  The `shoestring do` loop up to queued execution: repository intake, goal,
  a planner-drafted plan, terminal review and approval, then an execution
  request for the running service. Every step goes through the same domain
  APIs as the step-by-step commands; nothing here starts an Elf.

  Locked decisions (iteration 7A):

  - Nothing runs until the human answers `y` to the exact plan shown. `n`
    leaves the goal and the draft recorded and stops.
  - The goal contract (base `HEAD`, gates) comes from `Shoestring.Cobbler.Intake`;
    the planner never chooses gates.
  - A planning call whose capacity cannot be admitted automatically is made
    only after the human confirms that one call.
  - Work is queued only when the running service reports the same database
    (`Shoestring.Health.instance/0`).

  Terminal I/O goes through `:shell` (default `Shoestring.CLI.Shell`). All of
  it is conversation, so it goes to stderr (`error/1`); the command prints the
  data. Tests drive it with `Mix.Shell.Process`.
  """

  alias Shoestring.{AgentProfiles, Harnesses, Repo}

  alias Shoestring.Cobbler.{
    ExecutionControl,
    ExecutionProfile,
    Intake,
    PlanContract,
    Planner,
    Plans
  }

  alias Shoestring.Trajectory.Goal

  @request_key "initial"
  @worker_role "Worker"
  @claude_planner [max_output_tokens: 8192, timeout_ms: 240_000]

  @type result ::
          {:ok, %{goal_id: Ecto.UUID.t(), revision: pos_integer(), execution_id: String.t()}}
          | {:declined, Ecto.UUID.t()}
          | {:error, term()}

  @doc """
  Runs the loop for `request`. Options: `:repo` (default the current
  directory), `:agent` (saved agent name; default the saved default), `:gates`,
  `:tests`, `:constraints`, `:by` (`human:NAME`), and for tests `:shell`,
  `:service`, `:planner_config`, `:planner_opts`, `:oban`, `:edit_dir` and `:edit`.
  """
  @spec run(String.t(), keyword()) :: result()
  def run(request, opts \\ []) do
    shell = Keyword.get(opts, :shell, Shoestring.CLI.Shell)
    by = Keyword.get_lazy(opts, :by, &default_human/0)

    with {:ok, facts} <- Intake.repository(Keyword.get(opts, :repo, File.cwd!())),
         {:ok, gates} <-
           Intake.gates(facts,
             gates: Keyword.get(opts, :gates, []),
             tests: Keyword.get(opts, :tests, [])
           ),
         {:ok, contract} <-
           Intake.goal_contract(request, facts, gates,
             constraints: Keyword.get(opts, :constraints, [])
           ),
         {:ok, binding, coordinator} <- agent(opts[:agent]),
         {:ok, planner_config} <- planner_config(opts, coordinator),
         :ok <- service(opts),
         {:ok, goal} <- create_goal(request) do
      shell.error("Goal #{goal.id}")
      shell.error("Base #{short(facts.head)} in #{facts.root}; gates: #{describe_gates(gates)}")

      planner_opts =
        Keyword.merge(
          [config: planner_config, publish_fun: fn _ -> :ok end],
          opts[:planner_opts] || []
        )

      context = %{
        goal: goal,
        by: by,
        shell: shell,
        planner_opts: planner_opts,
        edit_dir: Keyword.get(opts, :edit_dir, System.tmp_dir!()),
        edit: Keyword.get(opts, :edit, &prompt_edit(shell, &1))
      }

      with {:ok, row} <- plan(context, contract, Intake.repository_map(facts)),
           {:ok, %{revision: revision}} <-
             Planner.adopt(
               goal.id,
               @request_key,
               %{digest: row.result_digest, authored_by: by},
               planner_opts
             ),
           {:ok, approved} <- review(context, revision) do
        start(context, approved, facts.root, binding, opts)
      else
        {:declined, _} = declined -> declined
        error -> error
      end
    end
  end

  # -- Agent and planner ---------------------------------------------------

  defp agent(name) do
    snapshot = if name, do: AgentProfiles.snapshot(name), else: AgentProfiles.default_snapshot()

    with {:ok, snapshot} <- snapshot,
         binding = %{
           "profile_id" => snapshot["profile_id"],
           "revision" => snapshot["revision"],
           "digest" => snapshot["digest"],
           "role" => @worker_role
         },
         {:ok, _} <- worker(binding) do
      {:ok, binding, hd(snapshot["configuration"]["roles"])}
    else
      {:error, :no_default} -> {:error, :no_default_agent}
      {:error, :not_found} -> {:error, :agent_not_found}
      error -> error
    end
  end

  defp worker(binding) do
    case ExecutionProfile.resolve(binding, Repo) do
      {:ok, _} -> {:ok, binding}
      {:error, :explicit_execution_model_required} -> {:error, :worker_model_required}
      {:error, _} -> {:error, :worker_role_required}
    end
  end

  # An explicitly configured planner wins; otherwise the agent's Coordinator
  # plans when its harness can (only Claude has a planner) and it names an
  # explicit model.
  defp planner_config(opts, coordinator) do
    configured = Application.get_env(:shoestring, :planner, [])

    cond do
      opts[:planner_config] ->
        {:ok, opts[:planner_config]}

      Keyword.get(configured, :adapter, :disabled) != :disabled ->
        {:ok, configured}

      not Harnesses.supports?(coordinator["provider"], :plan) ->
        {:error, {:coordinator_cannot_plan, coordinator["provider"]}}

      coordinator["model"] != "default" ->
        {:ok, [adapter: :claude, model: coordinator["model"]] ++ @claude_planner}

      true ->
        {:error, :planner_not_configured}
    end
  end

  # -- Service -------------------------------------------------------------

  defp service(opts) do
    case Keyword.get(opts, :service, &check_service/0) do
      fun when is_function(fun, 0) -> fun.()
      :skip -> :ok
    end
  end

  @doc false
  # `req_options` is only a hermetic `Req.Test` seam for tests.
  def check_service(url \\ health_url(), req_options \\ []) do
    options =
      [retry: false, receive_timeout: 3_000, connect_options: [timeout: 2_000]] ++ req_options

    # The CLI starts only the repository; Req's HTTP pool is not running yet.
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, options) do
      {:ok, %{status: 200, body: %{"instance" => instance}}} ->
        if instance == Shoestring.Health.instance(),
          do: :ok,
          else: {:error, :service_uses_another_database}

      {:ok, %{status: 200}} ->
        {:error, :service_too_old}

      {:ok, %{status: status}} ->
        {:error, {:service_not_ready, status}}

      {:error, _} ->
        {:error, :service_unreachable}
    end
  end

  defp health_url do
    http = Application.get_env(:shoestring, ShoestringWeb.Endpoint, [])[:http] || []
    "http://127.0.0.1:#{Keyword.get(http, :port, 4000)}/health"
  end

  # -- Goal and planning ---------------------------------------------------

  defp create_goal(request) do
    request = String.trim(request)

    title =
      if String.length(request) > 80, do: String.slice(request, 0, 77) <> "...", else: request

    %Goal{}
    |> Goal.create_changeset(Ecto.UUID.generate(), %{title: title, description: request})
    |> Repo.insert()
  end

  defp plan(context, contract, map) do
    attrs = %{
      request_key: @request_key,
      requested_by: context.by,
      goal_contract: contract,
      repository_map: map
    }

    with {:ok, _} <- Planner.request(context.goal.id, attrs, context.planner_opts) do
      context.shell.error("Drafting a plan...")
      generate(context, :generate, false)
    end
  end

  defp generate(context, mode, confirmed?) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    opts =
      context.planner_opts ++
        [task_supervisor: supervisor, confirm_unknown_capacity: confirmed?]

    result =
      try do
        case mode do
          :generate -> Planner.generate(context.goal.id, @request_key, opts)
          :repair -> Planner.repair(context.goal.id, @request_key, opts)
        end
      after
        Supervisor.stop(supervisor)
      end

    case result do
      {:ok, %{request: row}} -> planned(context, row, mode, confirmed?)
      error -> error
    end
  end

  defp planned(_context, %{state: "ready"} = row, _mode, _confirmed?), do: {:ok, row}

  defp planned(context, %{state: "blocked"} = row, mode, false) do
    context.shell.error("Planning is held: #{messages(row)}")

    if yes?(
         context,
         "Make this one planning call anyway? Its usage is charged before the call. [y/N] "
       ),
       do: generate(context, mode, true),
       else: {:error, :planning_not_confirmed}
  end

  defp planned(context, %{state: state} = row, :generate, confirmed?)
       when state in ["schema_failed", "unsafe_proposal"] do
    context.shell.error("The draft was refused: #{messages(row)}")

    if yes?(context, "Ask the planner to repair it once? This is its last call. [y/N] "),
      do: generate(context, :repair, confirmed?),
      else: {:error, :plan_refused}
  end

  defp planned(_context, row, _mode, _confirmed?),
    do: {:error, {:planning_failed, row.state, messages(row)}}

  # -- Review --------------------------------------------------------------

  defp review(context, revision) do
    show(context.shell, revision)

    case answer(context, "Approve this plan? [y]es / [n]o / [e]dit: ") do
      "y" -> approve(context, revision)
      "n" -> {:declined, context.goal.id}
      "e" -> edit(context, revision)
      _ -> review(context, revision)
    end
  end

  defp approve(context, revision) do
    case Plans.approve(context.goal.id, %{
           revision_number: revision.revision_number,
           digest: revision.digest,
           decision_id: "do-approve-#{revision.revision_number}",
           decided_by: context.by
         }) do
      {:ok, %{revision: approved}} -> {:ok, approved}
      error -> error
    end
  end

  defp edit(context, revision) do
    path =
      Path.join(
        context.edit_dir,
        "shoestring-plan-#{context.goal.id}-r#{revision.revision_number}.json"
      )

    File.write!(path, Jason.encode!(revision.content, pretty: true))

    if context.edit.(path) == :keep do
      review(context, revision)
    else
      with {:ok, json} <- File.read(path),
           {:ok, content} <- Jason.decode(json),
           {:ok, contract} <- PlanContract.new(content),
           {:ok, %{revision: edited}} <-
             Plans.propose(context.goal.id, %{
               plan: contract.content,
               proposal_id:
                 "do-edit-#{revision.revision_number}-#{System.unique_integer([:positive])}",
               authored_by: context.by,
               parent_revision_number: revision.revision_number
             }) do
        review(context, edited)
      else
        error ->
          context.shell.error("The edit was not accepted: #{inspect(error, limit: 8)}")
          review(context, revision)
      end
    end
  end

  defp show(shell, revision) do
    {:ok, contract} = PlanContract.new(revision.content)
    tasks = Map.new(contract.content["tasks"], &{&1["id"], &1})
    goal = contract.content["goal"]
    budget = contract.content["budget"]

    shell.error("")
    shell.error("Plan revision #{revision.revision_number} (#{short(revision.digest)})")
    shell.error("  Goal: #{goal["statement"]}")
    shell.error("  Checks at the end: #{describe_gates(goal["acceptance"]["gates"])}")

    contract.ordered_task_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {id, number} ->
      task = tasks[id]
      shell.error("  #{number}. #{id}: #{task["title"]}")
      shell.error("     Outcome: #{task["outcome"]}")

      if task["depends_on"] != [],
        do: shell.error("     After: #{Enum.join(task["depends_on"], ", ")}")

      files = get_in(task, ["hints", "files"]) || []
      if files != [], do: shell.error("     Files: #{Enum.join(files, ", ")}")
      shell.error("     Checks: #{describe_gates(task["gates"])}")
    end)

    shell.error(
      "  Budget: #{budget["max_total_attempts"]} attempts, " <>
        "#{div(budget["max_total_duration_seconds"], 60)} minutes"
    )

    shell.error("")
  end

  # The human edits the exported file in their own editor, then submits it.
  defp prompt_edit(shell, path) do
    shell.error("Edit #{path} and save it.")

    case "Press Enter to submit the edit, or q to keep the plan as shown: "
         |> shell.prompt()
         |> String.trim()
         |> String.downcase() do
      "q" -> :keep
      _ -> :submit
    end
  end

  # -- Execution -----------------------------------------------------------

  defp start(context, revision, root, binding, opts) do
    attrs = %{
      revision_number: revision.revision_number,
      digest: revision.digest,
      repository_path: root,
      requested_by: context.by,
      agent_profile: binding
    }

    result =
      case opts[:oban] do
        nil ->
          Shoestring.CLI.Jobs.with_client(
            &ExecutionControl.start(context.goal.id, attrs, oban: &1)
          )

        client ->
          ExecutionControl.start(context.goal.id, attrs, oban: client)
      end

    case result do
      {:ok, %{execution: execution}} ->
        context.shell.error(
          "Approved. Execution #{execution.execution_id} is queued for the service."
        )

        {:ok,
         %{
           goal_id: context.goal.id,
           revision: revision.revision_number,
           execution_id: execution.execution_id
         }}

      error ->
        error
    end
  end

  # -- Helpers -------------------------------------------------------------

  defp answer(context, question),
    do: question |> context.shell.prompt() |> to_string() |> String.trim() |> String.downcase()

  defp yes?(context, question), do: answer(context, question) in ["y", "yes"]

  defp messages(row) do
    row.errors["items"]
    |> Enum.map_join("; ", &(&1["message"] || &1["code"]))
  end

  defp describe_gates(gates) do
    Enum.map_join(gates, "; ", fn gate ->
      Enum.join([gate["gate"] | Map.get(gate, "test_paths", [])], " ")
    end)
  end

  defp short(sha), do: String.slice(sha, 0, 12)

  @doc "`human:$USER` when it is a valid identity, otherwise `human:operator`."
  def default_human do
    user = System.get_env("USER", "operator")

    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/, user),
      do: "human:" <> user,
      else: "human:operator"
  end
end
