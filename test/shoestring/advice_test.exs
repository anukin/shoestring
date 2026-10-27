defmodule Shoestring.AdviceTest do
  @moduledoc """
  Advice is plain statistics over finished runs. Run histories are synthetic
  event maps; token payloads come from the real Codex, Claude and opencode
  normalizers. No provider runs.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Advice
  alias Shoestring.Harness.EventPayload
  alias Shoestring.Harness.{ClaudeHeadless, CodexAppServer, OpencodeAcp}

  @t0 ~U[2026-10-20 12:00:00.000000Z]

  defp binding(harness, model, effort \\ nil) do
    %{"provider" => harness, "model" => model}
    |> then(&if(effort, do: Map.put(&1, "effort", effort), else: &1))
  end

  # One finished run: requested, running for `seconds`, then ended; its task
  # dispatched at `attempt`, and accepted when `accepted`.
  defp run(binding, opts) do
    run_id = Ecto.UUID.generate()
    goal_id = Keyword.get(opts, :goal_id, Ecto.UUID.generate())
    task_id = Keyword.get(opts, :task_id, "dispatch")
    attempt = Keyword.get(opts, :attempt, 1)
    start = DateTime.add(@t0, Keyword.get(opts, :at, 0) * 60)
    finish = DateTime.add(start, Keyword.get(opts, :seconds, 60))
    execution_id = Keyword.get(opts, :execution_id, "e-#{goal_id}")

    dispatched = %{
      "run_id" => run_id,
      "plan_task_id" => task_id,
      "attempt" => attempt,
      "execution_id" => execution_id,
      "revision_number" => 1
    }

    events =
      [
        %{
          type: "run.requested",
          payload: %{"run_id" => run_id, "extensions" => %{"shoestring.agent:binding" => binding}},
          at: start
        },
        %{type: "cobbler.plan.task.dispatched", payload: dispatched, at: start},
        %{type: "run.running", payload: %{"run_id" => run_id}, at: start},
        %{
          type: Keyword.get(opts, :end, "run.completed"),
          payload: %{"run_id" => run_id},
          at: finish
        }
      ] ++
        if(Keyword.get(opts, :accepted, true),
          do: [%{type: "cobbler.plan.task.accepted", payload: dispatched, at: finish}],
          else: []
        )

    {run_id,
     Enum.map(
       events,
       &%{type: &1.type, goal_id: goal_id, payload: &1.payload, occurred_at: &1.at}
     )}
  end

  defp codex_tokens(run_id, total) do
    frame = %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{
        "threadId" => "thread-1",
        "turnId" => "turn-1",
        "tokenUsage" => %{
          "total" => %{"totalTokens" => total, "inputTokens" => total - 10, "outputTokens" => 10},
          "last" => %{"totalTokens" => total},
          "modelContextWindow" => 200_000
        }
      }
    }

    {:ok, event} = CodexAppServer.EventNormalizer.normalize(frame, run_id, 1)
    EventPayload.harness_event(event)
  end

  defp claude_tokens(run_id, usage) do
    frame = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "terminal_reason" => "completed",
      "session_id" => "00000000-0000-4000-8000-000000000009",
      "usage" => usage
    }

    {:ok, [event]} = ClaudeHeadless.EventNormalizer.normalize(frame, run_id, 1, %{})
    EventPayload.harness_event(event)
  end

  defp opencode_tokens(run_id, input, output) do
    {:ok, event} =
      OpencodeAcp.EventNormalizer.prompt_outcome(
        {:ok,
         %{
           "stopReason" => "end_turn",
           "usage" => %{"inputTokens" => input, "outputTokens" => output}
         }},
        run_id,
        1,
        %{}
      )

    EventPayload.harness_event(event)
  end

  defp revisions(gates),
    do: fn _goal, 1 -> %{"tasks" => [%{"id" => "dispatch", "gates" => gates}]} end

  test "a kind with fewer than 10 finished runs has no estimate, only its count" do
    runs = for i <- 1..3, do: run(binding("codex", "gpt-6-luna"), at: i)

    [advice] =
      Advice.build(
        Enum.flat_map(runs, &elem(&1, 1)),
        [],
        %{},
        revisions([%{"gate" => "mix_test"}])
      )

    assert advice["runs"] == 3
    assert advice["estimate"] == nil
    assert advice["note"] == "no estimate yet (3 of 10 runs)"

    assert advice["kind"] == %{
             "harness" => "codex",
             "model" => "gpt-6-luna",
             "effort" => nil,
             "purpose" => "implement",
             "task_class" => "gates:mix_test"
           }
  end

  test "with enough runs: token median and 90th percentile, first-try rate, attempts, duration" do
    luna = binding("codex", "gpt-6-luna", "high")

    # Ten tasks first-tried; tasks 9 and 10 failed and took a second attempt.
    first =
      for i <- 1..10 do
        run(luna,
          goal_id: "g#{i}",
          at: i,
          seconds: i * 10,
          accepted: i <= 8,
          end: if(i <= 8, do: "run.completed", else: "run.failed")
        )
      end

    second = for i <- 9..10, do: run(luna, goal_id: "g#{i}", attempt: 2, at: 20 + i, seconds: 30)
    runs = first ++ second
    tokens = for {{run_id, _}, i} <- Enum.with_index(runs, 1), do: codex_tokens(run_id, i * 100)

    [advice] =
      Advice.build(
        Enum.flat_map(runs, &elem(&1, 1)),
        tokens,
        %{},
        revisions([%{"gate" => "mix_test"}])
      )

    assert advice["runs"] == 12
    assert advice["from"] == DateTime.add(@t0, 1 * 60 + 10)

    assert advice["estimate"] == %{
             "tokens" => %{"median" => 600, "p90" => 1100, "runs" => 12},
             "runs_without_tokens" => 0,
             "first_try_pass_rate" => %{"passed" => 8, "of" => 10},
             "mean_attempts" => 1.2,
             "median_duration_ms" => 40_000,
             "usage_share" => nil,
             "runs_without_usage_share" => 12
           }
  end

  test "the usage share is per window length, over attributable runs only, never zero-filled" do
    luna = binding("codex", "gpt-6-luna", "high")
    runs = for i <- 1..12, do: run(luna, at: i)
    [first, second | _] = run_ids = Enum.map(runs, &elem(&1, 0))

    shares =
      run_ids
      |> Enum.take(10)
      |> Enum.with_index(1)
      |> Map.new(fn {run_id, i} -> {run_id, %{"percent" => i, "window_minutes" => 300}} end)
      # A share of another window length is reported apart.
      |> Map.put(first, %{"percent" => 1, "window_minutes" => 10_080})
      |> Map.delete(second)

    [advice] =
      Advice.build(
        Enum.flat_map(runs, &elem(&1, 1)),
        [],
        %{},
        revisions([%{"gate" => "mix_test"}]),
        {:ok, shares}
      )

    assert advice["estimate"]["usage_share"] == [
             %{"window_minutes" => 300, "median_percent" => 6, "p90_percent" => 10, "runs" => 8},
             %{"window_minutes" => 10_080, "median_percent" => 1, "p90_percent" => 1, "runs" => 1}
           ]

    assert advice["estimate"]["runs_without_usage_share"] == 3
    refute Map.has_key?(advice["estimate"], "usage_share_unavailable")

    [advice] =
      Advice.build(
        Enum.flat_map(runs, &elem(&1, 1)),
        [],
        %{},
        revisions([%{"gate" => "mix_test"}]),
        {:error, :measurement_event_limit}
      )

    assert %{
             "usage_share" => nil,
             "runs_without_usage_share" => 12,
             "usage_share_unavailable" => "measurement_event_limit"
           } = advice["estimate"]
  end

  test "Claude counts cache reads and writes; a run without usage is counted apart, never as zero" do
    opus = binding("claude", "opus")
    runs = for i <- 1..11, do: run(opus, at: i)

    tokens =
      for {{run_id, _}, i} <- Enum.with_index(runs, 1), i <= 10 do
        claude_tokens(run_id, %{
          "input_tokens" => 4,
          "output_tokens" => 96,
          "cache_read_input_tokens" => i * 100,
          "cache_creation_input_tokens" => 0
        })
      end

    [advice] =
      Advice.build(
        Enum.flat_map(runs, &elem(&1, 1)),
        tokens,
        %{},
        revisions([%{"gate" => "mix_test"}])
      )

    assert %{"tokens" => %{"median" => 600, "runs" => 10}, "runs_without_tokens" => 1} =
             advice["estimate"]
  end

  test "opencode's completion usage, and kinds split by model, purpose and task class" do
    glm = binding("opencode", "opencode/glm-5")
    {run_id, events} = run(glm, goal_id: "dispatched-goal")
    {other_id, other} = run(binding("opencode", "opencode/kimi"), at: 2)
    {_, mix} = run(glm, at: 3)

    advice =
      Advice.build(
        events ++ other ++ mix,
        [opencode_tokens(run_id, 900, 100), opencode_tokens(other_id, 1, 1)],
        %{"dispatched-goal" => "explore"},
        fn
          "dispatched-goal", 1 ->
            %{"tasks" => [%{"id" => "dispatch", "gates" => [%{"gate" => "python_unittest"}]}]}

          _goal, 1 ->
            %{
              "tasks" => [
                %{
                  "id" => "dispatch",
                  "gates" => [%{"gate" => "mix_test"}, %{"gate" => "mix_format_check"}]
                }
              ]
            }
        end
      )

    assert length(advice) == 3

    assert Enum.find(advice, &(&1["kind"]["purpose"] == "explore"))["kind"]["task_class"] ==
             "gates:python_unittest"

    assert Enum.find(
             advice,
             &(&1["kind"]["model"] == "opencode/glm-5" and &1["kind"]["purpose"] == "implement")
           )["kind"]["task_class"] ==
             "gates:mix_format_check,mix_test"

    # Advice is only shown for kinds with enough runs; the token total is still derived.
    assert Advice.build(events, [opencode_tokens(run_id, 900, 100)], %{}, revisions([]))
           |> hd()
           |> Map.fetch!("runs") == 1
  end

  test "percentiles are nearest-rank" do
    assert Advice.percentile(Enum.to_list(1..10), 90) == 9
    assert Advice.percentile(Enum.to_list(1..10), 100) == 10
    assert Advice.median([4, 1, 3, 2]) == 2
    assert Advice.median([7]) == 7
  end
end
