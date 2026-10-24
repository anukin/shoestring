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
end
