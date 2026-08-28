defmodule Shoestring.State do
  @moduledoc """
  Resolves and prepares Shoestring's local state paths.

  Production and development use `SHOESTRING_STATE_DIR` as an explicit
  override. Tests deliberately use the separate `SHOESTRING_TEST_STATE_DIR`
  variable so a developer's production state directory can never be selected
  accidentally by the test suite.
  """

  @subdirectories [:artifacts, :worktrees, :logs, :run]

  @type environment :: :dev | :test | :prod
  @type state_error ::
          {:state_root_unavailable, Path.t(), File.posix()}
          | {:state_root_not_writable, Path.t(), File.posix()}

  @spec root() :: Path.t()
  def root do
    environment = environment()

    environment_override(environment) ||
      Application.get_env(:shoestring, :state_dir) ||
      default_root(environment)
  end

  @spec database_path() :: Path.t()
  def database_path, do: Path.join(root(), "shoestring.db")

  @spec path(atom()) :: Path.t()
  def path(name) when name in @subdirectories, do: Path.join(root(), Atom.to_string(name))

  @spec ensure_root() :: :ok | {:error, state_error()}
  def ensure_root do
    state_root = root()

    case File.mkdir_p(state_root) do
      :ok -> :ok
      {:error, reason} -> {:error, {:state_root_unavailable, state_root, reason}}
    end
  end

  @spec ensure_writable_root() :: :ok | {:error, state_error()}
  def ensure_writable_root do
    with :ok <- ensure_root() do
      verify_writable(root())
    end
  end

  @spec ensure_writable_root!() :: :ok
  def ensure_writable_root! do
    case ensure_writable_root() do
      :ok -> :ok
      {:error, reason} -> raise "Shoestring state directory is unavailable: #{inspect(reason)}"
    end
  end

  @spec configure_repo!() :: :ok
  def configure_repo! do
    repo_config = Application.get_env(:shoestring, Shoestring.Repo, [])

    Application.put_env(
      :shoestring,
      Shoestring.Repo,
      Keyword.put(repo_config, :database, database_path())
    )
  end

  @spec default_root(environment()) :: Path.t()
  def default_root(:dev), do: Path.expand(".shoestring/dev", File.cwd!())

  def default_root(:test) do
    Path.join(System.tmp_dir!(), "shoestring-test-#{System.pid()}")
  end

  def default_root(:prod) do
    case :os.type() do
      {:unix, :darwin} ->
        Path.join(System.user_home!(), "Library/Application Support/Shoestring")

      {:unix, _name} ->
        case System.get_env("XDG_STATE_HOME") do
          value when is_binary(value) and value != "" -> Path.join(value, "shoestring")
          _ -> Path.join(System.user_home!(), ".local/state/shoestring")
        end

      _ ->
        Path.join(System.user_home!(), ".shoestring")
    end
  end

  defp environment, do: Application.get_env(:shoestring, :environment, :prod)

  defp environment_override(:test), do: present_env("SHOESTRING_TEST_STATE_DIR")
  defp environment_override(_environment), do: present_env("SHOESTRING_STATE_DIR")

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp verify_writable(state_root) do
    probe = Path.join(state_root, ".writable-#{System.unique_integer([:positive, :monotonic])}")

    case File.open(probe, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)
        File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, {:state_root_not_writable, state_root, reason}}
    end
  end
end
