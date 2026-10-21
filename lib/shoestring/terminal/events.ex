defmodule Shoestring.Terminal.Events do
  @moduledoc "Canonical terminal lifecycle/ownership facts; no terminal bytes, prompts or provider prose."
  alias Shoestring.Harness.Contract

  @states ~w(agent_owned takeover_requested human_owned detached_human_owned release_requested interrupted)

  def validate("terminal.ownership.changed", payload) do
    if payload["state"] in @states and
         (payload["owner_ref"] == "none" or
            (is_binary(payload["owner_ref"]) and
               Regex.match?(~r/\A[0-9a-f]{64}\z/, payload["owner_ref"]))),
       do: :ok,
       else:
         Contract.invalid(:state, "must be a terminal ownership state and opaque owner reference")
  end

  def validate("terminal.session.started", payload) do
    if payload["protocol_version"] == 1 and is_integer(payload["process_group"]) and
         payload["process_group"] > 1,
       do: :ok,
       else:
         Contract.invalid(:protocol_version, "must describe a supported helper and process group")
  end

  def validate("terminal.session.exited", payload) do
    if payload["reason"] in ~w(exited child_failed helper_failed incompatible_helper protocol_error output_overflow artifact_failed cancelled application_restart),
      do: :ok,
      else: Contract.invalid(:reason, "must be a terminal outcome code")
  end

  def validate(_type, _payload), do: :ok

  def run_id(request) do
    case Shoestring.Repo.get_by(Shoestring.Harness.RunRecord,
           dispatch_id: request.dispatch_id,
           goal_id: request.goal_id,
           task_id: request.task_id,
           workspace_ref: request.workspace_ref
         ) do
      nil -> {:error, :terminal_run_not_owned}
      run -> {:ok, run.id}
    end
  end

  def append(request, type, payload, key \\ nil, actor \\ "system") do
    with {:ok, run_id} <- run_id(request) do
      Shoestring.Trajectory.append(
        request.goal_id,
        %{
          "type" => type,
          "schema_version" => 1,
          "actor" => actor,
          "idempotency_key" => key || "terminal:#{Ecto.UUID.generate()}",
          "payload" => Map.put(payload, "run_id", run_id)
        },
        trusted: [task_id: request.task_id, run_id: run_id]
      )
    end
  end
end
