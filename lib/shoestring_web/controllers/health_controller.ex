defmodule ShoestringWeb.HealthController do
  use ShoestringWeb, :controller

  alias Shoestring.Health

  def show(conn, _params) do
    checks = Health.check()
    ready? = Health.ready?(checks)

    conn
    |> put_status(if(ready?, do: :ok, else: :service_unavailable))
    |> json(%{ready: ready?, checks: checks})
  end
end
