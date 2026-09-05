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
    assert RunPresentation.redact_text("github_pat_1234567890abcdef") =~ "[REDACTED_API_KEY]"
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
end
