defmodule Shoestring.CLI.Jobs do
  @moduledoc "Queue-only client: persist jobs without starting application workers or providers."

  def with_client(fun) do
    {:ok, _} = Application.ensure_all_started(:oban)

    {:ok, pid} =
      Oban.start_link(
        name: __MODULE__,
        repo: Shoestring.Repo,
        engine: Oban.Engines.Lite,
        queues: false,
        plugins: false,
        peer: false
      )

    try do
      fun.(__MODULE__)
    after
      Supervisor.stop(pid)
    end
  end
end
