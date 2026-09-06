defmodule ShoestringWeb.RunLiveTest do
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Shoestring.Harness.CapacityObservatory
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Repo
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent
  alias ShoestringWeb.RunShowLive
  alias ShoestringWeb.RunPresentation
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

    test "repository path outside allowed roots is rejected with clean error (B4)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      submit_payload = %{
        "run" => %{
          "repo_path" => "/Users/bob/nonexistent_repo_xyz",
          "base_revision" => "HEAD",
          "provider" => "fake",
          "prompt" => "B4 outside path check",
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

      assert html =~ "Repository path is not allowed"
      flash_html = flash_group_html(html)
      refute flash_html =~ "/Users/bob"
    end

    test "invalid base revision flash provides clean error without leaking secret tokens or inspected terms (B3)",
         %{
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
          "prompt" => "B3 base revision clean flash check",
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
      flash_html = flash_group_html(html)
      # B3(a): Clean user message, no raw inspected terms or secret tokens
      refute flash_html =~ secret
      refute flash_html =~ "{"
      refute flash_html =~ ":invalid_base_revision"
      assert flash_html =~ "invalid repository path or base revision"
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

    test "cancel_run reports a clean flash when the run assign is unavailable" do
      {:ok, socket} = RunShowLive.mount(%{"run_id" => Ecto.UUID.generate()}, %{}, empty_socket())

      assert {:noreply, socket} = RunShowLive.handle_event("cancel_run", %{}, socket)

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Run is no longer available. Please refresh the page."
    end

    test "request_stop reports a clean flash when the run assign is unavailable" do
      {:ok, socket} = RunShowLive.mount(%{"run_id" => Ecto.UUID.generate()}, %{}, empty_socket())

      assert {:noreply, socket} = RunShowLive.handle_event("request_stop", %{}, socket)

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Run is no longer available. Please refresh the page."
    end

    test "live event stream stays bounded and reports the capped window", %{
      conn: conn,
      goal: goal,
      run: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      events =
        for sequence <- 1..(RunPresentation.max_rendered_events() + 1) do
          event = %TrajectoryEvent{
            id: Ecto.UUID.generate(),
            goal_id: goal.id,
            run_id: run.id,
            sequence: sequence,
            schema_version: 1,
            type: "harness.event_recorded",
            actor: "elf",
            occurred_at: DateTime.utc_now(),
            idempotency_key: "evt-stream-bound-#{sequence}",
            payload: %{
              "run_id" => run.id,
              "source_event_id" => "stream-bound-#{sequence}",
              "ordinal" => sequence,
              "kind" => "command"
            }
          }

          send(view.pid, {:trajectory_event_committed, event})
          _ = :sys.get_state(view.pid)
          _ = render(view)
          event
        end

      _ = :sys.get_state(view.pid)

      document = LazyHTML.from_fragment(render(view))

      rendered_events =
        document
        |> LazyHTML.query("#events-stream > div[data-sequence]")
        |> LazyHTML.to_tree()

      first_event = hd(events)
      last_event = List.last(events)

      assert length(rendered_events) == RunPresentation.max_rendered_events()
      assert has_element?(view, "#events-window-notice")
      assert render(view) =~ "Showing 200 of 201 events"
      refute has_element?(view, "#run-event-#{first_event.id}")
      assert has_element?(view, "#run-event-#{last_event.id}")
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

  describe "Regression tests for B1, B2, B4" do
    test "B1 regression: creating multiple fixture repos does not reap earlier repos", %{
      conn: conn
    } do
      # Set up an existing fixture repo with an older mtime in tmp
      tmp = System.tmp_dir!()
      unique = System.unique_integer([:positive])
      reap_target = Path.join(tmp, "shoestring_fixture_repo_reap_target_#{unique}")
      File.mkdir_p!(reap_target)
      File.touch!(reap_target, System.os_time(:second) - 3600)

      filler_dirs =
        for i <- 1..5 do
          dir = Path.join(tmp, "shoestring_fixture_repo_filler_#{unique}_#{i}")
          File.mkdir_p!(dir)
          File.touch!(dir, System.os_time(:second) - 1800 + i)
          dir
        end

      on_exit(fn ->
        File.rm_rf(reap_target)
        Enum.each(filler_dirs, &File.rm_rf/1)
      end)

      {:ok, view, _html} = live(conn, ~p"/runs/new")

      # Trigger fixture repo creation
      view |> element("#btn-use-fixture") |> render_click()

      # At 2288ca4, maybe_reap_fixture_repos deletes fixture dirs by mtime once >5 exist.
      # Because reap_target had the oldest mtime, 2288ca4 rm_rf'd it.
      # With the reaper deleted, reap_target remains intact.
      assert File.dir?(reap_target)
    end

    test "B2 regression: handle_info does not crash on trajectory event when run is not found", %{
      conn: conn
    } do
      missing_id = Ecto.UUID.generate()
      {:ok, view, html} = live(conn, ~p"/runs/#{missing_id}")
      assert html =~ "Run Not Found"

      event = %Shoestring.Trajectory.TrajectoryEvent{
        id: Ecto.UUID.generate(),
        goal_id: Ecto.UUID.generate(),
        run_id: missing_id,
        sequence: 1,
        schema_version: 1,
        type: "harness.event_recorded",
        actor: "elf",
        occurred_at: DateTime.utc_now(),
        idempotency_key: "evt-b2-test",
        payload: %{}
      }

      send(view.pid, {:trajectory_event_committed, event})

      # At 2288ca4, this crashes with KeyError on socket.assigns.goal.id.
      # With B2 guarded, the LiveView remains alive and renders cleanly.
      assert render(view) =~ "Run Not Found"
    end

    test "B4 regression: rejects repository path outside allowed roots", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/new")

      outside_dir =
        Path.join(System.tmp_dir!(), "outside_repo_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: outside_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Shoestring Test"], cd: outside_dir)

      {_, 0} =
        System.cmd("git", ["config", "user.email", "test@shoestring.local"], cd: outside_dir)

      File.write!(Path.join(outside_dir, "README.md"), "outside root\n")
      {_, 0} = System.cmd("git", ["add", "README.md"], cd: outside_dir)

      {_, 0} =
        System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "Initial commit"],
          cd: outside_dir
        )

      on_exit(fn -> File.rm_rf(outside_dir) end)

      submit_payload = %{
        "run" => %{
          "repo_path" => outside_dir,
          "base_revision" => "HEAD",
          "provider" => "fake",
          "prompt" => "B4 outside repo path check",
          "timeout_seconds" => "60",
          "max_events" => "100",
          "lease_seconds" => "30",
          "scenario" => "success"
        }
      }

      result =
        view
        |> form("#manual-run-form", submit_payload)
        |> render_submit()

      # At 2288ca4, this valid outside repo was accepted and the LiveView
      # redirected after creating a worktree. The fixed path fails before any
      # worktree or run is created and returns the validation flash instead.
      case result do
        {:error, {:live_redirect, %{to: target}}} ->
          run_id = String.replace(target, "/runs/", "")
          _ = Shoestring.Elves.cancel_run(run_id)

        _ ->
          :ok
      end

      assert is_binary(result)
      assert result =~ "Repository path is not allowed"
    end
  end

  describe "PR #35 fix round 1: terminal cap (B1) and not-found consistency (B2)" do
    setup %{repo_path: repo_path} do
      %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
      run_id = Ecto.UUID.generate()

      {:ok, worktree} = Worktrees.create(repo_path, run_id, "HEAD")

      run =
        %RunRecord{
          id: run_id,
          dispatch_id: run_id,
          goal_id: goal.id,
          task_id: task.id,
          provider_id: "fake",
          workspace_ref: worktree.workspace_ref,
          request_version: 1,
          prompt: "PR35 round1 regression run",
          continuation: nil,
          policy: %{"mode" => "manual_execution"},
          requested_capabilities: %{items: ["cancel"]},
          extensions: %{},
          status: "running"
        }
        |> Repo.insert!()

      {:ok, goal: goal, task: task, run: run, worktree: worktree}
    end

    test "B1 regression: oversized terminal payload is capped with explicit notice", %{
      conn: conn,
      goal: goal,
      task: task,
      run: run
    } do
      # At b16f652 run_show_live.html.heex renders
      # RunPresentation.format_payload(@terminal_event.payload) with no cap.
      big_error = String.duplicate("x", 40_000)

      assert {:ok, _} =
               Trajectory.append(
                 goal.id,
                 %{
                   "type" => "run.failed",
                   "schema_version" => 1,
                   "actor" => "elf",
                   "occurred_at" => DateTime.utc_now(),
                   "idempotency_key" => "evt-terminal-cap-#{run.id}",
                   "payload" => %{
                     "run_id" => run.id,
                     "error_category" => "terminal_cap_probe",
                     "error_code" => big_error
                   }
                 },
                 trusted: [task_id: task.id, run_id: run.id]
               )

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      rendered = render(view)

      assert has_element?(view, "#terminal-payload-truncated")
      assert rendered =~ "Terminal payload truncated"
      assert rendered =~ "bytes omitted"

      payload_html =
        rendered
        |> LazyHTML.from_fragment()
        |> LazyHTML.query_by_id("terminal-payload")
        |> LazyHTML.to_html()

      assert byte_size(payload_html) < byte_size(big_error)
      # B4 fixed the event-stream leak this assertion used to work around:
      # the whole page must not contain the full payload.
      refute rendered =~ big_error
      assert payload_html =~ "bytes omitted"
    end

    test "B4 regression: oversized per-event payload is capped with explicit notice", %{
      conn: conn,
      goal: goal,
      task: task,
      run: run
    } do
      # At 114cfdd the event stream renders
      # RunPresentation.format_payload(event.payload) with no cap, so a large
      # payload crosses the WebSocket unbounded into the browser DOM.
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      big_output = String.duplicate("x", 40_000)

      stream_event = %TrajectoryEvent{
        id: Ecto.UUID.generate(),
        goal_id: goal.id,
        task_id: task.id,
        run_id: run.id,
        sequence: 999,
        schema_version: 1,
        type: "harness.event_recorded",
        actor: "elf",
        occurred_at: DateTime.utc_now(),
        idempotency_key: "evt-stream-cap-#{run.id}",
        payload: %{
          "run_id" => run.id,
          "source_event_id" => "stream-cap-probe",
          "ordinal" => 1,
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "kind" => "command",
          "result" => %{"output" => big_output}
        }
      }

      send(view.pid, {:trajectory_event_committed, stream_event})
      rendered = render(view)

      assert has_element?(view, "#run-event-#{stream_event.id}")
      assert has_element?(view, ".event-payload-truncated")
      assert rendered =~ "Event payload truncated"
      assert rendered =~ "bytes omitted"

      event_html =
        rendered
        |> LazyHTML.from_fragment()
        |> LazyHTML.query_by_id("run-event-#{stream_event.id}")
        |> LazyHTML.to_html()

      assert byte_size(event_html) < byte_size(big_output)
      refute event_html =~ big_output
      assert event_html =~ "bytes omitted"
    end

    test "B2a regression: refresh recovers via run_id when mounted before commit" do
      # At b16f652 reload_run_state/1 checks only socket.assigns[:run],
      # so a not-found mount can never recover via refresh.
      missing_id = Ecto.UUID.generate()
      {:ok, socket} = RunShowLive.mount(%{"run_id" => missing_id}, %{}, empty_socket())

      assert socket.assigns[:run_not_found?]
      assert socket.assigns[:run_id] == missing_id
      assert socket.assigns[:run] == nil

      %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()

      %RunRecord{
        id: missing_id,
        dispatch_id: missing_id,
        goal_id: goal.id,
        task_id: task.id,
        provider_id: "fake",
        workspace_ref: "workspace/#{missing_id}",
        request_version: 1,
        prompt: "late-committed run",
        continuation: nil,
        policy: %{"mode" => "manual_execution"},
        requested_capabilities: %{items: ["cancel"]},
        extensions: %{},
        status: "running"
      }
      |> Repo.insert!()

      assert {:noreply, refreshed} = RunShowLive.handle_event("refresh", %{}, socket)
      refute refreshed.assigns[:run_not_found?]
      assert refreshed.assigns[:run].id == missing_id
      assert refreshed.assigns[:run_id] == missing_id
    end

    test "B2b regression: deleted run clears stale assign on refresh", %{run: run} do
      # At b16f652 reload_run_state/1 leaves the stale :run struct in assigns
      # while setting :run_not_found? => true.
      {:ok, socket} = RunShowLive.mount(%{"run_id" => run.id}, %{}, empty_socket())
      assert socket.assigns[:run].id == run.id

      run |> Repo.reload!() |> Repo.delete!()

      assert {:noreply, refreshed} = RunShowLive.handle_event("refresh", %{}, socket)
      assert refreshed.assigns[:run_not_found?]
      assert refreshed.assigns[:run] == nil
      assert refreshed.assigns[:run_id] == run.id
    end

    test "N1 regression: changed-files list is capped with explicit notice", %{
      conn: conn,
      run: run,
      worktree: worktree
    } do
      # At b8588b7 the template renders every changed file with no limit.
      for i <- 1..150 do
        File.write!(Path.join(worktree.path, "bulk_changed_#{i}.txt"), "bulk content #{i}\n")
      end

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      rendered = render(view)

      assert has_element?(view, "#changed-files-truncated")
      assert rendered =~ "Showing 100 of 150 changed files for bounded rendering."

      items =
        rendered
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#worktree-info li")
        |> LazyHTML.to_tree()

      assert length(items) == 100
    end
  end

  defp flash_group_html(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query_by_id("flash-group")
    |> LazyHTML.to_html()
  end

  defp empty_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: nil, flash: %{}},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end
end
