defmodule Shoestring.Health do
  @moduledoc """
  Local readiness checks for the Shoestring control plane.
  """

  alias Shoestring.Repo

  @type status :: :ok | :error
  @type checks :: %{
          application: status(),
          pubsub: status(),
          repo: status(),
          state: status()
        }

  @spec check() :: checks()
  def check do
    %{
      application: process_status(Shoestring.Supervisor),
      pubsub: process_status(Shoestring.PubSub),
      repo: repo_status(),
      state: state_status()
    }
  end

  @spec ready?() :: boolean()
  def ready?, do: ready?(check())

  @spec ready?(checks()) :: boolean()
  def ready?(checks), do: Enum.all?(checks, fn {_name, status} -> status == :ok end)

  defp process_status(name), do: if(Process.whereis(name), do: :ok, else: :error)

  defp repo_status do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _exception -> :error
  end

  defp state_status do
    case Shoestring.State.ensure_writable_root() do
      :ok -> :ok
      {:error, _reason} -> :error
    end
  end
end
