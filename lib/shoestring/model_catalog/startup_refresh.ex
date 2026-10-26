defmodule Shoestring.ModelCatalog.StartupRefresh do
  @moduledoc """
  Once, as the service starts, refreshes the model catalog of each installed
  harness whose models were never listed or were last listed more than a day
  ago. Enabled by `config :shoestring, :model_catalog_refresh_on_start`; off
  in tests and with `SHOESTRING_AUTOMATION=off`. A failed listing is logged
  and changes nothing; this process never restarts.
  """
  use Task, restart: :temporary
  require Logger

  alias Shoestring.ModelCatalog

  @max_age_seconds 86_400

  def start_link(opts \\ []), do: Task.start_link(__MODULE__, :run, [opts])

  @doc """
  Refreshes the stale harnesses and returns `[{provider, result}]`. Options:
  `:now`, `:find` (locates an executable) and `:lister`.
  """
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    find = Keyword.get(opts, :find, &System.find_executable/1)

    for provider <- ModelCatalog.providers(), find.(provider), stale?(provider, now) do
      result = ModelCatalog.refresh(provider, Keyword.take(opts, [:lister]))

      case result do
        {:ok, report} ->
          Logger.info(
            "Model catalog: #{provider} listed #{report["listed"]} models, #{length(report["new"])} new"
          )

        {:error, reason} ->
          Logger.warning("Model catalog: #{provider} could not be listed (#{inspect(reason)})")
      end

      {provider, result}
    end
  end

  def stale?(provider, now) do
    case ModelCatalog.last_listed_at(provider) do
      nil -> true
      at -> DateTime.diff(now, at) > @max_age_seconds
    end
  end
end
