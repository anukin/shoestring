defmodule Shoestring.Cobbler.Planner do
  @moduledoc """
  Initial plan generation through quota admission and an exclusive global claim.

  `request/3` stores one immutable, bounded projection per goal. `generate/3`
  admits and charges one attempt before tool-free inference. `repair/3` permits
  exactly one explicit repair after schema/unsafe output. Transport failures and
  ambiguous in-flight attempts are never retried automatically. A lost result
  remains `running` and its claim/budget remain owned; time alone cannot grant
  another call. A human can always use Plans.propose directly instead.

  A valid result is a durable candidate, not a revision or approval. `adopt/4`
  explicitly authors a revision through the human-only Plans API. There is no
  task dispatch, lease, worktree mutation or reserve override in this boundary.
  """
  import Ecto.Query

  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    Commands,
    PlanContract,
    PlannerRequestRecord,
    Plans
  }

  alias Shoestring.Cobbler.Planner.{Configuration, Output, Projection, Replay, Schema}
  alias Shoestring.Harness.{CapacitySnapshot, Observatory}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.Goal
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}

  def request(goal_id, attrs, opts \\ []) do
    with {:ok, goal_id} <- Ecto.UUID.cast(goal_id),
         {:ok, config} <- Configuration.load(opts),
         {:ok, key} <- request_key(attrs),
         {:ok, projection} <- Projection.build(Repo, goal_id, attrs),
         digest =
           PlanContract.digest(%{"projection" => projection, "configuration" => config.public}) do
      transaction(fn ->
        case get(goal_id) do
          nil ->
            if Plans.list_revisions(goal_id) != [],
              do: Repo.rollback(:initial_planning_already_has_revision)

            row =
              %PlannerRequestRecord{
                goal_id: goal_id,
                request_key: key,
                input_digest: digest,
                projection: projection,
                configuration: config.public
              }
              |> Ecto.Changeset.change()
              |> Ecto.Changeset.unique_constraint(:goal_id)
              |> insert!()

            append!(
              goal_id,
              "cobbler.planner.requested",
              %{
                "request_id" => row.id,
                "request_key" => key,
                "input_digest" => digest,
                "projection_json" => PlanContract.canonical_json(projection),
                "configuration" => config.public
              },
              opts
            )

            %{request: row, outcome: :recorded}

          %PlannerRequestRecord{request_key: ^key, input_digest: ^digest} = row ->
            %{request: row, outcome: :replayed}

          _ ->
            Repo.rollback(:planner_request_conflict)
        end
      end)
      |> converge_request(goal_id, key, digest)
    else
      :error -> {:error, :invalid_goal_id}
      error -> error
    end
  end

  def get(goal_id) do
    case Ecto.UUID.cast(goal_id) do
      {:ok, goal_id} -> Repo.get_by(PlannerRequestRecord, goal_id: goal_id)
      :error -> nil
    end
  end

  def rebuild(goal_id), do: Replay.rebuild(goal_id, get(goal_id))

  def generate(goal_id, key, opts \\ []), do: run(goal_id, key, :initial, opts)
  def repair(goal_id, key, opts \\ []), do: run(goal_id, key, :repair, opts)

  @doc "Authors a human revision from one exact reviewed candidate digest; never approves it."
  def adopt(goal_id, key, attrs, opts \\ []) do
    case get(goal_id) do
      %PlannerRequestRecord{request_key: ^key, state: "ready"} = row ->
        if attrs[:digest] == row.result_digest do
          with {:ok, %{consistent?: true}} <- rebuild(goal_id),
               {:ok, contract} <- PlanContract.from_canonical_json(row.result_json),
               true <- contract.digest == row.result_digest do
            Plans.propose(
              goal_id,
              %{
                proposal_id: "planner:#{row.id}",
                authored_by: attrs[:authored_by],
                plan: contract.content,
                parent_revision_number: attrs[:parent_revision_number]
              },
              opts
            )
          else
            _ -> {:error, :planner_result_corrupt}
          end
        else
          {:error, :stale_planner_digest}
        end

      _ ->
        {:error, :planner_result_not_ready}
    end
  end

  defp run(goal_id, key, mode, opts) do
    with {:ok, config} <- Configuration.load(opts),
         {:ok, reservation} <- reserve(goal_id, key, mode, config, opts) do
      case reservation do
        %{outcome: :started, request: row} -> infer(row, config, opts)
        result -> {:ok, result}
      end
    end
  end

  defp reserve(goal_id, key, mode, config, opts) do
    transaction(fn ->
      row = get(goal_id) || Repo.rollback(:planner_request_not_found)

      case Replay.rebuild(goal_id, row) do
        {:ok, %{consistent?: true}} -> :ok
        _ -> Repo.rollback(:planner_state_diverged)
      end

      if row.request_key != key, do: Repo.rollback(:planner_request_conflict)
      if row.configuration != config.public, do: Repo.rollback(:planner_configuration_changed)

      cond do
        row.state == "running" ->
          %{request: row, outcome: :replayed}

        mode == :initial and row.attempts > 0 ->
          %{request: row, outcome: :replayed}

        mode == :repair and
            (row.attempts != 1 or row.state not in ["schema_failed", "unsafe_proposal", "blocked"]) ->
          Repo.rollback(:planner_repair_unavailable)

        true ->
          admit!(row, config, opts)
      end
    end)
  end

  defp admit!(row, config, opts) do
    case Repo.get(Goal, row.goal_id) do
      %Goal{status: "active"} -> :ok
      _ -> Repo.rollback(:goal_not_active)
    end

    now = now(opts)
    candidate = Configuration.candidate(config.public)
    snapshot = snapshot(config.public, opts)
    override = confirmation(row, candidate, opts)

    {:ok, decision} =
      AdmissionEvaluation.evaluate(
        %{
          goal_id: row.goal_id,
          requested_capability: "read_only",
          scope: candidate.scope,
          override: override
        },
        candidate,
        snapshot,
        nil,
        now: now,
        occupancy: Commands.active_claim() != nil
      )

    admission =
      append!(row.goal_id, "admission.decided", AdmissionDecision.to_payload(decision), opts)

    if decision.result == :admit do
      number = row.attempts + 1
      limit = config.public["max_output_tokens"]

      attrs = %{
        state: "running",
        attempts: number,
        charged_output_tokens: row.charged_output_tokens + limit,
        attempt_history: %{
          "items" =>
            row.attempt_history["items"] ++
              [
                %{
                  "attempt" => number,
                  "status" => "running",
                  "output_token_allowance" => limit,
                  "admission_event_id" => admission.id
                }
              ]
        }
      }

      row = update_owned!(row, attrs)

      claim =
        unwrap!(
          Commands.submit(
            row.goal_id,
            %{
              command_id: claim_id(row),
              type: "task.claim",
              requested_by: row.projection["requested_by"],
              payload: %{
                intent: "read_only",
                scope: candidate.scope,
                candidate: %{provider_id: candidate.provider_id, adapter_id: candidate.adapter_id},
                admission_event_id: admission.id
              }
            },
            command_opts(opts)
          )
        )

      if claim.command.result["kind"] != "claimed", do: Repo.rollback(:planner_claim_not_acquired)

      append!(
        row.goal_id,
        "cobbler.planner.attempt.started",
        %{
          "request_id" => row.id,
          "attempt" => number,
          "admission_event_id" => admission.id,
          "output_token_allowance" => limit,
          "charged_output_tokens" => row.charged_output_tokens
        },
        opts
      )

      %{request: row, outcome: :started}
    else
      errors = [%{"code" => decision.reason_code, "message" => decision.explanation}]
      row = update_owned!(row, %{state: "blocked", errors: %{"items" => errors}})

      append!(
        row.goal_id,
        "cobbler.planner.blocked",
        %{
          "request_id" => row.id,
          "admission_event_id" => admission.id,
          "errors" => %{"items" => errors}
        },
        opts
      )

      %{request: row, outcome: :blocked}
    end
  end

  defp infer(row, config, opts) do
    input = %{
      "projection" => row.projection,
      "schema" => Schema.for_goal(row.projection["goal_contract"]),
      "model" => config.public["model"],
      "attempt" => row.attempts,
      "max_output_tokens" => config.public["max_output_tokens"],
      "timeout_ms" => config.public["timeout_ms"],
      "validation_errors" => repair_errors(row)
    }

    task =
      Task.Supervisor.async_nolink(
        Keyword.get(opts, :task_supervisor, Shoestring.Cobbler.PlannerTasks),
        fn ->
          config.adapter.generate(
            input,
            Keyword.put(config.adapter_opts, :endpoint, config.endpoint)
          )
        end
      )

    result =
      case Task.yield(task, config.public["timeout_ms"]) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} -> validate_result(value, row)
        {:exit, _} -> failed("transport_failed", "adapter_exit")
        nil -> failed("transport_failed", "transport_timeout")
      end

    finish(row, result, opts)
  end

  defp validate_result({:ok, %{json: json, output_tokens: tokens}}, row)
       when is_integer(tokens) and tokens >= 0 do
    if tokens <= row.configuration["max_output_tokens"] do
      case Output.validate(json, row.projection, row.configuration) do
        {:ok, contract} ->
          %{
            state: "ready",
            errors: [],
            result_json: PlanContract.canonical_json(contract),
            result_digest: contract.digest,
            output_tokens: tokens
          }

        {:error, {state, errors}} ->
          %{state: state, errors: errors, output_tokens: tokens}
      end
    else
      failed("budget_exceeded", "output_token_limit")
    end
  end

  defp validate_result({:error, code}, _row) when is_atom(code),
    do: failed("transport_failed", transport_code(code))

  defp validate_result(_, _row), do: failed("transport_failed", "invalid_adapter_result")

  defp transport_code(code) when code in [:quota_refused, :output_limit, :output_too_large],
    do: to_string(code)

  defp transport_code(_), do: "transport_error"

  defp failed(state, code),
    do: %{
      state: state,
      errors: [
        %{
          "code" => code,
          "message" =>
            "Inference ended without a usable plan. Use a manual plan; no automatic retry."
        }
      ]
    }

  defp finish(row, result, opts) do
    transaction(fn ->
      current = get(row.goal_id)

      if current.id != row.id or current.state != "running" or current.attempts != row.attempts,
        do: Repo.rollback(:planner_attempt_changed)

      history =
        current.attempt_history["items"]
        |> Enum.map(fn attempt ->
          if attempt["attempt"] == row.attempts,
            do:
              attempt
              |> Map.put("status", result.state)
              |> Map.put("errors", %{"items" => result.errors})
              |> Map.put("output_tokens", Map.get(result, :output_tokens)),
            else: attempt
        end)

      current =
        update_owned!(current, %{
          state: result.state,
          errors: %{"items" => result.errors},
          attempt_history: %{"items" => history},
          result_json: Map.get(result, :result_json),
          result_digest: Map.get(result, :result_digest)
        })

      payload = %{
        "request_id" => current.id,
        "attempt" => current.attempts,
        "state" => current.state,
        "errors" => current.errors,
        "output_tokens" => Map.get(result, :output_tokens)
      }

      payload =
        if current.state == "ready",
          do:
            Map.merge(payload, %{
              "plan_content" => current.result_json,
              "plan_digest" => current.result_digest
            }),
          else: payload

      append!(row.goal_id, "cobbler.planner.attempt.finished", payload, opts)

      case Commands.active_claim() do
        %{goal_id: goal_id, command_id: command_id} when goal_id == row.goal_id ->
          if command_id != claim_id(row), do: Repo.rollback(:planner_claim_changed)

          unwrap!(
            Commands.submit(
              row.goal_id,
              %{
                command_id: "planner-release:#{row.id}:#{row.attempts}",
                type: "task.release",
                requested_by: row.projection["requested_by"],
                payload: %{reason: "Planning attempt finished."}
              },
              command_opts(opts)
            )
          )

        nil ->
          :ok

        _ ->
          Repo.rollback(:planner_claim_changed)
      end

      %{request: current, outcome: :finished}
    end)
  end

  defp snapshot(public, opts) do
    case Keyword.fetch(opts, :snapshot) do
      {:ok, nil} ->
        nil

      {:ok, %CapacitySnapshot{} = snapshot} ->
        snapshot

      {:ok, _} ->
        Repo.rollback(:invalid_planner_snapshot)

      :error ->
        case Observatory.latest_observation(
               public["provider_id"],
               "structured-planning",
               public["scope"]
             ) do
          {:ok, snapshot} -> snapshot
          _ -> nil
        end
    end
  end

  defp confirmation(row, candidate, opts) do
    if Keyword.get(opts, :confirm_unknown_capacity, false) do
      %{
        confirmed_by: row.projection["requested_by"],
        target_provider_id: candidate.provider_id,
        target_scope: candidate.scope,
        intent: "read_only",
        confirmation_id: Ecto.UUID.generate()
      }
    end
  end

  defp update_owned!(row, attrs) do
    # Compare-and-set is effective even inside an enclosing sandbox SAVEPOINT.
    # Losing writers cannot start a second effect or overwrite its result.
    query =
      from r in PlannerRequestRecord,
        where:
          r.id == ^row.id and r.state == ^row.state and r.attempts == ^row.attempts and
            r.charged_output_tokens == ^row.charged_output_tokens

    case Repo.update_all(query, set: Map.to_list(attrs) ++ [updated_at: DateTime.utc_now()]) do
      {1, _} -> Repo.get!(PlannerRequestRecord, row.id)
      _ -> Repo.rollback(:planner_attempt_changed)
    end
  end

  defp request_key(attrs) when is_map(attrs) do
    key = attrs[:request_key]

    if is_binary(key) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,126}\z/, key),
      do: {:ok, key},
      else: {:error, :invalid_planner_request_key}
  end

  defp request_key(_), do: {:error, :invalid_planner_request}
  defp claim_id(row), do: "planner-claim:#{row.id}:#{row.attempts}"

  defp repair_errors(%{attempts: 2, attempt_history: history}),
    do: history["items"] |> hd() |> Map.get("errors", %{"items" => []}) |> Map.fetch!("items")

  defp repair_errors(_), do: []
  defp command_opts(opts), do: [now: now(opts), publish_fun: fn _ -> :ok end]

  defp now(opts),
    do: Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp insert!(changeset), do: changeset |> Repo.insert() |> unwrap!()

  # Event append shares the reservation transaction, as in Plans/Commands.
  defp append!(goal_id, type, payload, opts) do
    payload = unwrap!(EventRegistry.validate_payload(type, 1, payload, now: now(opts)))

    sequence =
      Repo.one(from e in TrajectoryEvent, where: e.goal_id == ^goal_id, select: max(e.sequence)) ||
        0

    %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal_id,
      sequence: sequence + 1,
      type: type,
      actor: "cobbler",
      occurred_at: now(opts),
      schema_version: 1,
      payload: payload
    }
    |> TrajectoryEvent.changeset(%{})
    |> insert!()
  end

  defp transaction(fun) do
    Repo.transaction(fun, mode: :immediate)
  rescue
    _ in [Exqlite.Error, DBConnection.ConnectionError] -> {:error, :planner_database_busy}
    _ in [Ecto.ConstraintError, Ecto.StaleEntryError] -> {:error, :planner_database_conflict}
  end

  defp converge_request({:error, _} = error, goal_id, key, digest) do
    case get(goal_id) do
      %PlannerRequestRecord{request_key: ^key, input_digest: ^digest} = row ->
        {:ok, %{request: row, outcome: :replayed}}

      _ ->
        error
    end
  end

  defp converge_request(result, _, _, _), do: result
end
