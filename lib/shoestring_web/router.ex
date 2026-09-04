defmodule ShoestringWeb.Router do
  use ShoestringWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ShoestringWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ShoestringWeb do
    pipe_through :browser

    live "/", HealthLive, :index
    live "/observatory", CapacityObservatoryLive, :index
    live "/goals/:goal_id/timeline", TrajectoryTimelineLive, :show
  end

  scope "/", ShoestringWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end
