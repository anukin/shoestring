defmodule Shoestring.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Shoestring.State.ensure_writable_root!()
    Shoestring.State.configure_repo!()

    children =
      [
        ShoestringWeb.Telemetry,
        Shoestring.Repo,
        {Registry, keys: :unique, name: Shoestring.Trajectory.WriterRegistry},
        Shoestring.Trajectory.WriterSupervisor,
        {Phoenix.PubSub, name: Shoestring.PubSub},
        {Oban, Application.fetch_env!(:shoestring, Oban)}
      ] ++
        dispatch_reconciler_children() ++
        capacity_supervisor_children() ++
        [
          {DNSCluster, query: Application.get_env(:shoestring, :dns_cluster_query) || :ignore},
          ShoestringWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Shoestring.Supervisor]
    Supervisor.start_link(children, opts)
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
    # intensity, it exits with `{:shutdown, _}`, which a `:transient` child
    # does NOT restart. The outage stops there instead of storming the root
    # supervisor (which would take down the Endpoint, Repo, and healthy
    # provider with it).
    [Supervisor.child_spec(Shoestring.Harness.Capacity.Supervisor, restart: :transient)]
  end

  defp dispatch_reconciler_children do
    if Application.get_env(:shoestring, :dispatch_reconciler, true) do
      [Shoestring.Harness.Dispatch.Reconciler]
    else
      []
    end
  end
end
