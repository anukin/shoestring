defmodule Shoestring.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Shoestring.State.ensure_writable_root!()
    Shoestring.State.configure_repo!()

    if Application.get_env(:shoestring, :environment) == :prod do
      secret =
        Shoestring.Release.Bootstrap.endpoint_secret!(
          Shoestring.State.root(),
          System.get_env("SECRET_KEY_BASE")
        )

      endpoint = Application.fetch_env!(:shoestring, ShoestringWeb.Endpoint)

      Application.put_env(
        :shoestring,
        ShoestringWeb.Endpoint,
        Keyword.put(endpoint, :secret_key_base, secret)
      )
    end

    children =
      [
        ShoestringWeb.Telemetry,
        Shoestring.Repo,
        Shoestring.Harness.SessionTables,
        Shoestring.Harness.HTTP.Supervisor,
        Shoestring.Cobbler.ReservationWriter,
        {Task.Supervisor, name: Shoestring.Cobbler.PlannerTasks},
        {Task.Supervisor, name: Shoestring.Cobbler.GateOutputTasks},
        {Registry, keys: :unique, name: Shoestring.Trajectory.WriterRegistry},
        Shoestring.Trajectory.WriterSupervisor,
        {Phoenix.PubSub, name: Shoestring.PubSub},
        Shoestring.Coordinator.ToolTokens,
        {Registry, keys: :unique, name: Shoestring.Conversations.Registry},
        {DynamicSupervisor, name: Shoestring.Conversations.Supervisor, strategy: :one_for_one},
        Shoestring.Terminal.Supervisor,
        {Oban, Application.fetch_env!(:shoestring, Oban)}
      ] ++
        dispatch_reconciler_children() ++
        wakeup_reconciler_children() ++
        handoff_reconciler_children() ++
        capacity_supervisor_children() ++
        elves_children() ++
        plan_execution_reconciler_children() ++
        reservation_control_reconciler_children() ++
        plan_child_inbox_reconciler_children() ++
        model_catalog_children() ++
        [
          {DNSCluster, query: Application.get_env(:shoestring, :dns_cluster_query) || :ignore},
          ShoestringWeb.Endpoint
        ] ++
        conversation_resume_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Shoestring.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      if Phoenix.Endpoint.server?(:shoestring, ShoestringWeb.Endpoint),
        do: Shoestring.Banner.print(ShoestringWeb.Endpoint.url())

      {:ok, pid}
    end
  end

  # Engines of conversations whose session still has a grant, so a dispatch
  # that settles with no client attached still wakes the coordinator.
  # Disabled in test via `:conversation_resume`.
  defp conversation_resume_children do
    if Application.get_env(:shoestring, :conversation_resume, true),
      do: [Shoestring.Conversations.Resume],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ShoestringWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp capacity_supervisor_children do
    # The capacity supervisor is always present so monitors stay independently
    # addressable. In the test environment both providers are disabled via
    # config, so it boots empty: no monitor auto-starts and no provider CLI
    # is ever invoked.
    #
    # `:transient` (matching `Capacity.Supervisor.child_spec/1`): when a
    # crash-looping monitor exhausts the capacity supervisor's restart
    # intensity, it exits with the bare reason `:shutdown` (OTP reports
    # `:reached_max_restart_intensity` only in its log report, never in the
    # exit term), which a `:transient` child does NOT restart. The outage
    # stops there instead of storming the root supervisor (which would take
    # down the Endpoint, Repo, and healthy provider with it).
    #
    # ORDER IS LOAD-BEARING (DEF-01b): the exhaustion watcher MUST remain
    # listed after the capacity supervisor. OTP terminates children in reverse
    # start order, so a graceful application shutdown terminates the watcher
    # BEFORE the capacity supervisor and the watcher never observes the
    # graceful `:shutdown` exit (no false alarm on clean shutdowns or
    # redeploys). On genuine intensity exhaustion only the capacity supervisor
    # dies while the watcher survives and emits the observable signal.
    [
      Supervisor.child_spec(Shoestring.Harness.Capacity.Supervisor, restart: :transient),
      Shoestring.Harness.Capacity.SupervisionWatcher
    ]
  end

  defp dispatch_reconciler_children do
    if Application.get_env(:shoestring, :dispatch_reconciler, true) do
      [Shoestring.Harness.Dispatch.Reconciler]
    else
      []
    end
  end

  # Startup-only wakeup repair (E4): one reconcile pass at boot, no timers,
  # no auto-wake semantics. Disabled in test via `:wakeup_reconciler`.
  defp wakeup_reconciler_children do
    if Application.get_env(:shoestring, :wakeup_reconciler, true) do
      [Shoestring.Cobbler.WakeupReconciler]
    else
      []
    end
  end

  # Startup-only handoff repair: one reconcile pass at boot restoring lost
  # delivery attempts for standing handoff intents. No timers, no new handoff
  # semantics. Disabled in test via `:handoff_reconciler`.
  defp handoff_reconciler_children do
    if Application.get_env(:shoestring, :handoff_reconciler, true) do
      [Shoestring.Cobbler.HandoffReconciler]
    else
      []
    end
  end

  defp elves_children do
    # The Elf supervisor is always present so runs stay independently
    # addressable. It boots with zero children in every environment — an Elf
    # (and therefore an OS process) only exists after an explicit
    # `Shoestring.Elves` start call — so unlike the capacity monitors there is
    # nothing to disable in test config. Tests that need isolation start their
    # own unnamed supervisor and pass it as `supervisor:` instead of using the
    # global one.
    [
      {Registry, keys: :unique, name: Shoestring.Elves.Registry},
      Supervisor.child_spec(Shoestring.Elves.Supervisor, restart: :transient)
    ]
  end

  defp plan_execution_reconciler_children do
    if Application.get_env(:shoestring, :plan_execution_reconciler, true),
      do: [Shoestring.Cobbler.PlanExecutionReconciler],
      else: []
  end

  defp reservation_control_reconciler_children do
    if Application.get_env(:shoestring, :reservation_control_reconciler, true),
      do: [Shoestring.Cobbler.ReservationControlReconciler],
      else: []
  end

  # Off unless configured, so a test or a tool run never starts a harness CLI.
  defp model_catalog_children do
    if Application.get_env(:shoestring, :model_catalog_refresh_on_start, false),
      do: [Shoestring.ModelCatalog.StartupRefresh],
      else: []
  end

  defp plan_child_inbox_reconciler_children do
    if Application.get_env(:shoestring, :plan_child_inbox_reconciler, true),
      do: [Shoestring.Cobbler.PlanChildInboxReconciler],
      else: []
  end
end
