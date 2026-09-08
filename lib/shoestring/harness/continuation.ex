defmodule Shoestring.Harness.Continuation do
  @moduledoc """
  Pure continuation projection and resume/handoff validation for quota-aware runs.

  This module is deliberately separate from `Shoestring.Harness.RunRequest`
  (which stays closed/small: `checkpoint_id`/`next_action`/`decision_refs`
  only) and from `Shoestring.Harness.Projector` (which is
  persistence-coupled). It reads checkpoints **only** through
  `Shoestring.Harness.CheckpointRecord` with its own bounded queries, so it
  never depends on the concurrent checkpoint-writer slice.

  ## Bounds (module attributes, exposed for tests)

  - history: at most `@max_history` (50) checkpoint rows are considered;
    ordering is `projection_sequence` DESC, `id` ASC (deterministic
    tie-break); empty history returns `{:error, :no_checkpoint}`;
  - `next_action` is truncated to `@max_next_action_chars` (2000) characters
    with `@truncation_marker` appended when truncation occurs;
  - `decision_refs` keeps at most `@max_decision_refs` (32) latest entries.

  ## Decision references

  `decision_refs` come **only** from `admission.decided` event payloads
  (`decision_id`), correlated by goal, latest 32. Checkpoint bodies carry
  free-text `decisions` which are NEVER treated as ids: when no decided
  events exist, the refs are `[]`.

  ## Resume validation order (fail-fast)

  `validate_resume/3` checks, in order: checkpoint match, decision
  freshness, confirmation state, lease allowlist, session binding.

  - stale checkpoint refuses with `:stale_continuation` (the caller
    re-projects; no fallback);
  - superseded refs refuse with `:decision_superseded` (fresh admission is
    required; no fallback to checkpoint free text);
  - confirmation pending refuses with `:confirmation_pending`;
  - a lease status outside the explicit resumable allowlist refuses with
    `:lease_not_resumable` (no auto-renew; unknown future statuses are
    not resumable);
  - same-run resume with a different session refuses with
    `:session_mismatch` unless the adapter declares migration;
  - resume is strictly same-run: a checkpoint from another run refuses with
    `:cross_run_resume` (handoff targets a NEW RUN of the SAME goal;
    cross-goal handoff is out of scope).

  A missing lease row (`:no_lease`) constrains nothing: the allowlist
  governs known lease statuses, and runs without a lease predate lease
  enforcement.
  """

  import Ecto.Query

  alias Shoestring.Harness.{CheckpointRecord, Contract}
  alias Shoestring.Trajectory.TrajectoryEvent

  @max_history 50
  @max_next_action_chars 2_000
  @truncation_marker "…[truncated]"
  @max_decision_refs 32

  @resumable_lease_statuses ~w(granted active renewed)

  @allowed_continuation_keys ~w(checkpoint_id next_action decision_refs)

  @forbidden_keys ~w(
    transcript raw_transcript raw_output stdout stderr messages
    model_response prompt
  )a

  @type continuation :: %{
          checkpoint_id: Ecto.UUID.t(),
          next_action: String.t(),
          decision_refs: [Ecto.UUID.t()]
        }

  @doc "Maximum number of checkpoint rows considered by projection."
  @spec max_history() :: 50
  def max_history, do: @max_history

  @doc "Maximum `next_action` characters before truncation with a marker."
  @spec max_next_action_chars() :: 2_000
  def max_next_action_chars, do: @max_next_action_chars

  @doc "Marker appended when `next_action` is truncated."
  @spec truncation_marker() :: String.t()
  def truncation_marker, do: @truncation_marker

  @doc "Maximum number of latest decision refs carried."
  @spec max_decision_refs() :: 32
  def max_decision_refs, do: @max_decision_refs

  @doc "Lease statuses that allow a same-run resume (read-only allowlist)."
  @spec resumable_lease_statuses() :: [String.t()]
  def resumable_lease_statuses, do: @resumable_lease_statuses

  @doc "Keys that must never appear in continuation attrs or handoff payloads."
  @spec forbidden_keys() :: [atom()]
  def forbidden_keys, do: @forbidden_keys

  @doc """
  Projects the latest checkpoint from a history list plus decision refs.

  Sorts by `projection_sequence` DESC, `id` ASC (deterministic tie-break),
  considers at most `max_history/0` rows, truncates `next_action`, and keeps
  the latest `max_decision_refs/0` refs. Accepts `CheckpointRecord` structs
  or plain maps with atom/string keys. Empty history returns
  `{:error, :no_checkpoint}`.
  """
  @spec project_latest([CheckpointRecord.t() | map()], [String.t()]) ::
          {:ok, continuation()} | {:error, :no_checkpoint}
  def project_latest(checkpoints, decision_refs) when is_list(checkpoints) do
    case checkpoints |> Enum.sort(&latest_first/2) |> Enum.take(@max_history) do
      [] ->
        {:error, :no_checkpoint}

      [latest | _rest] ->
        {:ok,
         %{
           checkpoint_id: checkpoint_field(latest, :id),
           next_action: truncate_next_action(checkpoint_field(latest, :next_action)),
           decision_refs: latest_refs(decision_refs)
         }}
    end
  end

  @doc """
  Thin bounded reader: run-scoped checkpoint query with goal fallback,
  composed with goal-correlated `admission.decided` refs.

  Options: `:repo` (default `Shoestring.Repo`), `:run_id` (run scoping),
  `:allow_goal_fallback` (default `true`).
  """
  @spec for_goal(Ecto.UUID.t(), keyword()) :: {:ok, continuation()} | {:error, term()}
  def for_goal(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Shoestring.Repo)

    with {:ok, record} <- latest_checkpoint(repo, goal_id, opts) do
      refs = decision_refs(repo, goal_id)
      project_latest([record], refs)
    end
  end

  @doc """
  Returns the latest checkpoint record for a goal: run-scoped when
  `:run_id` is given, with goal fallback unless
  `:allow_goal_fallback` is `false`.
  """
  @spec latest_checkpoint(module(), Ecto.UUID.t(), keyword()) ::
          {:ok, CheckpointRecord.t()} | {:error, :no_checkpoint}
  def latest_checkpoint(repo, goal_id, opts \\ []) do
    run_id = Keyword.get(opts, :run_id)
    allow_fallback = Keyword.get(opts, :allow_goal_fallback, true)

    scoped =
      if run_id do
        repo.all(
          from checkpoint in CheckpointRecord,
            where: checkpoint.goal_id == ^goal_id and checkpoint.run_id == ^run_id,
            order_by: [desc: checkpoint.projection_sequence, asc: checkpoint.id],
            limit: ^@max_history
        )
      else
        []
      end

    records =
      if scoped == [] and (is_nil(run_id) or allow_fallback) do
        repo.all(
          from checkpoint in CheckpointRecord,
            where: checkpoint.goal_id == ^goal_id,
            order_by: [desc: checkpoint.projection_sequence, asc: checkpoint.id],
            limit: ^@max_history
        )
      else
        scoped
      end

    case records do
      [] -> {:error, :no_checkpoint}
      [latest | _rest] -> {:ok, latest}
    end
  end

  @doc """
  Returns goal-correlated decision ids from `admission.decided` payloads,
  latest 32 in chronological order. Checkpoint free-text decisions are
  never ids: no decided events means `[]`.
  """
  @spec decision_refs(module(), Ecto.UUID.t()) :: [String.t()]
  def decision_refs(repo, goal_id) do
    repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == "admission.decided",
        order_by: [desc: event.sequence],
        limit: ^@max_decision_refs,
        select: event.payload
    )
    |> Enum.map(&payload_decision_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
  end

  @doc """
  Key guard for continuation attrs: rejects every forbidden key and every
  key outside `checkpoint_id`/`next_action`/`decision_refs`.

  Shape validation stays with `RunRequest.new/1` (closed struct); this is
  the fail-fast privacy boundary used before any adapter call.
  """
  @spec validate_attrs(map()) :: :ok | {:error, term()}
  def validate_attrs(attrs) when is_map(attrs) do
    keys = attrs |> Map.keys() |> Enum.map(&to_string/1)
    forbidden = Enum.map(@forbidden_keys, &Atom.to_string/1)

    cond do
      Enum.any?(keys, fn key -> key in forbidden end) ->
        {:error, {:forbidden_continuation_key, Enum.find(keys, &forbidden_key?/1)}}

      Enum.any?(keys, fn key -> key not in @allowed_continuation_keys end) ->
        {:error, {:unsupported_continuation_field, Enum.find(keys, &unsupported_key?/1)}}

      true ->
        :ok
    end
  end

  def validate_attrs(_attrs), do: {:error, {:invalid_continuation, :must_be_a_map}}

  @doc """
  Fail-fast resume validation: checkpoint match, decision freshness,
  confirmation state, lease allowlist, then session binding.

  `presented` and `fresh` are maps with `:checkpoint_id`,
  `:decision_refs`, `:run_id`, and `:provider_session_id` (atom or string
  keys). `context` carries `:mode` (`:resume` or `:handoff`), `:lease_status`
  (`nil`/`:no_lease` constrains nothing), `:confirmation_pending`
  (boolean), and `:adapter_migrates_session` (boolean).
  """
  @spec validate_resume(map(), map(), map()) :: :ok | {:error, atom() | tuple()}
  def validate_resume(presented, fresh, context \\ %{}) do
    mode = Map.get(context, :mode, :resume) |> normalize_mode()
    presented = normalize_binding(presented)
    fresh = normalize_binding(fresh)

    with :ok <- match_checkpoint(presented, fresh, mode),
         :ok <- match_decisions(presented, fresh),
         :ok <- check_confirmation(context),
         :ok <- check_lease(context),
         :ok <- check_session(presented, fresh, mode, context) do
      :ok
    end
  end

  @doc """
  Builds a `handoff.created` v1 payload (string keys) or refuses with a
  validation error. Never carries transcript-scale content: forbidden keys
  and secret-bearing terms are rejected before the registry boundary.
  """
  @spec handoff_payload(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t() | term()}
  def handoff_payload(params) when is_map(params) do
    with :ok <- reject_forbidden_payload_keys(params),
         {:ok, handoff_id} <- fetch_uuid(params, :handoff_id),
         {:ok, run_id} <- fetch_uuid(params, :run_id),
         {:ok, checkpoint_id} <- fetch_uuid(params, :checkpoint_id),
         {:ok, from_provider_id} <-
           fetch_text(params, :from_provider_id, max: 200),
         {:ok, to_provider_id} <- fetch_text(params, :to_provider_id, max: 200),
         {:ok, _version} <- fetch_contract_version(params),
         {:ok, next_action} <- fetch_text(params, :next_action, max: @max_next_action_chars),
         {:ok, decision_refs} <- fetch_decision_refs(params),
         {:ok, reason} <- fetch_text(params, :reason, max: 500),
         {:ok, extensions} <- fetch_extensions(params),
         {:ok, prior_run_id} <- fetch_optional_uuid(params, :prior_run_id),
         {:ok, lease_grant_id} <- fetch_optional_uuid(params, :lease_grant_id),
         :ok <- ensure_safe_term(params) do
      {:ok,
       %{
         "handoff_id" => handoff_id,
         "run_id" => run_id,
         "checkpoint_id" => checkpoint_id,
         "from_provider_id" => from_provider_id,
         "to_provider_id" => to_provider_id,
         "contract_version" => 1,
         "next_action" => next_action,
         "decision_refs" => decision_refs,
         "reason" => reason,
         "extensions" => extensions
       }
       |> maybe_put("prior_run_id", prior_run_id)
       |> maybe_put("lease_grant_id", lease_grant_id)}
    end
  end

  def handoff_payload(_params), do: {:error, {:invalid_handoff, :must_be_a_map}}

  # -- Pure projection helpers --

  defp latest_first(a, b) do
    seq_a = checkpoint_field(a, :projection_sequence)
    seq_b = checkpoint_field(b, :projection_sequence)

    if seq_a != seq_b do
      seq_a > seq_b
    else
      checkpoint_field(a, :id) <= checkpoint_field(b, :id)
    end
  end

  defp checkpoint_field(%CheckpointRecord{} = record, field), do: Map.fetch!(record, field)

  defp checkpoint_field(record, field) when is_map(record) do
    Map.get(record, field, Map.get(record, Atom.to_string(field)))
  end

  defp truncate_next_action(action) when is_binary(action) do
    if String.length(action) > @max_next_action_chars do
      String.slice(action, 0, @max_next_action_chars) <> @truncation_marker
    else
      action
    end
  end

  defp truncate_next_action(_action), do: ""

  defp latest_refs(refs) when is_list(refs) do
    refs |> Enum.filter(&is_binary/1) |> Enum.take(-@max_decision_refs)
  end

  defp latest_refs(_refs), do: []

  defp payload_decision_id(%{"decision_id" => decision_id}) when is_binary(decision_id),
    do: decision_id

  defp payload_decision_id(%{decision_id: decision_id}) when is_binary(decision_id),
    do: decision_id

  defp payload_decision_id(_payload), do: nil

  # -- Key guards --

  defp forbidden_key?(key), do: key in Enum.map(@forbidden_keys, &Atom.to_string/1)
  defp unsupported_key?(key), do: key not in @allowed_continuation_keys

  # -- Resume validation steps --

  defp normalize_mode(:handoff), do: :handoff
  defp normalize_mode("handoff"), do: :handoff
  defp normalize_mode(_mode), do: :resume

  defp normalize_binding(binding) when is_map(binding) do
    %{
      checkpoint_id: binding[:checkpoint_id] || binding["checkpoint_id"],
      decision_refs: binding[:decision_refs] || binding["decision_refs"] || [],
      run_id: binding[:run_id] || binding["run_id"],
      provider_session_id: binding[:provider_session_id] || binding["provider_session_id"]
    }
  end

  defp match_checkpoint(presented, fresh, :resume) do
    cond do
      is_nil(presented.checkpoint_id) or is_nil(fresh.checkpoint_id) ->
        {:error, :stale_continuation}

      presented.checkpoint_id != fresh.checkpoint_id ->
        {:error, :stale_continuation}

      presented.run_id != fresh.run_id ->
        {:error, :cross_run_resume}

      true ->
        :ok
    end
  end

  defp match_checkpoint(presented, fresh, :handoff) do
    cond do
      is_nil(presented.checkpoint_id) or is_nil(fresh.checkpoint_id) ->
        {:error, :stale_continuation}

      presented.checkpoint_id != fresh.checkpoint_id ->
        {:error, :stale_continuation}

      presented.run_id != fresh.run_id ->
        {:error, :stale_continuation}

      true ->
        :ok
    end
  end

  defp match_decisions(presented, fresh) do
    if MapSet.equal?(MapSet.new(presented.decision_refs), MapSet.new(fresh.decision_refs)) do
      :ok
    else
      {:error, :decision_superseded}
    end
  end

  defp check_confirmation(context) do
    if Map.get(context, :confirmation_pending, false) do
      {:error, :confirmation_pending}
    else
      :ok
    end
  end

  defp check_lease(context) do
    case Map.get(context, :lease_status, :no_lease) do
      status when status in [nil, :no_lease] ->
        :ok

      status when is_binary(status) ->
        if status in @resumable_lease_statuses do
          :ok
        else
          {:error, :lease_not_resumable}
        end

      _other ->
        {:error, :lease_not_resumable}
    end
  end

  defp check_session(presented, fresh, :resume, context) do
    cond do
      presented.provider_session_id == fresh.provider_session_id ->
        :ok

      Map.get(context, :adapter_migrates_session, false) ->
        :ok

      true ->
        {:error, :session_mismatch}
    end
  end

  defp check_session(_presented, _fresh, :handoff, _context), do: :ok

  # -- Handoff payload field validation --

  defp reject_forbidden_payload_keys(params) do
    keys = Map.keys(params) |> Enum.map(&to_string/1)

    case Enum.find(keys, &forbidden_key?/1) do
      nil -> :ok
      key -> {:error, {:forbidden_handoff_key, key}}
    end
  end

  defp ensure_safe_term(params) do
    if Contract.safe_term?(params) do
      :ok
    else
      {:error, {:forbidden_handoff_content, :must_be_secret_free}}
    end
  end

  defp fetch_uuid(params, field) do
    case Contract.fetch(params, field) do
      {:ok, value} -> Contract.uuid(value, field)
      :error -> Contract.invalid(field, "can't be blank")
    end
  end

  defp fetch_optional_uuid(params, field) do
    case Contract.fetch(params, field) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> Contract.uuid(value, field)
      :error -> {:ok, nil}
    end
  end

  defp fetch_text(params, field, opts) do
    case Contract.fetch(params, field) do
      {:ok, value} -> Contract.text(value, field, opts)
      :error -> Contract.invalid(field, "can't be blank")
    end
  end

  defp fetch_contract_version(params) do
    case Contract.fetch(params, :contract_version) do
      {:ok, 1} -> {:ok, 1}
      {:ok, _other} -> Contract.invalid(:contract_version, "must equal 1")
      :error -> Contract.invalid(:contract_version, "can't be blank")
    end
  end

  defp fetch_decision_refs(params) do
    case Contract.fetch(params, :decision_refs) do
      {:ok, value} -> validate_decision_refs(value)
      :error -> Contract.invalid(:decision_refs, "can't be blank")
    end
  end

  defp validate_decision_refs(value) when is_list(value) do
    if length(value) <= @max_decision_refs do
      Enum.reduce_while(value, {:ok, []}, fn ref, {:ok, acc} ->
        case Contract.uuid(ref, :decision_refs) do
          {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, refs} -> {:ok, Enum.reverse(refs)}
        error -> error
      end
    else
      Contract.invalid(:decision_refs, "contains too many entries")
    end
  end

  defp validate_decision_refs(_value), do: Contract.invalid(:decision_refs, "must be a list")

  defp fetch_extensions(params) do
    case Contract.fetch(params, :extensions) do
      {:ok, value} -> Contract.extensions(value)
      :error -> {:ok, %{}}
    end
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)
end
