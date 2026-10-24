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

  @types ["cobbler.plan.gate.started", "cobbler.plan.gate.output", "cobbler.plan.gate.completed"]

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

    output =
      for({"cobbler.plan.gate.output", p} <- events, do: p)
      |> Enum.group_by(& &1["invocation_id"])

    for({"cobbler.plan.gate.started", p} <- events, do: p)
    |> Enum.with_index(1)
    |> Enum.map(fn {started, number} ->
      %{
        number: number,
        started: started,
        completed: completed[started["invocation_id"]],
        output: Map.get(output, started["invocation_id"], [])
      }
    end)
  end

  @doc """
  Prints the list, or one invocation's output. Options: `:shell`, `:output`
  (an invocation number) and `:json`.

  As text, the list goes to stdout; with `:output`, stdout carries only the
  stored output bytes and the description goes to stderr, so the output can
  be redirected as it was recorded.
  """
  @spec show(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def show(goal_id, opts \\ []) do
    shell = Keyword.get(opts, :shell, Shoestring.CLI.Shell)
    json? = Keyword.get(opts, :json, false)
    invocations = invocations(goal_id)

    case Keyword.get(opts, :output) do
      nil when json? ->
        json(shell, %{goal_id: goal_id, checks: Enum.map(invocations, &data/1)})

      nil ->
        if invocations == [], do: shell.error("No checks recorded.")
        Enum.each(invocations, &shell.info(line(&1)))

      number ->
        with %{} = invocation <-
               Enum.find(invocations, &(&1.number == number)) || {:error, :no_such_check},
             {:ok, bytes, partial?} <- output(invocation, goal_id) do
          digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
          truncated? = invocation.completed["output_truncated"] == true

          if json? do
            {encoding, text} =
              if String.valid?(bytes),
                do: {"utf-8", bytes},
                else: {"base64", Base.encode64(bytes)}

            json(shell, %{
              goal_id: goal_id,
              check: data(invocation),
              output: text,
              encoding: encoding,
              bytes: byte_size(bytes),
              sha256: digest,
              partial: partial?,
              truncated: truncated?
            })
          else
            shell.error(line(invocation))
            label = if partial?, do: "Output so far", else: "Output"
            shell.error("#{label} (#{byte_size(bytes)} bytes, redacted, sha256 #{digest}):")
            shell.info(bytes)

            if partial?,
              do: shell.error("[partial output; no complete output artifact recorded]")

            if truncated?, do: shell.error("[cut at the output limit]")
          end

          :ok
        end
    end
  end

  defp json(shell, value) do
    shell.info(Jason.encode!(value, pretty: true))
    :ok
  end

  @doc false
  # One invocation as the `--json` shape documents it.
  def data(%{number: number, started: s, completed: c}) do
    %{
      number: number,
      scope: if(s["scope"] == "task", do: "task", else: "final"),
      plan_task_id: s["plan_task_id"],
      attempt: s["attempt"],
      gate: s["gate"],
      kind: s["kind"],
      required: s["required"] == true,
      spec: s["spec"],
      result: c && c["result"],
      exit_status: c && c["exit_status"],
      duration_ms: c && c["duration_ms"],
      commit: c && c["commit"]
    }
  end

  defp output(invocation, goal_id) do
    case get_in(invocation, [:completed, "artifact_id"]) do
      nil ->
        if invocation.output == [] do
          {:error, :no_output_recorded}
        else
          invocation.output
          |> Enum.with_index(1)
          |> Enum.reduce_while({:ok, "", true}, fn {chunk, number}, {:ok, bytes, true} ->
            with true <- chunk["chunk"] == number,
                 {:ok, part} <- read_output(chunk, goal_id) do
              {:cont, {:ok, bytes <> part, true}}
            else
              false -> {:halt, {:error, :gate_output_sequence_invalid}}
              error -> {:halt, error}
            end
          end)
        end

      _id ->
        with {:ok, bytes} <- read_output(invocation.completed, goal_id),
             do: {:ok, bytes, false}
    end
  end

  defp read_output(payload, goal_id) do
    with {:ok, %{bytes: bytes, artifact: artifact}} <- ArtifactStore.read(payload["artifact_id"]) do
      if artifact.goal_id == goal_id and artifact.sha256 == payload["output_sha256"] and
           artifact.byte_size == payload["output_bytes"] and artifact.redacted,
         do: {:ok, bytes},
         else: {:error, :gate_output_artifact_mismatch}
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
