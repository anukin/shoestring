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
        {Oban, Application.fetch_env!(:shoestring, Oban)},
        {Registry, keys: :unique, name: Shoestring.Trajectory.WriterRegistry},
        Shoestring.Trajectory.WriterSupervisor
      ] ++
        dispatch_reconciler_children() ++
        [
          {DNSCluster, query: Application.get_env(:shoestring, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Shoestring.PubSub},
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

  defp dispatch_reconciler_children do
    if Application.get_env(:shoestring, :dispatch_reconciler, true) do
      [Shoestring.Harness.Dispatch.Reconciler]
    else
      []
    end
  end
end
