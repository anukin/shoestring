defmodule Shoestring.Release.Backup do
  @moduledoc "Explicit consistent SQLite backups. Never deletes or replaces existing state."

  def create(repo, root) do
    dir = Path.join(root, "backups")
    name = "before-upgrade-" <> Ecto.UUID.generate() <> ".sqlite3"
    path = Path.join(dir, name)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         false <- File.exists?(path),
         {:ok, _} <- repo.query("VACUUM INTO ?", [path], log: false),
         :ok <- File.chmod(path, 0o600),
         :ok <- sync(path) do
      {:ok, name}
    else
      _ -> {:error, :database_backup_failed}
    end
  end

  defp sync(path) do
    with {:ok, file} <- File.open(path, [:read, :write, :binary]) do
      try do
        :file.sync(file)
      after
        File.close(file)
      end
    end
  end
end
