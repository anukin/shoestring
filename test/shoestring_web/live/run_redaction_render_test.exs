defmodule ShoestringWeb.RunRedactionRenderTest do
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ArtifactStore, Goal, Task, TrajectoryEvent}
  alias ShoestringWeb.RunPresentation

  setup do
    goal =
      %Goal{id: Ecto.UUID.generate()}
      |> Goal.changeset(%{
        "title" => "Redaction Test Goal",
        "description" => "Testing UI boundary"
      })
      |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
      |> Repo.insert!()

    task =
      %Task{id: Ecto.UUID.generate()}
      |> Task.changeset(%{"title" => "Redaction Task", "description" => "Task"})
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    run_id = Ecto.UUID.generate()

    run =
      %Shoestring.Harness.RunRecord{
        id: run_id,
        dispatch_id: run_id,
        goal_id: goal.id,
        task_id: task.id,
        provider_id: "fake",
        workspace_ref: "workspace/#{run_id}",
        request_version: 1,
        prompt:
          "Task prompt with path /Users/bob/sensitive_project/secret.txt and api_key=sk-1234567890abcdef1234",
        continuation: nil,
        policy: %{"mode" => "manual_execution"},
        requested_capabilities: %{items: ["cancel"]},
        extensions: %{},
        status: "running"
      }
      |> Repo.insert!()

    {:ok, goal: goal, task: task, run: run}
  end

  test "unit: RunPresentation redacts credentials, home paths, and strips reasoning", _ctx do
    # API keys and tokens
    assert RunPresentation.redact_text("sk-proj-1234567890abcdef123456") =~ "[REDACTED_API_KEY]"

    assert RunPresentation.redact_text("ghp_123456789012345678901234567890123456") =~
             "[REDACTED_API_KEY]"

    assert RunPresentation.redact_text("AKIA1234567890ABCDEF") =~ "[REDACTED_API_KEY]"
    assert RunPresentation.redact_text("ASIA1234567890ABCDEF") =~ "[REDACTED_API_KEY]"
    assert RunPresentation.redact_text("AKIB1234567890ABCDEF") =~ "[REDACTED_API_KEY]"
    assert RunPresentation.redact_text("github_pat_1234567890abcdef") =~ "[REDACTED_API_KEY]"

    assert RunPresentation.redact_text("gho_12345678901234567890123456789012") =~
             "[REDACTED_API_KEY]"

    assert RunPresentation.redact_text("ghu_12345678901234567890123456789012") =~
             "[REDACTED_API_KEY]"

    assert RunPresentation.redact_text("ghs_12345678901234567890123456789012") =~
             "[REDACTED_API_KEY]"

    assert RunPresentation.redact_text("ghr_12345678901234567890123456789012") =~
             "[REDACTED_API_KEY]"

    assert RunPresentation.redact_text("Bearer some-token-value-xyz") =~ "Bearer [REDACTED]"
    assert RunPresentation.redact_text("Basic dXNlcm5hbWU6cGFzc3dvcmQ=") =~ "Basic [REDACTED]"
    assert RunPresentation.redact_text("password=my_secret_pass") =~ "password=[REDACTED]"
    assert RunPresentation.redact_text("api_key = secret_value") =~ "api_key=[REDACTED]"

    # User and home directories
    assert RunPresentation.redact_text("/Users/alice/projects/shoestring/lib.ex") ==
             "/Users/[REDACTED]/projects/shoestring/lib.ex"

    assert RunPresentation.redact_text("/home/deployer/.config/app/secrets") ==
             "/home/[REDACTED]/.config/app/secrets"

    # XML thought tags
    assert RunPresentation.redact_text("<thought>Hidden model thoughts</thought>") =~
             "[REDACTED_REASONING]"

    # Payload sanitization: forbidden keys removed
    payload = %{
      "safe_field" => "Normal text",
      "reasoning" => "Hidden chain of thought that must not leak",
      "thinking" => "Another hidden reasoning trace",
      "scratchpad" => "Internal model scratchpad",
      "token" => "secret_token_12345",
      "path" => "/Users/eve/data/file.json",
      "nested" => %{
        "thought" => "Deep model thought",
        "nested_path" => "/home/ubuntu/key.pem"
      }
    }

    sanitized = RunPresentation.sanitize_payload(payload)

    refute Map.has_key?(sanitized, "reasoning")
    refute Map.has_key?(sanitized, "thinking")
    refute Map.has_key?(sanitized, "scratchpad")
    refute Map.has_key?(sanitized, "token")
    refute Map.has_key?(sanitized["nested"], "thought")

    assert sanitized["safe_field"] == "Normal text"
    assert sanitized["path"] == "/Users/[REDACTED]/data/file.json"
    assert sanitized["nested"]["nested_path"] == "/home/[REDACTED]/key.pem"
  end

  test "unit: evidence channels render redacted, not dropped (B4)", _ctx do
    payload = %{
      "stdout" => "build ok, token sk-ant-api03-abcdef1234567890abcdef123456 in /Users/bob/proj",
      "stderr" => "warning in /home/developer/app",
      "prompt" => "do the thing with ghp_123456789012345678901234567890123456",
      "transcript" => "assistant said hello from /Users/alice/work",
      "raw_output" => "result ok",
      "reasoning" => "PRIVATE_REASONING_MUST_NOT_RENDER",
      "raw_transcript" => "PRIVATE_RAW_TRANSCRIPT_MUST_NOT_RENDER"
    }

    sanitized = RunPresentation.sanitize_payload(payload)

    # Evidence stays visible, with secrets redacted inside the text.
    assert sanitized["stdout"] =~ "build ok"
    refute sanitized["stdout"] =~ "sk-ant-api03"
    assert sanitized["stdout"] =~ "[REDACTED_API_KEY]"
    refute sanitized["stdout"] =~ "/Users/bob"
    assert sanitized["stderr"] =~ "/home/[REDACTED]"
    assert sanitized["prompt"] =~ "[REDACTED_API_KEY]"
    assert sanitized["transcript"] =~ "/Users/[REDACTED]"
    assert sanitized["raw_output"] == "result ok"

    # Hidden reasoning stays stripped.
    refute Map.has_key?(sanitized, "reasoning")
    refute Map.has_key?(sanitized, "raw_transcript")
  end

  test "unit: pane cap applies after redaction with explicit notice (B5)", _ctx do
    big = String.duplicate("x", 40_000) <> " sk-ant-api03-abcdef1234567890abcdef123456"
    {visible, omitted, truncated?} = RunPresentation.cap_text(big)

    assert truncated?
    assert omitted > 0
    assert byte_size(visible) <= RunPresentation.pane_byte_cap() + 100
    assert visible =~ "truncated,"
    assert visible =~ "bytes omitted"
    refute visible =~ "sk-ant-api03"

    {small, 0, false} = RunPresentation.cap_text("hello")
    assert small == "hello"
  end

  test "unit: event window bounds DOM with showing X of Y (B5)", _ctx do
    events = Enum.to_list(1..250)
    {visible, total, showing, truncated?} = RunPresentation.window_events(events)

    assert total == 250
    assert showing == RunPresentation.max_rendered_events()
    assert truncated?
    assert length(visible) == RunPresentation.max_rendered_events()
    # First-N/last-N order preserved.
    assert hd(visible) == 1
    assert List.last(visible) == 250

    {all, 3, 3, false} = RunPresentation.window_events([1, 2, 3])
    assert length(all) == 3
  end

  test "render gate: no vendor credentials, tokens, home paths, or reasoning are rendered in UI",
       %{
         conn: conn,
         goal: goal,
         task: task,
         run: run
       } do
    # 1. Direct Repo.insert of raw event with secrets, home paths, and reasoning
    _leak_event =
      %TrajectoryEvent{
        id: Ecto.UUID.generate(),
        goal_id: goal.id,
        task_id: task.id,
        run_id: run.id,
        sequence: 1,
        schema_version: 1,
        type: "harness.event_recorded",
        actor: "elf",
        occurred_at: DateTime.utc_now(),
        idempotency_key: "evt-leak-1",
        payload: %{
          "run_id" => run.id,
          "source_event_id" => "evt-1",
          "ordinal" => 1,
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "kind" => "command",
          "reasoning" => "PRIVATE_REASONING_CHAIN_MUST_NEVER_APPEAR_ON_SCREEN",
          "thinking" => "PRIVATE_THINKING_TRACE_MUST_NEVER_APPEAR_ON_SCREEN",
          "scratchpad" => "MODEL_SCRATCHPAD_MUST_NEVER_BE_SHOWN",
          "error" => %{
            "message" =>
              "Exported sk-ant-api03-abcdef1234567890abcdef123456 and AKIA1234567890ABCDEF in /Users/bob/project",
            "code" => "error_code_1",
            "details" => %{
              "path" => "/home/developer/.ssh/id_rsa",
              "token" => "ghp_123456789012345678901234567890123456",
              "bearer" => "Bearer super-secret-bearer-token-12345"
            }
          }
        }
      }
      |> Repo.insert!()

    # 2. Persisted log artifact with paths and credentials
    log_content = """
    Starting execution in /Users/bob/workspace/run-1
    Loaded auth token: Bearer my-secret-log-token-xyz
    Using aws_secret_access_key=supersecretkey123
    Finished task in /home/developer/app
    """

    {:ok, artifact} =
      ArtifactStore.put(
        goal.id,
        log_content,
        %{media_type: "text/plain", redacted: true},
        task_id: task.id
      )

    log_event_attrs = %{
      "type" => "harness.event_recorded",
      "schema_version" => 1,
      "actor" => "elf",
      "occurred_at" => DateTime.utc_now(),
      "idempotency_key" => "elf-log:#{run.id}",
      "payload" => %{
        "run_id" => run.id,
        "source_event_id" => "elf-log:#{run.id}",
        "ordinal" => 2,
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "kind" => "artifact",
        "artifact_id" => artifact.id
      }
    }

    assert {:ok, _} =
             Trajectory.append(goal.id, log_event_attrs,
               trusted: [task_id: task.id, run_id: run.id]
             )

    # 3. Mount the LiveView and verify rendered HTML
    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    # Explicit assertions on rendered output
    rendered_html = render(view)

    # Credentials must NOT appear
    refute rendered_html =~ "sk-ant-api03"
    refute rendered_html =~ "AKIA1234567890ABCDEF"
    refute rendered_html =~ "ghp_12345678901234567890"
    refute rendered_html =~ "super-secret-bearer-token"
    refute rendered_html =~ "my-secret-log-token-xyz"
    refute rendered_html =~ "supersecretkey123"

    # Home paths must NOT appear
    refute rendered_html =~ "/Users/bob"
    refute rendered_html =~ "/home/developer"

    # Hidden reasoning / thinking / scratchpad must NOT appear
    refute rendered_html =~ "PRIVATE_REASONING_CHAIN_MUST_NEVER_APPEAR_ON_SCREEN"
    refute rendered_html =~ "PRIVATE_THINKING_TRACE_MUST_NEVER_APPEAR_ON_SCREEN"
    refute rendered_html =~ "MODEL_SCRATCHPAD_MUST_NEVER_BE_SHOWN"

    # Verify that redaction placeholders DO appear
    assert rendered_html =~ "[REDACTED"
    assert rendered_html =~ "/Users/[REDACTED]" or rendered_html =~ "/home/[REDACTED]"

    # Verify no Codex rollout session files are ever mentioned or loaded
    refute rendered_html =~ "rollout-"
    refute html =~ "rollout-"
  end

  test "render gate: stdout/transcript evidence displays redacted, reasoning stays hidden (B4)",
       %{
         conn: conn,
         goal: goal,
         task: task,
         run: run
       } do
    # Exercises the live-update render pipeline (handle_info ->
    # sanitize_event -> stream_insert -> format_payload), which is the path
    # where raw/legacy event payloads reach the template without passing
    # replay validation. Persisted-append is fail-closed against secrets, so
    # this pipeline is the UI redaction boundary that must keep evidence
    # visible (redacted) while stripping hidden reasoning.
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    live_event = %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      task_id: task.id,
      run_id: run.id,
      sequence: 99,
      schema_version: 1,
      type: "harness.event_recorded",
      actor: "elf",
      occurred_at: DateTime.utc_now(),
      idempotency_key: "evt-evidence-live-1",
      payload: %{
        "run_id" => run.id,
        "source_event_id" => "evt-evidence-1",
        "ordinal" => 1,
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "kind" => "command",
        "stdout" => "EVIDENCE_STDOUT_MARKER build ok in /Users/bob/proj",
        "transcript" => "EVIDENCE_TRANSCRIPT_MARKER hello",
        "reasoning" => "PRIVATE_EVIDENCE_REASONING_MUST_NOT_RENDER"
      }
    }

    send(view.pid, {:trajectory_event_committed, live_event})
    rendered_html = render(view)

    # Evidence markers survive redaction (visible, not dropped).
    assert rendered_html =~ "EVIDENCE_STDOUT_MARKER"
    assert rendered_html =~ "EVIDENCE_TRANSCRIPT_MARKER"
    # Secrets inside evidence are redacted, not leaked.
    refute rendered_html =~ "/Users/bob"
    # Hidden reasoning never renders.
    refute rendered_html =~ "PRIVATE_EVIDENCE_REASONING_MUST_NOT_RENDER"
  end

  test "render gate: oversized log artifact is capped with explicit notice (B5)",
       %{
         conn: conn,
         goal: goal,
         task: task,
         run: run
       } do
    big_content =
      String.duplicate("LOG_LINE_MARKER abcdefghij\n", 3000) <>
        " secret sk-ant-api03-abcdef1234567890abcdef123456 tail"

    {:ok, artifact} =
      ArtifactStore.put(
        goal.id,
        big_content,
        %{media_type: "text/plain", redacted: true},
        task_id: task.id
      )

    log_event_attrs = %{
      "type" => "harness.event_recorded",
      "schema_version" => 1,
      "actor" => "elf",
      "occurred_at" => DateTime.utc_now(),
      "idempotency_key" => "elf-log:#{run.id}",
      "payload" => %{
        "run_id" => run.id,
        "source_event_id" => "elf-log:#{run.id}",
        "ordinal" => 2,
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "kind" => "artifact",
        "artifact_id" => artifact.id
      }
    }

    assert {:ok, _} =
             Trajectory.append(goal.id, log_event_attrs,
               trusted: [task_id: task.id, run_id: run.id]
             )

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    rendered_html = render(view)

    assert has_element?(view, "#run-logs-truncated")
    assert rendered_html =~ "bytes omitted"
    # Cap applied after redaction: raw secret never appears, even truncated.
    refute rendered_html =~ "sk-ant-api03"
    # Bounded pane: raw 80KB+ artifact must not fully render.
    assert byte_size(rendered_html) < byte_size(big_content)
  end
end
