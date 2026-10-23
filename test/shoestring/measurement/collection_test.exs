defmodule Shoestring.Measurement.CollectionTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Harness.Observatory
  alias Shoestring.Measurement.Collection
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 ~U[2026-10-23 18:00:00.000000Z]

  defp collection_events do
    goal_id = Observatory.observatory_goal_id()

    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type in ^Collection.event_types(),
        order_by: e.sequence
    )
  end

  test "one open window per provider and scope, recorded in the Observatory stream" do
    assert {:ok, opened} = Collection.open("codex", "subscription", "operator", now: @t0)
    assert opened.goal_id == Observatory.observatory_goal_id()
    assert opened.actor == "operator"
    assert opened.payload["attestation_version"] == 1

    assert {:error, :collection_window_already_open} =
             Collection.open("codex", "subscription", "operator", now: @t0)

    assert {:ok, _} = Collection.open("claude", "subscription", "operator", now: @t0)
    assert {:ok, _} = Collection.open("codex", "team", "operator", now: @t0)
    assert length(collection_events()) == 3

    assert [%{provider: "codex", scope: "subscription", closed_at: nil} | _] = Collection.list()
  end

  test "close ends the open window once and a later window can be opened" do
    t1 = DateTime.add(@t0, 600, :second)
    t2 = DateTime.add(@t0, 900, :second)
    {:ok, first} = Collection.open("codex", "subscription", "operator", now: @t0)

    assert {:ok, closed} =
             Collection.close("codex", "subscription", "external_use_reported", now: t1)

    assert closed.payload["window_id"] == first.payload["window_id"]

    assert {:error, :no_open_collection_window} =
             Collection.close("codex", "subscription", "operator_closed", now: t1)

    assert {:ok, second} = Collection.open("codex", "subscription", "operator", now: t2)
    refute second.payload["window_id"] == first.payload["window_id"]

    assert [
             %{close_reason: "external_use_reported", closed_at: ^t1},
             %{closed_at: nil, opened_at: ^t2}
           ] = Collection.list()
  end

  test "invalid providers, labels and reasons append nothing" do
    for {provider, scope, by} <- [
          {"openai", "subscription", "operator"},
          {"codex", "Has Space", "operator"},
          {"codex", "subscription", "someone@example.com"}
        ] do
      assert {:error, :invalid_collection_window} = Collection.open(provider, scope, by)
    end

    {:ok, _} = Collection.open("codex", "subscription", "operator", now: @t0)

    assert {:error, :invalid_close_reason} =
             Collection.close("codex", "subscription", "because I said so")

    assert length(collection_events()) == 1
  end

  test "window membership opens inclusively, closes exclusively, and ignores stray closes" do
    t1 = DateTime.add(@t0, 60, :second)

    events = [
      event(1, "measurement.collection.closed", %{
        "window_id" => "00000000-0000-4000-8000-0000000000ff",
        "closed_at" => DateTime.to_iso8601(@t0)
      }),
      event(2, "measurement.collection.opened", %{
        "window_id" => "00000000-0000-4000-8000-000000000001",
        "provider_id" => "codex",
        "scope" => "subscription",
        "attested_by" => "operator",
        "opened_at" => DateTime.to_iso8601(@t0)
      }),
      event(3, "measurement.collection.closed", %{
        "window_id" => "00000000-0000-4000-8000-000000000001",
        "reason" => "operator_closed",
        "closed_at" => DateTime.to_iso8601(t1)
      })
    ]

    windows = Collection.windows(events)
    assert [%{opened_at: @t0, closed_at: ^t1}] = windows
    assert Collection.open_at(windows, "codex", "subscription", @t0)
    assert Collection.open_at(windows, "codex", "subscription", DateTime.add(t1, -1, :second))
    refute Collection.open_at(windows, "codex", "subscription", t1)
    refute Collection.open_at(windows, "codex", "subscription", DateTime.add(@t0, -1, :second))
    refute Collection.open_at(windows, "claude", "subscription", @t0)
  end

  describe "mix shoestring.measurements collection" do
    setup do
      previous = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(previous) end)
    end

    test "open prints the attestation and requires it to be typed" do
      send(self(), {:mix_shell_input, :prompt, "yes"})

      assert_raise Mix.Error, ~r/attestation_not_confirmed/, fn ->
        Mix.Tasks.Shoestring.Measurements.run(~w(collection open --provider codex --by operator))
      end

      assert_receive {:mix_shell, :info, [statement]}
      assert statement =~ "no device, session or person other"
      assert collection_events() == []

      send(self(), {:mix_shell_input, :prompt, "I attest\n"})
      Mix.Tasks.Shoestring.Measurements.run(~w(collection open --provider codex --by operator))
      assert_receive {:mix_shell, :info, [_statement]}
      assert_receive {:mix_shell, :info, [json]}
      assert %{"provider_id" => "codex", "window_id" => _} = Jason.decode!(json)

      Mix.Tasks.Shoestring.Measurements.run(~w(collection close --provider codex))
      assert_receive {:mix_shell, :info, [closed]}
      assert %{"reason" => "operator_closed"} = Jason.decode!(closed)
      assert length(collection_events()) == 2
    end

    test "open without an operator label is refused before prompting" do
      assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
        Mix.Tasks.Shoestring.Measurements.run(~w(collection open --provider codex))
      end

      refute_received {:mix_shell, :prompt, _}
    end
  end

  defp event(sequence, type, payload) do
    %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: Observatory.observatory_goal_id(),
      sequence: sequence,
      type: type,
      payload: payload
    }
  end
end
