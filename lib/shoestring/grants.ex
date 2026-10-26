defmodule Shoestring.Grants do
  @moduledoc """
  A person's allowance for one coordinator session (iteration 14 decision 5).

  A grant names one repository, the `provider:model`s and purposes the
  coordinator may dispatch, and its limits: attempts (every attempt counts,
  retries included), how many dispatches may run at once, total and
  per-dispatch duration, and how many dispatches whose remaining usage
  cannot be read it pre-approves (decision 7). Every limit is checked before
  a dispatch is recorded; nothing is estimated (decision 6).

  Only a `human:` identity creates, extends or revokes a grant, and the CLI
  does so only from a terminal. Revoking or exhausting a grant stops new
  dispatches; it never interrupts running work. Each change is appended to
  `coordinator_grant_events`.
  """
  import Ecto.Query

  alias Shoestring.{Authority, Harnesses, ModelCatalog, Repo}
  alias Shoestring.Grants.{Event, Grant}

  @purposes ~w(explore implement review)
  @purpose_capability %{"explore" => :implement, "implement" => :implement, "review" => :review}
  @session ~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/

  @limits [
    max_dispatches: 1..200,
    max_parallel: 1..16,
    max_total_seconds: 60..604_800,
    max_dispatch_seconds: 60..14_400,
    unread_usage: 0..100
  ]

  def purposes, do: @purposes

  @doc "A new session id for a grant made without one."
  def new_session_id,
    do: "session-" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Grant, id)
      :error -> nil
    end
  end

  def list, do: Repo.all(from g in Grant, order_by: [desc: g.inserted_at, desc: g.id])

  @doc "The session's newest grant that is not revoked, or nil."
  def active(session_id) do
    Repo.one(
      from g in Grant,
        where: g.session_id == ^session_id and is_nil(g.revoked_at),
        order_by: [desc: g.inserted_at, desc: g.id],
        limit: 1
    )
  end

  def events(grant_id),
    do: Repo.all(from e in Event, where: e.grant_id == ^grant_id, order_by: [e.occurred_at, e.id])

  @doc """
  Creates a grant. `attrs`: `:session_id`, `:repository_root` (canonical),
  `:models` (`["provider:model"]`), `:purposes`, and each limit in
  `#{inspect(Keyword.keys(@limits))}`.
  """
  def create(attrs, granted_by, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with :ok <- human(granted_by),
         {:ok, fields} <- validate(attrs) do
      Repo.transaction(fn ->
        grant = Repo.insert!(struct(Grant, Map.put(fields, :granted_by, granted_by)))
        record!(grant, "created", granted_by, snapshot(grant), now)
        grant
      end)
    end
  end

  @doc """
  Widens a grant: `:add_dispatches`, `:add_seconds`, `:add_unread_usage`,
  `:add_models`, `:add_purposes`, and `:max_parallel` to replace it.
  """
  def extend(%Grant{} = grant, changes, by, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    attrs = %{
      session_id: grant.session_id,
      repository_root: grant.repository_root,
      models: Enum.uniq(grant.models ++ Map.get(changes, :add_models, [])),
      purposes: Enum.uniq(grant.purposes ++ Map.get(changes, :add_purposes, [])),
      max_dispatches: grant.max_dispatches + Map.get(changes, :add_dispatches, 0),
      max_parallel: Map.get(changes, :max_parallel, grant.max_parallel),
      max_total_seconds: grant.max_total_seconds + Map.get(changes, :add_seconds, 0),
      max_dispatch_seconds: grant.max_dispatch_seconds,
      unread_usage: grant.unread_usage + Map.get(changes, :add_unread_usage, 0)
    }

    with :ok <- human(by),
         :ok <- if(grant.revoked_at, do: {:error, :grant_revoked}, else: :ok),
         {:ok, fields} <- validate(attrs) do
      Repo.transaction(fn ->
        grant =
          grant
          |> Ecto.Changeset.change(Map.put(fields, :limits_revision, grant.limits_revision + 1))
          |> Repo.update!()

        record!(grant, "extended", by, snapshot(grant), now)
        grant
      end)
    end
  end

  def revoke(%Grant{} = grant, by, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    cond do
      human(by) != :ok ->
        {:error, :non_human_identity}

      grant.revoked_at ->
        {:ok, grant}

      true ->
        Repo.transaction(fn ->
          grant =
            grant |> Ecto.Changeset.change(revoked_at: now, revoked_by: by) |> Repo.update!()

          record!(grant, "revoked", by, %{}, now)
          grant
        end)
    end
  end

  @doc """
  Uses one pre-approved unread-usage dispatch, atomically. `{:ok, grant}`, or
  `{:error, :unread_usage_exhausted}` when none is left (or the grant was
  revoked).
  """
  def use_unread(%Grant{id: id}, detail, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Repo.transaction(fn ->
      {count, _} =
        Repo.update_all(
          from(g in Grant,
            where: g.id == ^id and is_nil(g.revoked_at) and g.unread_usage_used < g.unread_usage
          ),
          inc: [unread_usage_used: 1]
        )

      if count != 1, do: Repo.rollback(:unread_usage_exhausted)
      grant = Repo.get!(Grant, id)
      record!(grant, "unread_usage_used", Authority.grant_identity(id), detail, now)
      grant
    end)
  end

  @doc """
  `:ok`, or `{:error, {:outside_grant, limit}}` naming the first limit the
  dispatch would cross. `request` has `:repository_root`, `:provider`,
  `:model`, `:purpose`, `:attempts` and `:seconds`; `usage` is what the
  grant's dispatches already reserve (`:attempts`, `:seconds`, `:running`).
  """
  def check(%Grant{} = grant, request, usage) do
    model = "#{request.provider}:#{request.model}"

    cond do
      grant.revoked_at ->
        {:error, {:outside_grant, :revoked}}

      request.repository_root != grant.repository_root ->
        {:error, {:outside_grant, :repository}}

      request.purpose not in grant.purposes ->
        {:error, {:outside_grant, :purpose}}

      model not in grant.models ->
        {:error, {:outside_grant, :model}}

      usage.attempts + request.attempts > grant.max_dispatches ->
        {:error, {:outside_grant, :dispatches}}

      usage.running + 1 > grant.max_parallel ->
        {:error, {:outside_grant, :parallel}}

      request.seconds > grant.max_dispatch_seconds ->
        {:error, {:outside_grant, :dispatch_duration}}

      usage.seconds + request.seconds > grant.max_total_seconds ->
        {:error, {:outside_grant, :total_duration}}

      true ->
        :ok
    end
  end

  defp validate(attrs) do
    with :ok <- session(attrs[:session_id]),
         :ok <- root(attrs[:repository_root]),
         :ok <- purposes(attrs[:purposes]),
         :ok <- models(attrs[:models], attrs[:purposes]),
         :ok <- limits(attrs) do
      fields =
        Map.take(attrs, [
          :session_id,
          :repository_root,
          :models,
          :purposes | Keyword.keys(@limits)
        ])

      if fields.max_parallel > fields.max_dispatches or
           fields.max_dispatch_seconds > fields.max_total_seconds,
         do: {:error, {:invalid_grant, :limits}},
         else: {:ok, fields}
    end
  end

  defp human(by), do: if(Authority.human?(by), do: :ok, else: {:error, :non_human_identity})

  defp session(id) when is_binary(id),
    do: if(Regex.match?(@session, id), do: :ok, else: {:error, {:invalid_grant, :session}})

  defp session(_id), do: {:error, {:invalid_grant, :session}}

  defp root(root) when is_binary(root) and root != "",
    do: if(Path.type(root) == :absolute, do: :ok, else: {:error, {:invalid_grant, :repository}})

  defp root(_root), do: {:error, {:invalid_grant, :repository}}

  defp purposes([_ | _] = purposes),
    do:
      if(Enum.all?(purposes, &(&1 in @purposes)),
        do: :ok,
        else: {:error, {:invalid_grant, :purposes}}
      )

  defp purposes(_purposes), do: {:error, {:invalid_grant, :purposes}}

  # Each model must be enabled, on a harness that can do at least one of the
  # granted purposes.
  defp models([_ | _] = models, purposes) do
    Enum.reduce_while(models, :ok, fn model, :ok ->
      with [provider, id] <- String.split(model, ":", parts: 2),
           true <- id in ModelCatalog.enabled(provider),
           true <- Enum.any?(purposes, &Harnesses.supports?(provider, @purpose_capability[&1])) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, {:invalid_grant, {:model, model}}}}
      end
    end)
  rescue
    ArgumentError -> {:error, {:invalid_grant, :models}}
  end

  defp models(_models, _purposes), do: {:error, {:invalid_grant, :models}}

  defp limits(attrs) do
    Enum.reduce_while(@limits, :ok, fn {key, range}, :ok ->
      if is_integer(attrs[key]) and attrs[key] in range,
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_grant, key}}}
    end)
  end

  defp snapshot(grant) do
    grant
    |> Map.take([
      :session_id,
      :repository_root,
      :models,
      :purposes,
      :limits_revision | Keyword.keys(@limits)
    ])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp record!(grant, kind, actor, payload, now) do
    Repo.insert!(%Event{
      grant_id: grant.id,
      kind: kind,
      actor: actor,
      payload: payload,
      occurred_at: now
    })
  end
end
