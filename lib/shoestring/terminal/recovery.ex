defmodule Shoestring.Terminal.Recovery do
  @moduledoc "Startup-only reconciliation of lost interactive sessions. Never launches or resumes a provider."
  use GenServer
  require Logger
  import Ecto.Query
  alias Shoestring.{Elves, Repo, Trajectory}
  alias Shoestring.Harness.{Projector, RunRecord, SystemClock}
  alias Shoestring.Terminal.{Events, Session}
  alias Shoestring.Trajectory.TrajectoryEvent

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    # Complete reconciliation before Application starts Oban and durable
    # dispatch delivery. An asynchronous continuation could race a new Elf
    # against the lost-session checkpoint for the same run.
    if Application.get_env(:shoestring, :terminal_recovery, true) do
      for result <- reconcile(), not match?({:ok, _}, result) do
        Logger.error("Interactive terminal recovery could not persist a lost-session outcome")
      end
    end

    {:ok, nil}
  end

  def reconcile do
    Repo.all(
      from run in RunRecord,
        where:
          run.provider_id in ~w(fixture_interactive_pty claude_interactive_pty codex_interactive_pty),
        where: run.status in ~w(requested starting running pausing cancelling)
    )
    |> Enum.map(&reconcile_run/1)
  end

  def reconcile_run(run) do
    if live?(run.id) do
      {:ok, :live}
    else
      with {:ok, _} <- Projector.project(run.goal_id),
           %RunRecord{} = current <- Repo.get(RunRecord, run.id) do
        if current.status in ~w(starting running pausing cancelling),
          do: interrupt(current),
          else: {:ok, :unchanged}
      end
    end
  end

  defp interrupt(run) do
    with {:ok, request} <- Elves.request_from_run(run),
         {:ok, _} <-
           Events.append(
             request,
             "terminal.ownership.changed",
             %{"state" => "interrupted", "owner_ref" => owner_ref(run)},
             "terminal-recovery-owner:#{run.id}"
           ),
         {:ok, _} <- record_exit(run, request),
         state <-
           struct(Shoestring.Elves.Elf,
             request: request,
             repo: Repo,
             clock: SystemClock,
             run_id: run.id,
             goal_id: run.goal_id,
             task_id: run.task_id,
             dispatch_id: run.dispatch_id,
             provider_session_id: run.provider_session_id
           ),
         terminal <- %{
           class: :failed,
           error_category: "transport",
           error_code: "terminal_session_lost"
         },
         {:ok, _checkpoint_id} <- Shoestring.Elves.TerminalCheckpoint.record(state, terminal),
         {:ok, _} <-
           Trajectory.append(
             run.goal_id,
             %{
               "type" => "run.failed",
               "schema_version" => 1,
               "actor" => "system",
               "idempotency_key" => "elf-terminal:#{run.dispatch_id}",
               "payload" => %{
                 "run_id" => run.id,
                 "error_category" => "transport",
                 "error_code" => "terminal_session_lost"
               }
             },
             trusted: [task_id: run.task_id, run_id: run.id]
           ),
         {:ok, _} <- Projector.project(run.goal_id) do
      {:ok, :reconciled}
    end
  end

  defp live?(run_id) do
    Session.lookup(run_id) != nil or
      (:ets.whereis(Shoestring.Elves.Registry) != :undefined and Elves.whereis(run_id) != nil)
  end

  # A helper can report its outcome just before the application stops, before
  # the Elf writes its checkpoint. Preserve that fact and complete recovery.
  defp record_exit(run, request) do
    case Repo.one(
           from event in TrajectoryEvent,
             where:
               event.goal_id == ^run.goal_id and event.run_id == ^run.id and
                 event.type == "terminal.session.exited",
             limit: 1
         ) do
      nil ->
        Events.append(
          request,
          "terminal.session.exited",
          %{"reason" => "application_restart"},
          "terminal-exit:#{run.id}"
        )

      event ->
        {:ok, event}
    end
  end

  defp owner_ref(run) do
    Repo.one(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and event.run_id == ^run.id and
            event.type == "terminal.ownership.changed",
        order_by: [desc: event.sequence],
        limit: 1,
        select: fragment("? ->> 'owner_ref'", event.payload)
    ) || "none"
  end
end
