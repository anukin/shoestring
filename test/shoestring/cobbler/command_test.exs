defmodule Shoestring.Cobbler.CommandTest do
  @moduledoc """
  Hermetic tests for the pure command model: validation, digest stability,
  and the legal transition table. No database, no processes.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.Command

  @claim_attrs %{
    "command_id" => "cmd-01950000-0000-7000-8000-000000000001",
    "type" => "task.claim",
    "payload" => %{
      "intent" => "supervised_execution",
      "scope" => "account:codex",
      "candidate" => %{"provider_id" => "codex", "adapter_id" => "codex_app_server"},
      "admission_event_id" => "01950000-0000-7000-8000-0000000000aa"
    }
  }

  describe "new/1 validation" do
    test "accepts a normalized task.claim command" do
      {:ok, command} = Command.new(@claim_attrs)

      assert command.version == 1
      assert command.command_id == "cmd-01950000-0000-7000-8000-000000000001"
      assert command.type == "task.claim"
      assert command.payload["intent"] == "supervised_execution"
      assert command.payload["candidate"]["provider_id"] == "codex"
      assert String.length(command.digest) == 64
    end

    test "generates a command id when the caller omits one" do
      {:ok, command} =
        Command.new(%{"type" => "task.release", "payload" => %{"reason" => "done"}})

      assert String.starts_with?(command.command_id, "cmd-")
    end

    test "rejects an unknown command type" do
      {:error, changeset} = Command.new(%{"type" => "task.execute", "payload" => %{}})

      assert errors_on(changeset)[:type] == ["must be one of task.claim, task.release"]
    end

    test "rejects a task.claim payload with a missing field" do
      attrs =
        @claim_attrs
        |> put_in(["payload", "intent"], nil)

      {:error, changeset} = Command.new(attrs)

      assert errors_on(changeset)[:intent] == ["can't be blank"]
    end

    test "rejects a non-UUID admission_event_id" do
      attrs = put_in(@claim_attrs, ["payload", "admission_event_id"], "not-a-uuid")

      {:error, changeset} = Command.new(attrs)

      assert errors_on(changeset)[:admission_event_id] == ["must be a UUID"]
    end

    test "rejects a task.release payload without a reason" do
      {:error, changeset} = Command.new(%{"type" => "task.release", "payload" => %{}})

      assert errors_on(changeset)[:reason] == ["can't be blank"]
    end

    test "rejects a blank command id" do
      {:error, changeset} = Command.new(Map.put(@claim_attrs, "command_id", "   "))

      assert errors_on(changeset)[:command_id] == ["can't be blank"]
    end

    test "rejects a non-map input" do
      {:error, changeset} = Command.new("task.claim")

      assert errors_on(changeset)[:base] == ["must be an object"]
    end
  end

  describe "digest/2" do
    test "is identical for the same type and payload in any key order" do
      {:ok, command} = Command.new(@claim_attrs)

      reordered_payload = %{
        "admission_event_id" => "01950000-0000-7000-8000-0000000000aa",
        "candidate" => %{"adapter_id" => "codex_app_server", "provider_id" => "codex"},
        "scope" => "account:codex",
        "intent" => "supervised_execution"
      }

      assert Command.digest("task.claim", reordered_payload) == command.digest
    end

    test "changes when the payload changes, so conflicting reuse is detectable" do
      {:ok, command} = Command.new(@claim_attrs)

      changed = put_in(@claim_attrs, ["payload", "scope"], "account:claude")

      {:ok, other} = Command.new(changed)

      assert other.digest != command.digest
    end

    test "response_digest separates distinct responses" do
      assert Command.response_digest(%{"resolution" => "abandon"}) !=
               Command.response_digest(%{"resolution" => "release"})
    end
  end

  describe "transition/3 legal table" do
    test "pending accepts needs_user, resolved, and rejected" do
      assert Command.transition(:pending, :accept, :needs_user) == :ok
      assert Command.transition(:pending, :accept, :resolved) == :ok
      assert Command.transition(:pending, :accept, :rejected) == :ok
    end

    test "needs_user resolves through a response" do
      assert Command.transition(:needs_user, :respond, :resolved) == :ok
      assert Command.transition(:needs_user, :respond, :rejected) == :ok
    end

    test "terminal states accept no transitions" do
      assert {:error, {:invalid_transition, :resolved, :resolved}} =
               Command.transition(:resolved, :accept, :resolved)

      assert {:error, {:invalid_transition, :rejected, :resolved}} =
               Command.transition(:rejected, :respond, :resolved)

      assert {:error, {:invalid_transition, :resolved, :needs_user}} =
               Command.transition(:resolved, :respond, :needs_user)

      assert {:error, {:invalid_transition, :rejected, :rejected}} =
               Command.transition(:rejected, :accept, :rejected)
    end

    test "accept cannot run on needs_user and respond cannot run on pending" do
      assert {:error, {:invalid_transition, :needs_user, :resolved}} =
               Command.transition(:needs_user, :accept, :resolved)

      assert {:error, {:invalid_transition, :pending, :resolved}} =
               Command.transition(:pending, :respond, :resolved)
    end

    test "accepts persisted string statuses" do
      assert Command.transition("needs_user", :respond, "resolved") == :ok

      assert {:error, {:invalid_transition, :resolved, :resolved}} =
               Command.transition("resolved", :accept, "resolved")
    end
  end

  describe "terminal?/1 and status mapping" do
    test "only resolved and rejected are terminal" do
      assert Command.terminal?(:resolved)
      assert Command.terminal?(:rejected)
      assert Command.terminal?("resolved")
      refute Command.terminal?(:pending)
      refute Command.terminal?(:needs_user)
      refute Command.terminal?("needs_user")
      refute Command.terminal?(:nonsense)
    end

    test "status_atom and status_string round-trip persisted statuses" do
      for status <- Command.statuses() do
        assert Command.status_atom(Atom.to_string(status)) == status
        assert Command.status_string(status) == Atom.to_string(status)
      end

      assert Command.status_atom("mystery") == nil
      assert Command.status_string(:mystery) == nil
    end
  end

  describe "recoverable needs_user contract" do
    test "claim_held offers exactly the abandon option with a mapped outcome" do
      assert Command.response_options("claim_held") == ["abandon"]
      assert Command.resolution("claim_held", "abandon") == {:ok, "abandoned"}
    end

    test "unoffered options and unknown reasons are invalid responses" do
      assert {:error, :invalid_response} = Command.resolution("claim_held", "proceed")
      assert {:error, :invalid_response} = Command.resolution("mystery", "abandon")
      assert Command.response_options("mystery") == []
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
