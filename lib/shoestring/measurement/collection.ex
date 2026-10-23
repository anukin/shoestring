defmodule Shoestring.Measurement.Collection do
  @moduledoc """
  Operator-attested measurement collection windows.

  A window is a human statement that nothing outside Shoestring uses the
  provider account until the window closes. Only rows measured inside a
  window can become calibration examples. Windows are canonical events in
  the protected Observatory stream, beside the capacity readings they
  qualify, so the dataset derives them from history like everything else.

  Opening one is a human act. An agent must never open a window: it cannot
  know what else uses the account. Nothing here starts a provider or changes
  admission.
  """
  import Ecto.Query
  alias Shoestring.Harness.Observatory
  alias Shoestring.Measurement.Events
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @types ~w(measurement.collection.opened measurement.collection.closed)

  @attestation """
  I attest that, until I close this window, no device, session or person other
  than this Shoestring installation uses this provider account. I will close
  the window first if that stops being true.
  """

  def attestation, do: @attestation
  def event_types, do: @types

  @doc "Open a window for `provider` and `scope`, refusing while one is already open."
  def open(provider, scope, attested_by, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- valid(provider, scope, attested_by),
         {:ok, _goal} <- Observatory.ensure_provisioned(repo: repo) do
      transaction(repo, fn ->
        windows = windows(events(repo))

        if Enum.any?(windows, &(open?(&1) and &1.provider == provider and &1.scope == scope)) do
          repo.rollback(:collection_window_already_open)
        else
          window_id = Ecto.UUID.generate()
          # The ordinal makes two racing opens collide on one key.
          ordinal = Enum.count(windows, &(&1.provider == provider and &1.scope == scope))

          append(repo, "measurement.collection.opened", now,
            idempotency_key: "measurement-window-open:#{provider}:#{scope}:#{ordinal}",
            payload: %{
              "window_id" => window_id,
              "provider_id" => provider,
              "scope" => scope,
              "attestation_version" => 1,
              "attested_by" => attested_by,
              "opened_at" => DateTime.to_iso8601(now)
            }
          )
        end
      end)
    end
  end

  @doc "Close the open window for `provider` and `scope`."
  def close(provider, scope, reason, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- valid(provider, scope, "operator"),
         true <- reason in Events.close_reasons() || {:error, :invalid_close_reason} do
      transaction(repo, fn ->
        case Enum.find(
               windows(events(repo)),
               &(open?(&1) and &1.provider == provider and &1.scope == scope)
             ) do
          nil ->
            repo.rollback(:no_open_collection_window)

          window ->
            append(repo, "measurement.collection.closed", now,
              idempotency_key: "measurement-window-close:#{window.window_id}",
              payload: %{
                "window_id" => window.window_id,
                "provider_id" => provider,
                "scope" => scope,
                "reason" => reason,
                "closed_at" => DateTime.to_iso8601(now)
              }
            )
        end
      end)
    end
  end

  @doc "All windows, oldest first, from the current history."
  def list(opts \\ []), do: windows(events(Keyword.get(opts, :repo, Repo)))

  @doc "The window open for `provider` and `scope` at `time`, if any."
  def open_at(windows, provider, scope, %DateTime{} = time) do
    Enum.find(windows, fn window ->
      window.provider == provider and window.scope == scope and
        DateTime.compare(window.opened_at, time) != :gt and
        (is_nil(window.closed_at) or DateTime.compare(time, window.closed_at) == :lt)
    end)
  end

  @doc """
  Pure derivation of windows from canonical events. A close that names no
  earlier open window is ignored; each window closes at most once.
  """
  def windows(events) do
    events
    |> Enum.filter(&(&1.type in @types))
    |> Enum.sort_by(&{&1.goal_id, &1.sequence})
    |> Enum.reduce([], fn
      %{type: "measurement.collection.opened", payload: p} = event, acc ->
        acc ++
          [
            %{
              window_id: p["window_id"],
              provider: p["provider_id"],
              scope: p["scope"],
              attested_by: p["attested_by"],
              opened_at: datetime(p["opened_at"]),
              closed_at: nil,
              close_reason: nil,
              opened_event_id: event.id,
              closed_event_id: nil
            }
          ]

      %{type: "measurement.collection.closed", payload: p} = event, acc ->
        closing = p["window_id"]

        Enum.map(acc, fn
          %{window_id: ^closing, closed_at: nil} = window ->
            %{
              window
              | closed_at: datetime(p["closed_at"]),
                close_reason: p["reason"],
                closed_event_id: event.id
            }

          window ->
            window
        end)
    end)
  end

  def open?(window), do: is_nil(window.closed_at)

  defp events(repo) do
    goal_id = Observatory.observatory_goal_id()

    repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type in ^@types,
        order_by: e.sequence
    )
  end

  defp append(repo, type, now, opts) do
    case Trajectory.append(
           Observatory.observatory_goal_id(),
           %{
             "type" => type,
             "schema_version" => 1,
             "actor" => "operator",
             "occurred_at" => now,
             "idempotency_key" => Keyword.fetch!(opts, :idempotency_key),
             "payload" => Keyword.fetch!(opts, :payload)
           },
           writer_opts: [transaction_repo: repo]
         ) do
      {:ok, event} -> event
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp transaction(repo, fun) do
    case repo.transaction(fun, mode: :immediate) do
      {:ok, %TrajectoryEvent{} = event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid(provider, scope, attested_by) do
    if provider in Events.providers() and Events.label?(scope) and Events.label?(attested_by),
      do: :ok,
      else: {:error, :invalid_collection_window}
  end

  defp datetime(value) do
    case DateTime.from_iso8601(value || "") do
      {:ok, time, _} -> time
      _ -> nil
    end
  end
end
