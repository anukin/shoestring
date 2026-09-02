defmodule Shoestring.ApplicationTest do
  use ExUnit.Case, async: false

  test "starts the application supervision tree and required named services" do
    assert Process.whereis(Shoestring.Supervisor)
    assert Process.whereis(Shoestring.Repo)
    assert Process.whereis(Shoestring.PubSub)
    assert Process.whereis(ShoestringWeb.Endpoint)

    children = Supervisor.which_children(Shoestring.Supervisor)
    child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

    assert Shoestring.Repo in child_ids
    assert Oban in child_ids
    assert Phoenix.PubSub.Supervisor in child_ids
    assert ShoestringWeb.Endpoint in child_ids
  end

  test "configures Oban Lite after the SQLite repo with manual test delivery" do
    assert %Oban.Config{engine: Oban.Engines.Lite, repo: Shoestring.Repo, testing: :manual} =
             Oban.config()

    assert Oban.config().queues == []
  end
end
