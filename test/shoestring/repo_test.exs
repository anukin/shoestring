defmodule Shoestring.RepoTest do
  use Shoestring.DataCase, async: false

  test "opens the configured isolated SQLite database" do
    assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT 1")

    database = Application.fetch_env!(:shoestring, Shoestring.Repo)[:database]
    assert is_binary(database)
    assert database == Shoestring.State.database_path()
    assert Path.dirname(database) == Shoestring.State.root()
    assert String.starts_with?(database, System.tmp_dir!())
  end
end
