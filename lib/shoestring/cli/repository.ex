defmodule Shoestring.CLI.Repository do
  @moduledoc """
  Repository-only CLI startup; no application workers or provider monitors.
  Domain writes also need the per-goal trajectory writers and PubSub, so a
  runtime without the application gets its own (see `with_domain_processes/1`).
  """

  def with_repo(fun) do
    Shoestring.State.ensure_writable_root!()
    start_repo(fun, true)
  end

  @doc "Open existing state for inspection without creating the state root or running migrations."
  def with_existing_repo(fun) do
    if File.regular?(Shoestring.State.database_path()),
      do: start_repo(fun, false),
      else: {:error, :existing_database_required}
  end

  @doc """
  Open existing state only when its schema is exactly this code's, without
  creating or migrating anything: the installed command never changes a
  database the service owns. Returns `{:ok, result}`, or `{:error, reason}`
  with `:database_missing`, `:database_needs_init` (migrations pending) or
  `:database_newer` (migrations this code does not know).
  """
  def with_current_repo(fun) do
    if File.regular?(Shoestring.State.database_path()) do
      start_repo(
        fn repo ->
          migrations =
            Ecto.Migrator.migrations(
              repo,
              Application.app_dir(:shoestring, "priv/repo/migrations")
            )

          with :current <- schema_state(migrations), do: {:ok, fun.(repo)}
        end,
        false
      )
    else
      {:error, :database_missing}
    end
  end

  @doc false
  # `Ecto.Migrator.migrations/2` rows: a version the database has but this
  # code does not is reported with this placeholder name.
  def schema_state(migrations) do
    cond do
      Enum.any?(migrations, fn {_, _, name} -> name == "** FILE NOT FOUND **" end) ->
        {:error, :database_newer}

      Enum.any?(migrations, fn {status, _, _} -> status == :down end) ->
        {:error, :database_needs_init}

      true ->
        :current
    end
  end

  defp start_repo(fun, migrate?) do
    Shoestring.State.configure_repo!()
    previous = Application.fetch_env!(:shoestring, Shoestring.Repo)

    Application.put_env(
      :shoestring,
      Shoestring.Repo,
      previous |> Keyword.put(:log, false) |> Keyword.put(:pool, DBConnection.ConnectionPool)
    )

    try do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(
          Shoestring.Repo,
          fn repo ->
            if migrate?, do: Ecto.Migrator.run(repo, :up, all: true, log: false)
            with_domain_processes(fn -> fun.(repo) end)
          end,
          pool_size: 1
        )

      result
    after
      Application.put_env(:shoestring, Shoestring.Repo, previous)
    end
  end

  # Capacity confirmations, review decisions, cancellations and reservation
  # commands append through a per-goal trajectory writer, publish to PubSub
  # and queue writes through the local ReservationWriter. The service starts
  # all three; a short-lived CLI runtime did not, and those commands crashed
  # there. Correctness does not depend on them being the service's: each
  # append reads the next sequence inside an immediate transaction and retries
  # a conflict, and the ReservationWriter is only local FIFO delivery over
  # SQLite transactions. Broadcasts from here reach only this runtime.
  defp with_domain_processes(fun) do
    if Process.whereis(Shoestring.Trajectory.WriterSupervisor) do
      fun.()
    else
      {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

      {:ok, supervisor} =
        Supervisor.start_link(
          [
            Shoestring.Cobbler.ReservationWriter,
            {Phoenix.PubSub, name: Shoestring.PubSub},
            {Registry, keys: :unique, name: Shoestring.Trajectory.WriterRegistry},
            Shoestring.Trajectory.WriterSupervisor
          ],
          strategy: :one_for_one
        )

      try do
        fun.()
      after
        Supervisor.stop(supervisor)
      end
    end
  end
end
