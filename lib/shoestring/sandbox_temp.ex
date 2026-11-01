defmodule Shoestring.SandboxTemp do
  @moduledoc """
  Per-run temporary directories for OS-sandboxed processes (gates and opencode
  Elves). Each run gets a fresh directory directly under the system temporary
  directory, named `<prefix>-<uuid>`, which its sandbox may write and which
  `HOME`/`TMPDIR` point at.

  The run's owner removes it once the run is over (the user asked for this on
  2026-10-24: hundreds had accumulated). `remove/2` deletes only a directory
  this module could have created — directly under the physical system
  temporary directory, a real directory rather than a symlink, and named with
  the expected prefix and a UUID — so a wrong path can never delete anything
  else. Nothing removes a directory on a timer; a crash leaves it behind.
  """

  alias Shoestring.Harness.CodexAppServer.GitSandbox

  @doc "Creates `<system tmp>/<prefix>-<uuid>`."
  @spec create(String.t()) :: {:ok, Path.t()} | {:error, :temp_dir_unavailable}
  def create(prefix) when is_binary(prefix) do
    dir = Path.join(root(), "#{prefix}-#{Ecto.UUID.generate()}")

    case File.mkdir(dir) do
      :ok -> {:ok, dir}
      {:error, _} -> {:error, :temp_dir_unavailable}
    end
  end

  @doc "Removes a directory made by `create/1` with the same prefix."
  @spec remove(Path.t() | nil, String.t()) :: :ok | {:error, :not_a_sandbox_temp_dir}
  def remove(nil, _prefix), do: :ok

  def remove(dir, prefix) when is_binary(dir) and is_binary(prefix) do
    if owned?(dir, prefix) do
      _ = File.rm_rf(dir)
      :ok
    else
      {:error, :not_a_sandbox_temp_dir}
    end
  end

  defp owned?(dir, prefix) do
    Path.dirname(dir) == root() and
      Regex.match?(
        ~r/\A#{Regex.escape(prefix)}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
        Path.basename(dir)
      ) and
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir))
  end

  defp root, do: GitSandbox.physical_path(System.tmp_dir!())

  @doc """
  Creates `<physical /tmp>/<prefix>-<12 hex>`, private to this user (0700),
  for a process that falls back to a shared location when its temporary
  directory's path is long. Claude Code 2.1.316 uses `CLAUDE_CODE_TMPDIR`
  only when it is at most about 32 characters (between 32 and 38, VERIFIED
  offline 2026-10-31); a longer one, as anything under macOS's per-user
  `TMPDIR` is, sends it back to the shared `/tmp/claude-<uid>`.
  """
  @spec create_short(String.t()) :: {:ok, Path.t()} | {:error, :temp_dir_unavailable}
  def create_short(prefix) when is_binary(prefix) do
    name = "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
    dir = Path.join(short_root(), name)

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    else
      _ -> {:error, :temp_dir_unavailable}
    end
  end

  @doc "Removes a directory made by `create_short/1` with the same prefix."
  @spec remove_short(Path.t() | nil, String.t()) :: :ok | {:error, :not_a_sandbox_temp_dir}
  def remove_short(nil, _prefix), do: :ok

  def remove_short(dir, prefix) when is_binary(dir) and is_binary(prefix) do
    if Path.dirname(dir) == short_root() and
         Regex.match?(~r/\A#{Regex.escape(prefix)}-[0-9a-f]{12}\z/, Path.basename(dir)) and
         match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir)) do
      _ = File.rm_rf(dir)
      :ok
    else
      {:error, :not_a_sandbox_temp_dir}
    end
  end

  @doc "The physical system `/tmp` that `create_short/1` uses."
  def short_root, do: GitSandbox.physical_path("/tmp")
end
