defmodule Shoestring.Cobbler.PlannerFixture do
  @moduledoc """
  Deterministic fixture planner for hermetic tests and offline use.

  The fixture never touches the network or a provider CLI. Its behaviour is
  fully scripted through the `:fixture` keyword passed to `plan/2`:

  - `%{plans: [map(), ...]}` — returns the entry for the current attempt
  # (`opts[:attempt]`, 1-based), so "invalid first, valid on repair" is
  # scripted as a two-entry list. An attempt past the end of the list is an
  # `invalid_response` error, never a silent repeat.
  - `%{errors: [reason, ...]}` — returns the error for the current attempt.
  - `%{plan: map()}` / `%{error: reason}` — repeats one outcome.
  - no `:fixture` — derives a valid two-task plan from the prompt's own
    goal, so the default path exercises the whole boundary with zero
    invention beyond the prompt.

  Every invocation sends `{:planner_call, prompt, attempt}` to the
  `:call_log` pid when one is given. Tests collect those messages to prove
  quota-blocked requests invoke zero times and bounded repair invokes at
  most twice. No test module is referenced here: the log is just a pid.

  `identity/0` is a fixed synthetic attribution. It never claims to be a
  provider model.
  """

  @behaviour Shoestring.Cobbler.PlannerAdapter

  @impl true
  @spec identity() :: %{identity: String.t(), version: String.t(), model: String.t()}
  def identity, do: %{identity: "fixture-planner", version: "1", model: "fixture-1"}

  @impl true
  @spec plan(map(), keyword()) ::
          {:ok, map()} | {:error, {:transport | :invalid_response | :refused, map()}}
  def plan(prompt, opts \\ []) when is_map(prompt) do
    log_call(opts, prompt)
    attempt = Keyword.get(opts, :attempt, 1)

    case Keyword.get(opts, :fixture, %{}) do
      %{plans: plans} when is_list(plans) ->
        case Enum.at(plans, attempt - 1) do
          nil -> {:error, {:invalid_response, %{"reason" => "fixture plan queue exhausted"}}}
          next -> {:ok, next}
        end

      %{errors: errors} when is_list(errors) ->
        case Enum.at(errors, attempt - 1) do
          nil -> {:error, {:transport, %{"reason" => "fixture error queue exhausted"}}}
          next -> {:error, next}
        end

      %{plan: plan} when is_map(plan) ->
        {:ok, plan}

      %{error: error} ->
        {:error, error}

      _other ->
        {:ok, derived_plan(prompt)}
    end
  end

  # A valid two-task plan derived from the prompt's own goal: the statement,
  # base revision, constraints, acceptance, and attribution all echo the
  # prompt, so the test proves the wiring end to end without inventing
  # repository facts the prompt never carried.
  defp derived_plan(prompt) do
    goal = Map.get(prompt, "goal", %{})
    repository = Map.get(goal, "repository", %{})
    planner = Map.get(prompt, "planner", %{})

    %{
      "version" => 1,
      "goal" => %{
        "statement" => Map.get(goal, "statement", "Fixture goal."),
        "repository" => %{
          "base_revision" => Map.get(repository, "base_revision", String.duplicate("0", 40))
        },
        "constraints" => Map.get(goal, "constraints", []),
        "non_goals" => Map.get(goal, "non_goals", []),
        "acceptance" =>
          Map.get(goal, "acceptance", %{
            "gates" => [%{"gate" => "mix_precommit"}],
            "evidence" => ["The gate passes."]
          })
      },
      "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 2_400},
      "tasks" => [
        %{
          "id" => "survey",
          "title" => "Survey the fixture goal",
          "outcome" => "The goal surface is recorded in the trajectory.",
          "acceptance_criteria" => ["The survey is recorded."],
          "gates" => [%{"gate" => "mix_precommit"}],
          "checkpoint" => %{
            "condition" => "The survey is recorded.",
            "evidence" => ["The trajectory event."]
          },
          "execution" => %{"max_attempts" => 2, "max_duration_seconds" => 1_200}
        },
        %{
          "id" => "verify",
          "title" => "Verify the fixture plan",
          "outcome" => "The plan validates against the contract.",
          "depends_on" => ["survey"],
          "acceptance_criteria" => ["The contract accepts the plan."],
          "gates" => [%{"gate" => "mix_precommit"}],
          "checkpoint" => %{
            "condition" => "Validation passed.",
            "evidence" => ["The validation result."]
          },
          "execution" => %{"max_attempts" => 2, "max_duration_seconds" => 1_200}
        }
      ],
      "planner" => %{
        "identity" => Map.get(planner, "identity", "fixture-planner"),
        "version" => Map.get(planner, "version", "1"),
        "source_context_refs" => source_refs(prompt)
      }
    }
  end

  defp source_refs(prompt) do
    prompt
    |> Map.get("context", [])
    |> Enum.map(&Map.get(&1, "ref", "fixture-ref"))
    |> Enum.take(16)
  end

  defp log_call(opts, prompt) do
    case Keyword.get(opts, :call_log) do
      pid when is_pid(pid) ->
        send(pid, {:planner_call, prompt, Keyword.get(opts, :attempt, 1)})
        :ok

      _other ->
        :ok
    end
  end
end
