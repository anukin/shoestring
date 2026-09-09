defmodule Shoestring.Cobbler.TaskClaimRaceTest do
  @moduledoc """
  SQLite-enforced exclusivity for the global MVP task claim.

  Runs against a scratch SQLite database with the production migrations and
  real concurrent connections (no sandbox), proving there is no
  count-then-act window: concurrent claim writers serialize on immediate
  write transactions and the partial unique index rejects every second
  active claim row. Fully hermetic — no provider CLIs, no network.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.Commands
  alias Shoestring.Test.MigrationRepo

  import Shoestring.Test.CobblerHelpers

  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
    {20_260_907_234_724, Shoestring.Repo.Migrations.AddCobblerCommands},
    {20_260_909_035_800, Shoestring.Repo.Migrations.AddResponseAttributionToCobblerCommands}
  ]

  @now ~U[2026-09-07 12:00:00.000000Z]
  @iso_now DateTime.to_iso8601(@now)

  setup do
    state_dir =
      Path.join(System.tmp_dir!(), "shoestring-claim-race-#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(state_dir) end)

    start_supervised!(
      {MigrationRepo,
       [
         database: Path.join(state_dir, "claims.db"),
         pool_size: 8,
         journal_mode: :wal,
         busy_timeout: 2_000
       ]}
    )

    assert is_list(Ecto.Migrator.run(MigrationRepo, @migrations, :up, all: true))

    {:ok, %{repo: MigrationRepo}}
  end

  test "concurrent claim commands from competing goals produce exactly one winner", %{
    repo: repo
  } do
    goal_a = seed_goal!(repo, "00000000-0000-4000-8000-000000000001")
    goal_b = seed_goal!(repo, "00000000-0000-4000-8000-000000000002")

    event_a = seed_admission_event!(repo, goal_a, 1, "01950000-0000-7000-8000-00000000000a")
    event_b = seed_admission_event!(repo, goal_b, 1, "01950000-0000-7000-8000-00000000000b")

    results =
      [
        {goal_a, claim_command(event_a, command_id: "cmd-race-a")},
        {goal_b, claim_command(event_b, command_id: "cmd-race-b")}
      ]
      |> Task.async_stream(
        fn {goal, command} ->
          Commands.submit(goal.id, command,
            repo: repo,
            publish_fun: fn _event -> :ok end,
            now: @now
          )
        end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == 2

    resolved_count =
      Enum.count(results, fn
        {:ok, %{command: %{status: "resolved"}}} -> true
        _other -> false
      end)

    held_count =
      Enum.count(results, fn
        {:ok, %{command: %{status: "needs_user"}}} -> true
        _other -> false
      end)

    assert resolved_count == 1
    assert held_count == 1

    # Exactly one active claim row exists, owned by the winner.
    {:ok, %{rows: [[active_count]]}} =
      repo.query("SELECT count(*) FROM cobbler_task_claims WHERE status = 'active'", [])

    assert active_count == 1

    claim = Commands.active_claim(repo: repo)

    loser_goal = if claim.goal_id == goal_a.id, do: goal_b, else: goal_a
    loser_command_id = if claim.command_id == "cmd-race-a", do: "cmd-race-b", else: "cmd-race-a"

    # The losing command recorded the recoverable needs_user outcome that
    # names the winner's claim; it did not release or overwrite the claim.
    loser = Commands.get(loser_goal.id, loser_command_id, repo: repo)

    assert loser.status == "needs_user"
    assert loser.result["reason"] == "claim_held"
    assert loser.result["active_claim"]["claim_id"] == claim.id

    # Each goal appended exactly one accepted event; only the winner appended
    # a claim.acquired event.
    {:ok, %{rows: rows}} =
      repo.query(
        "SELECT type, count(*) FROM trajectory_events WHERE type LIKE 'cobbler.%' GROUP BY type",
        []
      )

    grouped = Map.new(rows, fn [type, count] -> {type, count} end)
    assert grouped["cobbler.command.accepted"] == 2
    assert grouped["cobbler.claim.acquired"] == 1
    refute Map.has_key?(grouped, "cobbler.claim.released")
  end

  test "the partial unique index rejects concurrent active claim inserts directly", %{repo: repo} do
    goal = seed_goal!(repo, "00000000-0000-4000-8000-000000000010")

    attempts =
      Task.async_stream(
        1..6,
        fn n -> attempt_active_claim_insert(repo, goal.id, "cmd-raw-race-#{n}") end,
        max_concurrency: 6,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    inserted_count = Enum.count(attempts, &(&1 == {:ok, :inserted}))
    rejected_count = Enum.count(attempts, &(&1 == {:error, :rejected}))

    assert inserted_count == 1
    assert rejected_count == 5

    {:ok, %{rows: [[active_count]]}} =
      repo.query("SELECT count(*) FROM cobbler_task_claims WHERE status = 'active'", [])

    assert active_count == 1

    {:ok, %{rows: [[total_count]]}} = repo.query("SELECT count(*) FROM cobbler_task_claims", [])

    assert total_count == 1
  end

  test "the exclusive slot frees only through an explicit release, then re-acquires", %{
    repo: repo
  } do
    goal = seed_goal!(repo, "00000000-0000-4000-8000-000000000020")
    event = seed_admission_event!(repo, goal, 1, "01950000-0000-7000-8000-000000000020")

    opts = [repo: repo, publish_fun: fn _event -> :ok end, now: @now]

    assert {:ok, %{command: %{status: "resolved"}}} =
             Commands.submit(goal.id, claim_command(event, command_id: "cmd-release-flow"), opts)

    claim = Commands.active_claim(repo: repo)
    assert claim != nil
    assert claim.goal_id == goal.id

    assert {:ok, %{command: %{status: "resolved"}}} =
             Commands.submit(
               goal.id,
               release_command("operator released", command_id: "cmd-release-flow-release"),
               opts
             )

    assert Commands.active_claim(repo: repo) == nil

    # The released claim row remains as durable history; a fresh goal may now
    # acquire the slot.
    {:ok, %{rows: [[released_count]]}} =
      repo.query("SELECT count(*) FROM cobbler_task_claims WHERE status = 'released'", [])

    assert released_count == 1

    other = seed_goal!(repo, "00000000-0000-4000-8000-000000000021")

    other_event =
      seed_admission_event!(repo, other, 1, "01950000-0000-7000-8000-000000000021")

    assert {:ok, %{command: %{status: "resolved"}}} =
             Commands.submit(
               other.id,
               claim_command(other_event, command_id: "cmd-reacquire"),
               opts
             )

    assert Commands.active_claim(repo: repo).goal_id == other.id
  end

  # ----------------------------------------------------------------------------
  # Seeding against the scratch database
  # ----------------------------------------------------------------------------

  defp seed_goal!(repo, id) do
    repo.query!(
      "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      [id, "00000000-0000-4000-8000-0000000000ff", "Race goal", "active", @iso_now, @iso_now]
    )

    %{id: id}
  end

  defp seed_admission_event!(repo, goal, sequence, event_id) do
    repo.query!(
      "INSERT INTO trajectory_events (id, goal_id, sequence, type, actor, occurred_at, schema_version, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        event_id,
        goal.id,
        sequence,
        "admission.decided",
        "cobbler",
        @iso_now,
        1,
        Jason.encode!(admission_payload())
      ]
    )

    %{
      id: event_id,
      payload: %{
        "requested_capability" => "supervised_execution",
        "scope" => "account:codex",
        "candidate" => %{"provider_id" => "codex", "adapter_id" => "codex_app_server"}
      }
    }
  end

  defp attempt_active_claim_insert(repo, goal_id, command_id) do
    try do
      repo.transaction(
        fn ->
          case repo.query(active_claim_insert_sql(), active_claim_params(goal_id, command_id)) do
            {:ok, _result} -> :inserted
            {:error, _error} -> repo.rollback(:rejected)
          end
        end,
        mode: :immediate
      )
      |> case do
        {:ok, :inserted} -> {:ok, :inserted}
        {:error, _reason} -> {:error, :rejected}
      end
    rescue
      _error -> {:error, :rejected}
    end
  end

  defp active_claim_insert_sql do
    "INSERT INTO cobbler_task_claims
       (id, scope, status, goal_id, command_id, intent, provider_id,
        admission_decision_id, admission_event_id, inserted_at, updated_at)
     VALUES (?, 'global', 'active', ?, ?, 'supervised_execution', 'codex',
             '00000000-0000-4000-8000-0000000000ee', ?, ?, ?)"
  end

  defp active_claim_params(goal_id, command_id) do
    [
      Ecto.UUID.generate(),
      goal_id,
      command_id,
      Ecto.UUID.generate(),
      @iso_now,
      @iso_now
    ]
  end
end
