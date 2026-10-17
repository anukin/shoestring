defmodule Shoestring.CLI.Checks do
  @moduledoc """
  `shoestring checks GOAL`: every gate invocation recorded for a goal, in
  the order it ran, with its specification, exact result and the commit it
  verified; `--output N` prints the stored output of invocation N.

  It reads the recorded `cobbler.plan.gate.*` events and output artifacts
  only; nothing runs.
  """

  import Ecto.Query

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{ArtifactStore, TrajectoryEvent}

  @types ["cobbler.plan.gate.started", "cobbler.plan.gate.completed"]

  @doc """
  The goal's invocations, oldest first: maps with `:number`, `:started`
  (payload) and `:completed` (payload or `nil` when none was recorded).
  """
  @spec invocations(Ecto.UUID.t()) :: [map()]
  def invocations(goal_id) do
    events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type in ^@types,
          order_by: [asc: e.sequence],
          select: {e.type, e.payload}
      )

    completed =
      for {"cobbler.plan.gate.completed", p} <- events, into: %{}, do: {p["invocation_id"], p}

    for({"cobbler.plan.gate.started", p} <- events, do: p)
    |> Enum.with_index(1)
    |> Enum.map(fn {started, number} ->
      %{number: number, started: started, completed: completed[started["invocation_id"]]}
    end)
  end

  @doc "Prints the list, or one invocation's output. Options: `:shell`, `:output`."
  @spec show(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def show(goal_id, opts \\ []) do
    shell = Keyword.get(opts, :shell, Mix.shell())
    invocations = invocations(goal_id)

    case Keyword.get(opts, :output) do
      nil ->
        if invocations == [], do: shell.info("No checks recorded.")
        Enum.each(invocations, &shell.info(line(&1)))

      number ->
        with %{} = invocation <-
               Enum.find(invocations, &(&1.number == number)) || {:error, :no_such_check},
             id when is_binary(id) <-
               get_in(invocation, [:completed, "artifact_id"]) || {:error, :no_output_recorded},
             {:ok, %{bytes: bytes, artifact: artifact}} <- ArtifactStore.read(id) do
          shell.info(line(invocation))
          shell.info("Output (#{artifact.byte_size} bytes, redacted, sha256 #{artifact.sha256}):")
          shell.info(bytes)
          if invocation.completed["output_truncated"], do: shell.info("[cut at the output limit]")
          :ok
        end
    end
  end

  @doc false
  def line(%{number: number, started: s, completed: c}) do
    where =
      case s["scope"] do
        "task" -> "task #{s["plan_task_id"]} attempt #{s["attempt"]}"
        _ -> "final"
      end

    class = "#{s["kind"]}, #{if s["required"], do: "required", else: "optional"}"

    ending =
      case c do
        nil ->
          "no completion recorded"

        c ->
          exit = if is_integer(c["exit_status"]), do: " exit #{c["exit_status"]}", else: ""
          at = if c["commit"], do: " at #{String.slice(c["commit"], 0, 12)}", else: ""
          "#{c["result"]}#{exit} in #{c["duration_ms"]} ms#{at}"
      end

    "#{number}. #{where}: #{s["gate"]} (#{class}) -> #{ending}\n   spec #{s["spec"]}"
  end
end
