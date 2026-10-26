defmodule Shoestring.AdviceStoreTest do
  @moduledoc "Advice reads token-bearing harness events from the trajectory store. No provider runs."
  use Shoestring.DataCase, async: false

  alias Shoestring.{Advice, Repo, Trajectory}
  alias Shoestring.Harness.{CodexAppServer, EventPayload}

  test "the store query finds Codex running totals and completions, and nothing else" do
    goal = Shoestring.Test.CobblerHelpers.create_goal!()
    run_id = Ecto.UUID.generate()

    frame = %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{
        "threadId" => "thread-1",
        "turnId" => "turn-1",
        "tokenUsage" => %{
          "total" => %{"totalTokens" => 321},
          "last" => %{},
          "modelContextWindow" => 1
        }
      }
    }

    {:ok, tokens} = CodexAppServer.EventNormalizer.normalize(frame, run_id, 1)

    {:ok, other} =
      CodexAppServer.EventNormalizer.normalize(
        %{
          "method" => "turn/started",
          "params" => %{"threadId" => "thread-1", "turn" => %{"id" => "turn-1"}}
        },
        run_id,
        2
      )

    for event <- [tokens, other] do
      {:ok, _} =
        Trajectory.append(goal.id, %{
          type: "harness.event_recorded",
          schema_version: 1,
          actor: "harness",
          occurred_at: DateTime.utc_now(),
          idempotency_key: "advice-store-#{event.ordinal}",
          payload: EventPayload.harness_event(event)
        })
    end

    assert [%{"run_id" => ^run_id, "extensions" => %{"codex-app-server:token_usage" => _}}] =
             Advice.token_payloads(Repo)

    assert Advice.report(Repo) == []
  end
end
