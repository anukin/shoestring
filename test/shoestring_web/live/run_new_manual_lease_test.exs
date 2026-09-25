defmodule ShoestringWeb.RunNewManualLeaseTest do
  @moduledoc """
  The lease a `/runs/new` manual run is granted, fed the spend the Elf
  actually accounts.

  A manual lease is scoped `account:manual`. No provider reading carries that
  scope, so its renewal is never admitted: at every due boundary
  `LeaseRenewal` returns `:expired` (`snapshot_provider_mismatch`) and the
  Elf declines — checkpoint, suspend, stop. At base the manual admission
  proposed `checkpoint_cadence: 1`, so renewal was due after the FIRST
  response and every manual run ended there, whatever `max_events` the
  operator declared. (Live, #82 never saw this only because renewal wedged
  the projector first and the Elf "worked on".)

  LOCK: "one response is not a renewal boundary" fails on base (`due` after
  the first completed message). DOC: the operator's own envelope still ends
  the run through the same unrenewable safeguard — nothing is relaxed.

  Hermetic: the Fake provider path of `/runs/new`, a fixture git repo, no
  provider CLI. The Elf is not required to stream (the manual Fake path
  cannot: it passes an atom scenario), because the bounds are read off the
  persisted grant exactly as `Elf.ensure_lease_bounds/1` reads them.
  """
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Shoestring.Cobbler.{LeaseBounds, LeaseRenewal}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    ExecutionLeaseRecord,
    HarnessEvent,
    Projector,
    RunRecord
  }

  alias Shoestring.Repo

  setup do
    unique = "#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
    tmp_root = Path.join(System.tmp_dir!(), "shoestring_manual_run_test_#{unique}")
    File.rm_rf(tmp_root)
    repo_path = Path.join(tmp_root, "source_repo")
    File.mkdir_p!(repo_path)

    # Initialize fixture repo
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: repo_path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Shoestring Test"], cd: repo_path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@shoestring.local"], cd: repo_path)

    File.write!(Path.join(repo_path, "README.md"), "# Test Source Repo\nInitial content\n")
    File.write!(Path.join(repo_path, "lib.ex"), "defmodule Lib do\n  def test, do: :ok\nend\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo_path)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "Initial commit"],
        cd: repo_path
      )

    prev_roots = Application.get_env(:shoestring, :manual_run_allowed_repo_roots)
    Application.put_env(:shoestring, :manual_run_allowed_repo_roots, [tmp_root])

    on_exit(fn ->
      if prev_roots do
        Application.put_env(:shoestring, :manual_run_allowed_repo_roots, prev_roots)
      else
        Application.delete_env(:shoestring, :manual_run_allowed_repo_roots)
      end

      File.rm_rf(tmp_root)
    end)

    # Ensure Elves supervisor is running
    _sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})

    {:ok, repo_path: repo_path, tmp_root: tmp_root}
  end

  test "LOCK: one completed response is not a renewal boundary for a manual lease", %{
    conn: conn,
    repo_path: repo_path
  } do
    grant = manual_grant!(conn, repo_path, "100")

    {bounds, effects} = LeaseBounds.advance(bounds(grant), completed_message(grant, 1))
    assert bounds.responses == 1
    refute :renewal_due in effects
    refute LeaseBounds.due?(bounds)
    assert grant.checkpoint_cadence == 100

    bounds = spend(bounds, grant, 2..99)
    assert bounds.responses == 99
    refute LeaseBounds.due?(bounds)
  end

  test "DOC: the operator's max_events still ends the run at the boundary", %{
    conn: conn,
    repo_path: repo_path
  } do
    grant = manual_grant!(conn, repo_path, "100")
    bounds = spend(bounds(grant), grant, 1..100)
    assert bounds.responses == 100
    assert LeaseBounds.due?(bounds)
  end

  test "DOC: a manual lease's renewal is still never admitted on a provider reading", %{
    conn: conn,
    repo_path: repo_path
  } do
    grant = manual_grant!(conn, repo_path, "100")
    now = DateTime.utc_now()

    assert {:ok, %{outcome: :expired, decision: decision}} =
             LeaseRenewal.maybe_renew(grant.goal_id, grant.id,
               now: now,
               stop: :already_requested,
               boundary: :item_completed,
               observe: fn -> {:ok, codex_reading(now)} end
             )

    assert decision.result == :reject
    assert decision.reason_code == "snapshot_provider_mismatch"
  end

  defp manual_grant!(conn, repo_path, max_events) do
    {:ok, view, _html} = live(conn, ~p"/runs/new")

    payload = %{
      "run" => %{
        "repo_path" => repo_path,
        "base_revision" => "HEAD",
        "provider" => "fake",
        "prompt" => "Manual lease cadence prompt",
        "timeout_seconds" => "60",
        "max_events" => max_events,
        "lease_seconds" => "300",
        "scenario" => "success"
      }
    }

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view |> form("#manual-run-form", payload) |> render_submit()

    run = Repo.get!(RunRecord, run_id)
    assert {:ok, _} = Projector.project(run.goal_id)
    Repo.get_by!(ExecutionLeaseRecord, run_id: run_id)
  end

  # Exactly the fields `Elf.ensure_lease_bounds/1` reads off the grant row.
  defp bounds(grant) do
    LeaseBounds.new(%{
      grant_id: grant.id,
      run_id: grant.run_id,
      response_budget: grant.response_budget,
      tool_budget: grant.tool_budget,
      response_reserve: grant.response_reserve,
      tool_reserve: grant.tool_reserve,
      checkpoint_cadence: grant.checkpoint_cadence
    })
  end

  defp spend(bounds, grant, range) do
    Enum.reduce(range, bounds, fn n, acc ->
      {acc, _effects} = LeaseBounds.advance(acc, completed_message(grant, n))
      acc
    end)
  end

  defp completed_message(grant, n) do
    {:ok, event} =
      HarnessEvent.new(%{
        version: 1,
        run_id: grant.run_id,
        source_event_id: "evt-#{n}-output",
        ordinal: n,
        occurred_at: DateTime.utc_now(),
        kind: :output,
        # A completed agent message carries its text (delta frames do not).
        extensions: %{"codex-app-server:text" => "message #{n}"}
      })

    event
  end

  # The shape the Codex monitor serves live: provider-scoped, not manual.
  defp codex_reading(now) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :unknown,
          windows: [],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "codex_app_server",
            provider_id: "codex",
            invocation_mode: "app_server",
            event: :explicit_read
          },
          scope: "subscription",
          confidence: :none,
          support_tier: :proactive,
          compatibility_state: :degraded,
          reason: "untested_cli_version",
          extensions: %{}
        },
        now: now
      )

    snapshot
  end
end
