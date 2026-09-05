defmodule ShoestringWeb.RunLiveTest do
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Shoestring.Harness.CapacityObservatory
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Repo
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Worktrees
  alias Shoestring.Worktrees.Worktree

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

    on_exit(fn ->
      File.rm_rf(tmp_root)
    end)

    # Ensure Elves supervisor is running
    _sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})

    {:ok, repo_path: repo_path, tmp_root: tmp_root}
  end

  describe "/runs/new" do
    test "renders manual execution banner and all required input fields", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/runs/new")

      assert has_element?(view, "#manual-execution-banner")
      assert html =~ "MANUAL EXECUTION"
      assert html =~ "Not Cobbler Routing"

      # Verify required form fields
      assert has_element?(view, "#manual-run-form")
      assert has_element?(view, "#run-repo-path")
      assert has_element?(view, "#run-base-revision")
      assert has_element?(view, "#run-provider")
      assert has_element?(view, "#run-prompt")
      assert has_element?(view, "#run-timeout-seconds")
      assert has_element?(view, "#run-max-events")
      assert has_element?(view, "#run-lease-seconds")
      assert has_element?(view, "#btn-start-run")
      # B6: custom command capability removed from the UI entirely
      refute has_element?(view, "#run-command")
    end

    test "validates required fields before submitting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      # Submitting with empty prompt
      view
      |> form("#manual-run-form", %{
        "run" => %{
          "repo_path" => "/some/repo",
          "prompt" => ""
        }
      })
      |> render_submit()

      assert render(view) =~ "Task prompt is required."

      # Submitting with empty repo_path
      view
      |> form("#manual-run-form", %{
        "run" => %{
          "repo_path" => "",
          "prompt" => "Do some task"
        }
      })
      |> render_submit()

      assert render(view) =~ "Source repository path is required."
    end

    test "btn-use-fixture creates a temporary fixture repository", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      view
      |> element("#btn-use-fixture")
      |> render_click()

      assert render(view) =~ "Initialized temporary fixture repository."
      assert has_element?(view, "#run-repo-path[value*='shoestring_fixture_repo']")
    end

    test "starts a manual run, provisions worktree, and navigates to /runs/:run_id", %{
      conn: conn,
      repo_path: repo_path
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      submit_payload = %{
        "run" => %{
          "repo_path" => repo_path,
          "base_revision" => "HEAD",
          "provider" => "fake",
          "prompt" => "Deterministic manual test prompt",
          "timeout_seconds" => "60",
          "max_events" => "100",
          "lease_seconds" => "30",
          "scenario" => "success"
        }
      }

      {:error, {:live_redirect, %{to: target_path}}} =
        view
        |> form("#manual-run-form", submit_payload)
        |> render_submit()

      assert target_path =~ ~r|^/runs/[0-9a-f-]+|
      run_id = String.replace(target_path, "/runs/", "")

      # Verify durable state created
      run = Repo.get!(RunRecord, run_id)
      assert run.provider_id == "shoestring.harness.fake"
      assert run.prompt == "Deterministic manual test prompt"

      # Verify worktree provisioned
      assert {:ok, %Worktree{} = wt} = Worktrees.get(run_id)
      assert File.dir?(wt.path)
      assert wt.branch == "shoestring/run-#{run_id}"
    end

    test "ignores posted custom command (B6 capability removed, not restricted)", %{
      conn: conn,
      repo_path: repo_path
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      # Crafted POST bypassing the rendered form (which has no command input).
      {:error, {:live_redirect, %{to: target_path}}} =
        render_submit(view, :start_run, %{
          "run" => %{
            "repo_path" => repo_path,
            "base_revision" => "HEAD",
            "provider" => "fake",
            "prompt" => "B6 command injection attempt",
            "timeout_seconds" => "60",
            "max_events" => "100",
            "lease_seconds" => "30",
            "command" => "touch /tmp/pwned_by_form",
            "scenario" => "success"
          }
        })

      assert target_path =~ ~r|^/runs/[0-9a-f-]+|
      # The injected command must never execute as the app user.
      refute File.exists?("/tmp/pwned_by_form")
    end

    test "unknown scenario string defaults safely without creating atoms (B1)", %{
      conn: conn,
      repo_path: repo_path
    } do
      evil =
        "evil_scenario_#{System.unique_integer([:positive])}_#{:erlang.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(evil) end

      {:ok, view, _html} = live(conn, ~p"/runs/new")

      # Crafted POST bypassing the rendered select (which only offers known scenarios).
      {:error, {:live_redirect, %{to: target_path}}} =
        render_submit(view, :start_run, %{
          "run" => %{
            "repo_path" => repo_path,
            "base_revision" => "HEAD",
            "provider" => "fake",
            "prompt" => "B1 atom exhaustion attempt",
            "timeout_seconds" => "60",
            "max_events" => "100",
            "lease_seconds" => "30",
            "scenario" => evil
          }
        })

      assert target_path =~ ~r|^/runs/[0-9a-f-]+|
      # Unknown input must not intern a new atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(evil) end
    end

    test "out-of-range and negative leases are clamped server-side (B2)", %{
      conn: conn,
      repo_path: repo_path
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      submit_payload = %{
        "run" => %{
          "repo_path" => repo_path,
          "base_revision" => "HEAD",
          "provider" => "fake",
          "prompt" => "B2 clamp check",
          "timeout_seconds" => "999999999",
          "max_events" => "-5",
          "lease_seconds" => "999999",
          "scenario" => "success"
        }
      }

      {:error, {:live_redirect, %{to: target_path}}} =
        view
        |> form("#manual-run-form", submit_payload)
        |> render_submit()

      run_id = String.replace(target_path, "/runs/", "")
      run = Repo.get!(RunRecord, run_id)
      ext = run.extensions || %{}
      assert ext["shoestring.manual:timeout_seconds"] == 3600
      assert ext["shoestring.manual:max_events"] == 10
      assert ext["shoestring.manual:lease_seconds"] == 300
    end

    test "worktree failure flash redacts home paths and secret tokens (B3)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      submit_payload = %{
        "run" => %{
          "repo_path" => "/Users/bob/nonexistent_repo_xyz",
          "base_revision" => "HEAD",
          "provider" => "fake",
          "prompt" => "B3 flash redaction check",
          "timeout_seconds" => "60",
          "max_events" => "100",
          "lease_seconds" => "30",
          "scenario" => "success"
        }
      }

      html =
        view
        |> form("#manual-run-form", submit_payload)
        |> render_submit()

      assert html =~ "Worktree allocation failed"
      # Scope to the flash group: the form legitimately echoes the user's own
      # typed path in its input value, but the flashed failure reason must be
      # redacted.
      flash_html = flash_group_html(html)
      refute flash_html =~ "/Users/bob"
      assert flash_html =~ "/Users/[REDACTED]"
    end

    test "invalid base revision flash redacts secret-shaped token (B3)", %{
      conn: conn,
      repo_path: repo_path
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      secret = "sk-ant-api03-abcdef1234567890abcdef123456"

      submit_payload = %{
        "run" => %{
          "repo_path" => repo_path,
          "base_revision" => secret,
          "provider" => "fake",
          "prompt" => "B3 base revision redaction check",
          "timeout_seconds" => "60",
          "max_events" => "100",
          "lease_seconds" => "30",
          "scenario" => "success"
        }
      }

      html =
        view
        |> form("#manual-run-form", submit_payload)
        |> render_submit()

      assert html =~ "Worktree allocation failed"
      # Scope to the flash group: the form echoes the typed revision in its
      # input value, but the flashed failure reason must be redacted.
      flash_html = flash_group_html(html)
      refute flash_html =~ secret
      assert flash_html =~ "[REDACTED_API_KEY]"
    end
  end

  describe "/runs/:run_id" do
    setup %{repo_path: repo_path} do
      %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
      run_id = Ecto.UUID.generate()

      # Provision worktree
      {:ok, worktree} = Worktrees.create(repo_path, run_id, "HEAD")

      # Create RunRecord
      run =
        %RunRecord{
          id: run_id,
          dispatch_id: run_id,
          goal_id: goal.id,
          task_id: task.id,
          provider_id: "fake",
          workspace_ref: worktree.workspace_ref,
          request_version: 1,
          prompt: "Initial prompt for show test",
          continuation: nil,
          policy: %{"mode" => "manual_execution"},
          requested_capabilities: %{items: ["cancel"]},
          extensions: %{},
          status: "running"
        }
        |> Repo.insert!()

      # Ingest a capacity snapshot for provider
      now = DateTime.utc_now()

      {:ok, snapshot} =
        CapacitySnapshot.new(%{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :observed,
          windows: [
            %{
              kind: "five_hour",
              state: :observed,
              used_percent: 18.5,
              reset_at: DateTime.add(now, 3600, :second)
            }
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "fake_adapter",
            provider_id: "fake",
            invocation_mode: "app_server_stdio",
            event: :explicit_read
          },
          scope: "account",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        })

      {:ok, _, _} = CapacityObservatory.ingest(snapshot)

      {:ok, goal: goal, task: task, run: run, worktree: worktree}
    end

    test "renders all required manual run UI sections", %{
      conn: conn,
      run: run,
      worktree: worktree
    } do
      {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

      # 1. Clear label: MANUAL EXECUTION, not Cobbler routing
      assert has_element?(view, "#manual-execution-banner")
      assert html =~ "MANUAL EXECUTION"
      assert html =~ "Not Cobbler Routing"

      # 2. Run header, status, process info
      assert has_element?(view, "#run-header")
      assert has_element?(view, "#run-status-badge")
      assert has_element?(view, "#run-process-info")
      assert has_element?(view, "#run-provider-name")

      # 3. Action controls
      assert has_element?(view, "#btn-cancel-run")
      assert has_element?(view, "#btn-request-stop")

      # 4. Worktree information
      assert has_element?(view, "#worktree-info")
      assert html =~ worktree.branch

      # 5. Capacity snapshot
      assert has_element?(view, "#capacity-snapshot")
      assert html =~ "18.5%"

      # 6. Verification evidence and diff
      assert has_element?(view, "#verification-evidence")
      assert has_element?(view, "#worktree-diff")

      # 7. Logs and Events
      assert has_element?(view, "#run-logs")
      assert has_element?(view, "#events-stream")
    end

    test "cancel_run triggers cancellation and updates view", %{
      conn: conn,
      run: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view
      |> element("#btn-cancel-run")
      |> render_click()

      assert render(view) =~ "cancellation requested" or render(view) =~ "already terminal"
    end

    test "request_stop handles safe stop request", %{
      conn: conn,
      run: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view
      |> element("#btn-request-stop")
      |> render_click()

      # Because no live session was registered for this fake DB row, it cleanly reports not found
      assert render(view) =~ "No active session found" or render(view) =~ "Safe stop requested"
    end

    test "live PubSub updates stream events in real time", %{
      conn: conn,
      goal: goal,
      task: task,
      run: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # Append a new event to the trajectory
      new_event_attrs = %{
        "type" => "harness.event_recorded",
        "schema_version" => 1,
        "actor" => "elf",
        "occurred_at" => DateTime.utc_now(),
        "idempotency_key" => "evt-stream-live-1",
        "payload" => %{
          "run_id" => run.id,
          "source_event_id" => "live-stream-test",
          "ordinal" => 1,
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "kind" => "command"
        }
      }

      assert {:ok, event} =
               Trajectory.append(goal.id, new_event_attrs,
                 trusted: [task_id: task.id, run_id: run.id]
               )

      # Verify the event appears in the live stream without page navigation
      assert has_element?(view, "#run-event-#{event.id}")
      assert render(view) =~ "live-stream-test"
    end

    test "not found run id renders clean error state", %{conn: conn} do
      missing_id = Ecto.UUID.generate()
      {:ok, view, html} = live(conn, ~p"/runs/#{missing_id}")

      assert has_element?(view, "#run-not-found")
      assert html =~ "Run Not Found"
    end

    test "malformed run id renders clean not-found instead of crashing", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/runs/abc")

      assert has_element?(view, "#run-not-found")
      assert html =~ "Run Not Found"
    end
  end

  describe "Deterministic Eval: UI restart" do
    test "restarting the endpoint leaves the run, worktree, and trajectory intact", %{
      conn: conn,
      repo_path: repo_path
    } do
      %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
      run_id = Ecto.UUID.generate()

      # 1. Provision worktree and run
      {:ok, worktree} = Worktrees.create(repo_path, run_id, "HEAD")

      # Create a modified file in the worktree to verify diff survival
      modified_file = Path.join(worktree.path, "test_file.txt")
      File.write!(modified_file, "Worktree file written before restart\n")

      run =
        %RunRecord{
          id: run_id,
          dispatch_id: run_id,
          goal_id: goal.id,
          task_id: task.id,
          provider_id: "fake",
          workspace_ref: worktree.workspace_ref,
          request_version: 1,
          prompt: "Testing UI restart persistence",
          continuation: nil,
          policy: %{"mode" => "manual_execution"},
          requested_capabilities: %{items: ["cancel"]},
          extensions: %{},
          status: "running"
        }
        |> Repo.insert!()

      # 2. Append trajectory events
      for i <- 1..3 do
        event_attrs = %{
          "type" => "harness.event_recorded",
          "schema_version" => 1,
          "actor" => "elf",
          "occurred_at" => DateTime.utc_now(),
          "idempotency_key" => "evt-restart-#{i}",
          "payload" => %{
            "run_id" => run.id,
            "source_event_id" => "evt-restart-#{i}",
            "ordinal" => i,
            "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "kind" => "command"
          }
        }

        assert {:ok, _} =
                 Trajectory.append(goal.id, event_attrs,
                   trusted: [task_id: task.id, run_id: run.id]
                 )
      end

      # Append terminal event
      terminal_attrs = %{
        "type" => "run.completed",
        "schema_version" => 1,
        "actor" => "elf",
        "occurred_at" => DateTime.utc_now(),
        "idempotency_key" => "term-restart-#{run_id}",
        "payload" => %{"run_id" => run_id}
      }

      assert {:ok, _} =
               Trajectory.append(goal.id, terminal_attrs,
                 trusted: [task_id: task.id, run_id: run_id]
               )

      # 3. Mount UI first time before restart
      {:ok, view1, html1} = live(conn, ~p"/runs/#{run.id}")
      assert html1 =~ "Testing UI restart persistence"
      assert html1 =~ "COMPLETED" or html1 =~ "completed"
      assert has_element?(view1, "#worktree-diff")

      # 4. SIMULATE UI / ENDPOINT RESTART:
      # Explicitly terminate and restart the Endpoint process
      :ok = Supervisor.terminate_child(Shoestring.Supervisor, ShoestringWeb.Endpoint)

      {:ok, _new_endpoint} =
        Supervisor.restart_child(Shoestring.Supervisor, ShoestringWeb.Endpoint)

      # 5. Re-mount the endpoint with a fresh connection (reconnect after restart)
      {:ok, view2, html2} = live(build_conn(), ~p"/runs/#{run.id}")

      # Verify all data survives intact:
      # - Prompt and header intact
      assert html2 =~ "Testing UI restart persistence"
      assert has_element?(view2, "#manual-execution-banner")

      # - Run status remains completed
      assert html2 =~ "COMPLETED" or html2 =~ "completed"

      # - All 3 trajectory events survived and render
      for i <- 1..3 do
        assert html2 =~ "evt-restart-#{i}"
      end

      # - Worktree and diff survive intact
      assert has_element?(view2, "#worktree-info")
      assert html2 =~ "test_file.txt"
      assert html2 =~ worktree.branch

      # - Terminal outcome preserved
      assert html2 =~ "run.completed"
    end
  end

  defp flash_group_html(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query_by_id("flash-group")
    |> LazyHTML.to_html()
  end
end
