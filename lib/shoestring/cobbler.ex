defmodule Shoestring.Cobbler do
  @moduledoc """
  Cobbler: Quota-aware admission evaluation, deterministic reserve policies,
  and durable admission decision persistence.

  In Milestone 05 (quota-aware MVP foundation), Cobbler evaluates admission
  requests deterministically against capacity observations, candidate capabilities,
  explicit occupancy evidence, and operator confirmations, persisting durable
  `admission.decided` trajectory events without activating automatic dispatch.
  """

  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionEvaluation, AdmissionPolicy}
  alias Shoestring.Harness.CapacitySnapshot

  @doc """
  Evaluates admission for a single candidate provider deterministically.

  Requires explicit `:now` DateTime in `opts`.
  """
  @spec evaluate_admission(
          map(),
          map(),
          CapacitySnapshot.t() | map() | nil,
          AdmissionPolicy.t() | nil,
          keyword()
        ) :: {:ok, AdmissionDecision.t()} | {:error, term()}
  def evaluate_admission(request, candidate, snapshot, policy \\ nil, opts \\ []) do
    AdmissionEvaluation.evaluate(request, candidate, snapshot, policy, opts)
  end

  @doc """
  Evaluates admission across multiple candidate providers in deterministic priority order.
  """
  @spec evaluate_candidates(
          map(),
          [map()],
          map(),
          AdmissionPolicy.t() | nil,
          keyword()
        ) ::
          {:ok, %{selected: AdmissionDecision.t(), all: [AdmissionDecision.t()]}}
          | {:error, term()}
  def evaluate_candidates(request, candidates, snapshots_map, policy \\ nil, opts \\ []) do
    AdmissionEvaluation.evaluate_candidates(request, candidates, snapshots_map, policy, opts)
  end

  @doc "Returns the default admission policy."
  @spec default_policy() :: AdmissionPolicy.t()
  def default_policy, do: AdmissionPolicy.default()

  alias Shoestring.Cobbler.{Claim, Commands, Intent, StateReplay}
  alias Shoestring.Repo
  import Ecto.Query

  @doc """
  Executes a durable command within a goal.
  """
  @spec execute_command(Ecto.UUID.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_command(goal_id, command_params, opts \\ []) do
    Commands.execute(goal_id, command_params, opts)
  end

  @doc """
  Submits an inert task intent to Cobbler with caller-supplied command ID.
  """
  @spec submit_intent(Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def submit_intent(goal_id, command_id, payload, opts \\ []) do
    command = %{
      command_id: command_id,
      command_type: "submit_intent",
      payload: payload
    }

    Commands.execute(goal_id, command, opts)
  end

  @doc """
  Exclusively claims an inert pending intent for execution in SQLite.
  """
  @spec claim_intent(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def claim_intent(goal_id, command_id, intent_id, opts \\ []) do
    command = %{
      command_id: command_id,
      command_type: "claim",
      payload: %{"intent_id" => intent_id}
    }

    Commands.execute(goal_id, command, opts)
  end

  @doc """
  Transitions an active intent to recoverable :needs_user state.
  """
  @spec request_user(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request_user(goal_id, command_id, intent_id, reason, opts \\ []) do
    command = %{
      command_id: command_id,
      command_type: "needs_user",
      payload: %{"intent_id" => intent_id, "reason" => reason}
    }

    Commands.execute(goal_id, command, opts)
  end

  @doc """
  Recovers an intent from :needs_user back to :active state.
  """
  @spec resume_intent(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resume_intent(goal_id, command_id, intent_id, opts \\ []) do
    command = %{
      command_id: command_id,
      command_type: "resume",
      payload: %{"intent_id" => intent_id}
    }

    Commands.execute(goal_id, command, opts)
  end

  @doc """
  Terminally completes an active intent and releases its exclusive claim.
  """
  @spec complete_intent(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete_intent(goal_id, command_id, intent_id, reason \\ nil, opts \\ []) do
    command = %{
      command_id: command_id,
      command_type: "complete",
      payload: %{"intent_id" => intent_id, "reason" => reason || "Intent completed"}
    }

    Commands.execute(goal_id, command, opts)
  end

  @doc """
  Terminally fails an intent and releases any active claim.
  """
  @spec fail_intent(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fail_intent(goal_id, command_id, intent_id, reason, opts \\ []) do
    command = %{
      command_id: command_id,
      command_type: "fail",
      payload: %{"intent_id" => intent_id, "reason" => reason}
    }

    Commands.execute(goal_id, command, opts)
  end

  @doc """
  Terminally cancels an intent and releases any active claim.
  """
  @spec cancel_intent(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def cancel_intent(goal_id, command_id, intent_id, reason \\ nil, opts \\ []) do
    command = %{
      command_id: command_id,
      command_type: "cancel",
      payload: %{"intent_id" => intent_id, "reason" => reason || "Intent cancelled"}
    }

    Commands.execute(goal_id, command, opts)
  end

  @doc """
  Retrieves an intent by ID.
  """
  @spec get_intent(Ecto.UUID.t(), keyword()) :: Intent.t() | nil
  def get_intent(intent_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.get(Intent, intent_id)
  end

  @doc """
  Lists all intents for a goal.
  """
  @spec list_intents(Ecto.UUID.t(), keyword()) :: [Intent.t()]
  def list_intents(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.all(from i in Intent, where: i.goal_id == ^goal_id, order_by: [asc: i.inserted_at])
  end

  @doc """
  Retrieves the current globally active exclusive claim, if one exists.
  """
  @spec get_active_claim(keyword()) :: Claim.t() | nil
  def get_active_claim(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.one(from c in Claim, where: c.status == "active", limit: 1)
  end

  @doc """
  Replays a goal's canonical trajectory into in-memory Cobbler state.
  """
  @spec replay_state(Ecto.UUID.t(), keyword()) ::
          {:ok, %{intents: %{String.t() => map()}, active_claim: map() | nil}}
          | {:error, term()}
  def replay_state(goal_id, opts \\ []) do
    StateReplay.replay(goal_id, opts)
  end
end
