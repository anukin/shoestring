defmodule Shoestring.Elves.ClassifierTest do
  use ExUnit.Case, async: true

  alias Shoestring.Elves.Classifier
  alias Shoestring.Harness.Error

  test "normal exit: completed result with zero OS status completes" do
    assert %{class: :completed} =
             Classifier.classify({:result, "completed"}, {:exit_status, 0}, false)
  end

  test "completed adapter verdict wins over a ragged OS exit" do
    assert %{class: :completed} =
             Classifier.classify({:result, "completed"}, {:exit_status, 137}, false)
  end

  test "non-completed result statuses fail as task failures" do
    assert %{class: :failed, error_category: "task_failed", error_code: "result_failed"} =
             Classifier.classify({:result, "failed"}, {:exit_status, 0}, false)
  end

  test "quota refusal classifies distinctly from task failure" do
    error = Error.new(:quota_refused, "rate_limit_exceeded", "limit reached")

    assert %{class: :failed, error_category: "quota_refused", error_code: "rate_limit_exceeded"} =
             Classifier.classify({:error, error}, :unknown, false)
  end

  test "authentication failure classifies distinctly" do
    error = Error.new(:authentication_required, "login_required", "log in")

    assert %{class: :failed, error_category: "authentication_required"} =
             Classifier.classify({:error, error}, :unknown, false)
  end

  test "incompatible protocol (schema_incompatible) classifies distinctly" do
    error = Error.new(:schema_incompatible, "unknown_vendor_event", "degraded")

    assert %{class: :failed, error_category: "schema_incompatible"} =
             Classifier.classify({:error, error}, :unknown, false)
  end

  test "task failure error classifies as task failure" do
    error = Error.new(:task_failed, "tests_failed", "red")

    assert %{class: :failed, error_category: "task_failed", error_code: "tests_failed"} =
             Classifier.classify({:error, error}, :unknown, false)
  end

  test "cancellation always wins over concurrent exits and verdicts" do
    assert %{class: :cancelled} =
             Classifier.classify({:result, "completed"}, {:exit_status, 0}, true)

    assert %{class: :cancelled} = Classifier.classify(:no_verdict, {:exit_status, 1}, true)

    error = Error.new(:task_failed, "tests_failed", "red")
    assert %{class: :cancelled} = Classifier.classify({:error, error}, :unknown, true)
  end

  test "nonzero OS exit without an adapter verdict is a signal exit, not success" do
    assert %{class: :failed, error_category: "transport", error_code: "signal_exit_137"} =
             Classifier.classify(:no_verdict, {:exit_status, 137}, false)
  end

  test "zero OS exit without an adapter verdict fails closed without observed events" do
    # This assertion previously claimed `:completed` here — that was the
    # false-terminal defect from the live demo (a run that produced zero
    # adapter events reported successful). A launch that never observably
    # began must never be a completion.
    assert %{class: :failed, error_category: "transport", error_code: "no_adapter_events"} =
             Classifier.classify(:no_verdict, {:exit_status, 0}, false)
  end

  test "clean exit with zero observed adapter events is never completed" do
    assert %{class: :failed, error_category: "transport", error_code: "no_adapter_events"} =
             Classifier.classify(:no_verdict, {:exit_status, 0}, false, 0)
  end

  test "clean exit with observed adapter events stays deferred as completed" do
    # The genuinely ambiguous ending — events streamed, no explicit verdict —
    # remains orchestrator-facing recovery judgment, unchanged.
    assert %{class: :completed} = Classifier.classify(:no_verdict, {:exit_status, 0}, false, 1)

    assert %{class: :completed} = Classifier.classify(:no_verdict, {:exit_status, 0}, false, 42)
  end

  test "the observed-events variant delegates every other verdict shape" do
    assert %{class: :completed} =
             Classifier.classify({:result, "completed"}, {:exit_status, 0}, false, 0)

    assert %{class: :failed, error_code: "signal_exit_1"} =
             Classifier.classify(:no_verdict, {:exit_status, 1}, false, 9)

    assert %{class: :cancelled} = Classifier.classify(:no_verdict, {:exit_status, 0}, true, 9)
  end

  test "missing verdict with unknown exit fails explicitly, never silently" do
    assert %{class: :failed, error_code: "missing_terminal_verdict"} =
             Classifier.classify(:no_verdict, :unknown, false)
  end

  test "overflow, launch failure, and supervisor crash have stable codes" do
    assert %{class: :failed, error_code: "log_overflow"} = Classifier.overflow()
    assert %{class: :failed, error_code: "process_launch_failed"} = Classifier.launch_failed()

    assert %{class: :failed, error_code: "supervisor_crash"} = Classifier.supervisor_crash()
  end

  test "terminal maps to the run event type and payload the registry accepts" do
    run_id = Ecto.UUID.generate()

    assert Classifier.event_type(%{class: :completed}) == "run.completed"
    assert Classifier.event_type(%{class: :cancelled}) == "run.cancelled"
    assert Classifier.event_type(%{class: :failed}) == "run.failed"

    assert Classifier.event_payload(run_id, %{class: :completed}) == %{"run_id" => run_id}

    assert %{"run_id" => ^run_id, "error_category" => _, "error_code" => _} =
             Classifier.event_payload(run_id, Classifier.overflow())
  end
end
