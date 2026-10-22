defmodule Shoestring.Harness.HTTP.Supervisor do
  @moduledoc "Empty at boot. HTTP sessions are temporary and never automatically replaced."
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Shoestring.Harness.HTTP.Registry},
        {Task.Supervisor, name: Shoestring.Harness.HTTP.Tasks},
        {DynamicSupervisor, strategy: :one_for_one, name: Shoestring.Harness.HTTP.Sessions}
      ],
      strategy: :rest_for_one
    )
  end
end
