defmodule Mix.Tasks.Shoestring.Plans do
  use Mix.Task

  alias Shoestring.Cobbler.{PlanContract, Planner, Plans}
  alias Shoestring.Trajectory.Goal

  @shortdoc "Inspect, edit and decide immutable goal plan revisions without dispatch"
  @moduledoc """
  Repository-only plan review. See docs/cli-plan-review.md for the full workflow.

      mix shoestring.plans list GOAL
      mix shoestring.plans show GOAL [--revision N]
      mix shoestring.plans export GOAL --revision N
      mix shoestring.plans planner GOAL
      mix shoestring.plans propose GOAL --file plan.json --request-id ID --by human:NAME
      mix shoestring.plans edit GOAL --revision N --digest DIGEST --file plan.json --request-id ID --by human:NAME
      mix shoestring.plans adopt GOAL --request-key KEY --digest DIGEST --by human:NAME
      mix shoestring.plans approve GOAL --revision N --digest DIGEST --request-id ID --by human:NAME [--note TEXT]
      mix shoestring.plans reject GOAL --revision N --digest DIGEST --request-id ID --by human:NAME --reason TEXT

  `show` returns the latest revision if omitted. Decisions never infer a revision
  or digest. `export` returns only the editable plan JSON. `edit` creates a new
  proposal with an explicit parent; it does not approve, cancel or continue work.
  `planner` shows stored budget charges, support tier and validation errors; it
  never calls a model. `adopt` authors an exact reviewed planner candidate and
  leaves it unapproved. No command here dispatches work.
  """

  @switches [
    revision: :integer,
    digest: :string,
    file: :string,
    request_id: :string,
    request_key: :string,
    by: :string,
    note: :string,
    reason: :string
  ]
  @options %{
    "list" => {[], []},
    "show" => {[], [:revision]},
    "export" => {[:revision], []},
    "planner" => {[], []},
    "propose" => {[:file, :request_id, :by], []},
    "edit" => {[:revision, :digest, :file, :request_id, :by], []},
    "adopt" => {[:request_key, :digest, :by], []},
    "approve" => {[:revision, :digest, :request_id, :by], [:note]},
    "reject" => {[:revision, :digest, :request_id, :by, :reason], []}
  }

  @impl true
  def run(args) do
    switches = Enum.map(@switches, fn {key, type} -> {key, [type, :keep]} end)
    {opts, positional, invalid} = OptionParser.parse(args, strict: switches)

    with [command, goal_id] <- positional,
         {required, optional} <- Map.get(@options, command),
         true <- invalid == [] and valid_options?(opts, required, optional),
         {:ok, goal_id} <- Ecto.UUID.cast(goal_id) do
      Shoestring.CLI.Repository.with_repo(fn repo ->
        if is_nil(repo.get(Goal, goal_id)), do: Mix.raise("Goal not found")
        execute(command, goal_id, opts)
      end)
    else
      _ -> Mix.raise("Invalid arguments. See mix help shoestring.plans")
    end
  end

  defp valid_options?(opts, required, optional) do
    keys = Keyword.keys(opts)

    Enum.uniq(keys) == keys and Enum.all?(keys, &(&1 in (required ++ optional))) and
      Enum.all?(required, &Keyword.has_key?(opts, &1)) and
      (is_nil(opts[:revision]) or opts[:revision] > 0) and
      Enum.all?(opts, fn
        {:revision, _} -> true
        {_key, value} -> String.trim(value) != ""
      end)
  end

  defp execute("list", goal_id, _opts) do
    output(%{
      goal_id: goal_id,
      revisions: Enum.map(Plans.list_revisions(goal_id), &revision_summary/1)
    })
  end

  defp execute("show", goal_id, opts) do
    revision =
      if opts[:revision],
        do: fetch_revision!(goal_id, opts[:revision]),
        else: List.last(Plans.list_revisions(goal_id)) || Mix.raise("Plan revision not found")

    contract = verified_contract!(revision)
    tasks = Map.new(contract.content["tasks"], &{&1["id"], &1})

    decision =
      Plans.list_decisions(goal_id)
      |> Enum.find(&(&1.revision_number == revision.revision_number))

    output(%{
      goal_id: goal_id,
      revision: revision_summary(revision),
      plan: contract.content,
      ordered_tasks: Enum.map(contract.ordered_task_ids, &Map.fetch!(tasks, &1)),
      required_task_ids: PlanContract.required_task_ids(contract),
      retirements: PlanContract.retirements(contract),
      decision: decision_summary(decision),
      planner: planner_summary(goal_id)
    })
  end

  defp execute("export", goal_id, opts) do
    goal_id
    |> fetch_revision!(opts[:revision])
    |> verified_contract!()
    |> Map.fetch!(:content)
    |> output()
  end

  defp execute("planner", goal_id, _opts), do: output(planner_summary(goal_id))

  defp execute(command, goal_id, opts) when command in ["propose", "edit"] do
    if command == "edit" do
      parent = fetch_revision!(goal_id, opts[:revision])
      verified_contract!(parent)
      if parent.digest != opts[:digest], do: Mix.raise("Parent plan digest mismatch; reread it")
    end

    contract = read_plan!(opts[:file])

    Plans.propose(
      goal_id,
      %{
        plan: contract.content,
        proposal_id: opts[:request_id],
        authored_by: opts[:by],
        parent_revision_number: if(command == "edit", do: opts[:revision])
      },
      domain_options()
    )
    |> output_result!()
  end

  defp execute("adopt", goal_id, opts) do
    Planner.adopt(
      goal_id,
      opts[:request_key],
      %{digest: opts[:digest], authored_by: opts[:by]},
      domain_options()
    )
    |> output_result!()
  end

  defp execute(command, goal_id, opts) when command in ["approve", "reject"] do
    # Check the stored content as well as the caller-supplied digest. Domain
    # mutation remains atomic and checks the exact binding again in its transaction.
    goal_id |> fetch_revision!(opts[:revision]) |> verified_contract!()

    attrs = %{
      revision_number: opts[:revision],
      digest: opts[:digest],
      decision_id: opts[:request_id],
      decided_by: opts[:by],
      note: opts[:note],
      reason: opts[:reason]
    }

    result =
      case command do
        "approve" -> Plans.approve(goal_id, attrs, domain_options())
        "reject" -> Plans.reject(goal_id, attrs, domain_options())
      end

    output_result!(result)
  end

  defp fetch_revision!(goal_id, number),
    do: Plans.get_revision(goal_id, number) || Mix.raise("Plan revision not found")

  defp verified_contract!(revision) do
    case PlanContract.new(revision.content) do
      {:ok, %{digest: digest} = contract} when digest == revision.digest -> contract
      _ -> Mix.raise("Stored plan content/digest is inconsistent; no decision recorded")
    end
  end

  defp read_plan!(path) do
    result =
      File.open(path, [:read, :binary], fn file ->
        IO.binread(file, PlanContract.max_plan_bytes() + 1)
      end)

    case result do
      {:ok, json} when is_binary(json) ->
        case PlanContract.from_canonical_json(json) do
          {:ok, contract} ->
            contract

          {:error, {:malformed_plan_json, _}} ->
            Mix.raise("Malformed plan JSON; expected an object")

          {:error, reason} ->
            refuse!(reason)
        end

      {:ok, :eof} ->
        Mix.raise("Plan file is empty")

      _ ->
        Mix.raise("Unable to read plan file")
    end
  end

  defp revision_summary(revision) do
    Map.take(revision, [
      :revision_number,
      :parent_revision_number,
      :status,
      :digest,
      :authored_by,
      :task_count
    ])
  end

  defp decision_summary(nil), do: nil

  defp decision_summary(decision),
    do: Map.take(decision, [:decision_id, :kind, :bound_digest, :decided_by, :reason, :note])

  defp planner_summary(goal_id) do
    case Planner.get(goal_id) do
      nil ->
        %{state: "not_requested", support_tier: "unknown", charged_output_tokens: 0}

      row ->
        config = row.configuration

        %{
          state: row.state,
          request_key: row.request_key,
          model: config["model"],
          provider: config["provider_id"],
          support_tier: config["support_tier"],
          attempts: row.attempts,
          max_attempts: config["max_attempts"],
          charged_output_tokens: row.charged_output_tokens,
          max_charged_output_tokens: config["max_charged_output_tokens"],
          remaining_output_allowance:
            max(0, config["max_charged_output_tokens"] - row.charged_output_tokens),
          next_attempt_output_allowance: config["max_output_tokens"],
          attempt_history: row.attempt_history["items"],
          errors: row.errors["items"],
          candidate_digest: row.result_digest,
          candidate: candidate_content!(row),
          quota_note:
            "Stored planning budget; not a live provider allowance. Full output allowance is charged before a call."
        }
    end
  end

  defp candidate_content!(%{state: "ready"} = row) do
    with {:ok, %{consistent?: true}} <- Planner.rebuild(row.goal_id),
         {:ok, contract} <- PlanContract.from_canonical_json(row.result_json),
         true <- contract.digest == row.result_digest do
      contract.content
    else
      _ -> Mix.raise("Stored planner candidate is inconsistent")
    end
  end

  defp candidate_content!(_), do: nil

  defp domain_options, do: [publish_fun: fn _event -> :ok end]
  defp output(value), do: Mix.shell().info(Jason.encode!(value, pretty: true))

  defp output_result!({:ok, result}) do
    output(%{
      outcome: result.outcome,
      revision: revision_summary(result.revision),
      decision: decision_summary(Map.get(result, :decision))
    })
  end

  defp output_result!({:error, reason}), do: refuse!(reason)

  defp refuse!(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          placeholder = "%{#{key}}"

          if String.contains?(acc, placeholder),
            do: String.replace(acc, placeholder, to_string(value)),
            else: acc
        end)
      end)

    Mix.raise("Plan validation failed: #{Jason.encode!(errors)}")
  end

  defp refuse!({kind, %Ecto.Changeset{} = changeset}) when is_atom(kind), do: refuse!(changeset)

  defp refuse!(reason),
    do: Mix.raise("Plan request refused: #{inspect(reason, limit: 30, printable_limit: 1000)}")
end
