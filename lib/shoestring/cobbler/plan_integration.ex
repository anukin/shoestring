defmodule Shoestring.Cobbler.PlanIntegration do
  @moduledoc """
  Human-controlled integration of accepted plan work.

  Shoestring never merges. A human combines the retained accepted branches in
  their own repository, for example by fetching each private branch and
  merging it. They then record the resulting commit. Recording only reads the
  source repository. The commit must exist there, descend from the approved
  base, and contain every accepted commit as an ancestor; a cherry-pick does
  not qualify. While that commit covers every accepted result, remaining
  dependent work continues sequentially from it, and global verification runs
  in a private store at it. The approved repository contract is unchanged.
  """

  import Ecto.Query

  alias Shoestring.Cobbler.{GateProcess, PlanExecutor, Plans, ReservationWriter}
  alias Shoestring.{Repo, Trajectory}
  alias Shoestring.Trajectory.TrajectoryEvent

  @type_name "cobbler.plan.integration.recorded"
  @human ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/
  @commit ~r/\A[0-9a-f]{40,64}\z/

  def record(goal_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- Ecto.UUID.cast(goal_id),
         {:ok, command} <- command(attrs) do
      ReservationWriter.run(repo, fn ->
        repo.transaction(
          fn ->
            case existing(repo, goal_id, command.id) do
              nil ->
                case append(repo, goal_id, command, opts) do
                  {:ok, event} -> event
                  {:error, reason} -> repo.rollback(reason)
                end

              event ->
                if same?(event.payload, command),
                  do: event,
                  else: repo.rollback(:integration_conflict)
            end
          end,
          mode: :immediate
        )
      end)
    else
      :error -> {:error, :invalid_integration}
      {:error, _} = error -> error
    end
  end

  defp command(attrs) do
    with {:ok, id} <- Ecto.UUID.cast(attrs[:command_id]),
         {:ok, execution_id} <- Ecto.UUID.cast(attrs[:execution_id]),
         commit when is_binary(commit) <- attrs[:commit],
         true <- Regex.match?(@commit, commit),
         by when is_binary(by) <- attrs[:requested_by],
         true <- Regex.match?(@human, by),
         reason when is_binary(reason) <- attrs[:reason],
         reason = String.trim(reason),
         true <- reason != "" and String.length(reason) <= 2000 do
      {:ok, %{id: id, execution_id: execution_id, commit: commit, by: by, reason: reason}}
    else
      _ -> {:error, :invalid_integration}
    end
  end

  defp append(repo, goal_id, command, opts) do
    with {:ok, status} <- PlanExecutor.status(goal_id, repo: repo),
         %{execution: execution, completed?: false, cancelled?: false} <- status,
         true <- execution.execution_id == command.execution_id,
         %{revision: revision} <- Plans.authority(goal_id, repo: repo),
         true <- revision.digest == execution.plan_digest,
         accepted =
           status.accepted_evidence |> Enum.map(& &1.commit) |> Enum.uniq() |> Enum.sort(),
         true <- accepted != [] and length(accepted) <= 64,
         source when is_binary(source) <-
           execution[:repository_path] || Keyword.get(opts, :repository_path),
         base = get_in(revision.content, ["goal", "repository", "base_revision"]),
         :ok <- verify(source, command.commit, [base | accepted]) do
      Trajectory.append(
        goal_id,
        %{
          "type" => @type_name,
          "schema_version" => 1,
          "actor" => "human",
          "occurred_at" => DateTime.utc_now(),
          "idempotency_key" => key(command.id),
          "payload" => %{
            "integration_id" => command.id,
            "execution_id" => execution.execution_id,
            "revision_number" => execution.revision_number,
            "plan_digest" => execution.plan_digest,
            "commit" => command.commit,
            "accepted_commits" => accepted,
            "recorded_by" => command.by,
            "reason" => command.reason
          }
        },
        writer_opts: [transaction_repo: repo]
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :integration_mismatch}
    end
  end

  # Read-only Git observations of the user's repository.
  defp verify(source, commit, ancestors) do
    with {:ok, %{exit_status: 0, output: type}} <-
           GateProcess.run(["git", "cat-file", "-t", commit], source, 15_000, 64),
         true <- String.trim(type) == "commit",
         true <- Enum.all?(ancestors, &ancestor?(source, &1, commit)) do
      :ok
    else
      _ -> {:error, :integration_commit_not_verified}
    end
  end

  defp ancestor?(source, ancestor, commit) do
    match?(
      {:ok, %{exit_status: 0}},
      GateProcess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, commit],
        source,
        15_000,
        1024
      )
    )
  end

  defp existing(repo, goal_id, id) do
    repo.one(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.idempotency_key == ^key(id)
    )
  end

  defp same?(payload, command) do
    payload["execution_id"] == command.execution_id and payload["commit"] == command.commit and
      payload["recorded_by"] == command.by and payload["reason"] == command.reason
  end

  defp key(id), do: "plan-integration:#{id}"
end
