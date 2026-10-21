defmodule Shoestring.Terminal.Supervisor do
  @moduledoc "Interactive sessions restart only through an explicit new run, never as the old provider."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Shoestring.Terminal.Registry},
        {DynamicSupervisor, name: Shoestring.Terminal.Sessions, strategy: :one_for_one},
        Shoestring.Terminal.Recovery
      ],
      strategy: :rest_for_one
    )
  end
end
