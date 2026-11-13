defmodule Shoestring.Test.DecisionHelpers do
  @moduledoc """
  Hermetic fixtures for decision points (iteration 19): a two-task plan whose
  first task declares a decision, synthetic solid-colour PNG candidates
  written into a directory that stands in for the task's worktree, and
  executor options with an injected gate runner (no OS process).
  """
  import ExUnit.Assertions

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Test.{PlanExecutorHelpers, PlanFixtures}

  @colours [{"red", {255, 0, 0}}, {"green", {0, 160, 0}}, {"blue", {0, 0, 255}}]

  def decision(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "sheet",
        "question" => "Which reference sheet should the story use?",
        "min_options" => 2,
        "max_options" => 12,
        "allow_reject" => true
      },
      overrides
    )
  end

  def decision_plan(decision \\ decision()) do
    PlanExecutorHelpers.chain_plan(%{
      "tasks" => [
        PlanFixtures.task("sheets", "Draw three reference sheets", [], %{
          "expected_artifacts" => [PlanContract.decision_file(decision["id"])],
          "decision" => decision
        }),
        PlanFixtures.task("story", "Use the chosen sheet", ["sheets"])
      ]
    })
  end

  @doc "A valid 1x1 PNG of one colour: a few dozen bytes."
  def png({r, g, b}) do
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk.("IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>) <>
      chunk.("IDAT", :zlib.compress(<<0, r, g, b>>)) <> chunk.("IEND", "")
  end

  @doc """
  Writes candidates and `decision.json` under `.shoestring/decisions/sheet/`.
  Options: `:colours` (`[{key, {r, g, b}}]`), `:file` (the decision file's
  content, replacing the generated one). Returns the generated options.
  """
  def write_candidates!(worktree, opts \\ []) do
    dir = Path.join(worktree, ".shoestring/decisions/sheet")
    File.mkdir_p!(dir)

    options =
      for {name, rgb} <- Keyword.get(opts, :colours, @colours) do
        File.write!(Path.join(dir, "#{name}.png"), png(rgb))

        %{
          "key" => name,
          "label" => "A #{name} sheet",
          "file" => ".shoestring/decisions/sheet/#{name}.png",
          "media_type" => "image/png"
        }
      end

    file =
      Keyword.get(opts, :file, %{"id" => "sheet", "options" => options, "note" => "Three takes."})

    File.write!(Path.join(dir, "decision.json"), Jason.encode!(file))
    options
  end

  @doc "Executor options whose injected gates run at `worktree`."
  def opts(worktree, extra \\ []) do
    PlanExecutorHelpers.exec_opts(
      Keyword.merge(
        [
          gate_runner_opts: Keyword.put(PlanExecutorHelpers.gate_opts(), :worktree_path, worktree)
        ],
        extra
      )
    )
  end

  @doc """
  Approves `plan`, requests execution, dispatches the deciding task, ends its
  run and records its gates. Returns the completion result plus `:run_id`.
  Options: `:repository_path` for the execution request.
  """
  def run_sheets!(goal, worktree, plan \\ decision_plan(), request_opts \\ []) do
    rev = PlanExecutorHelpers.propose_and_approve!(goal, plan)
    admission = PlanExecutorHelpers.admit!(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               Map.merge(
                 %{
                   revision_number: rev.revision_number,
                   digest: rev.digest,
                   admission_event_id: admission.id
                 },
                 Map.new(request_opts)
               ),
               opts(worktree)
             )

    assert {:ok, %{disposition: :dispatched, plan_task_id: "sheets"} = first} =
             Cobbler.advance_plan_execution(
               goal.id,
               opts(worktree, admission_event_id: admission.id)
             )

    PlanExecutorHelpers.complete_run!(goal, first.run_id)
    assert {:ok, result} = Cobbler.complete_plan_task_run(goal.id, first.run_id, opts(worktree))
    Map.put(result, :run_id, first.run_id)
  end
end
