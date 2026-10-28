defmodule ShoestringWeb.Router do
  use ShoestringWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug ShoestringWeb.TerminalBrowser
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

    live "/", UsageLive, :index
    live "/usage", UsageLive, :index
    live "/agents", AgentsLive, :index
    live "/agents/new", AgentsLive, :new
    live "/agents/:slug/edit", AgentsLive, :edit
    live "/agents/:slug/duplicate", AgentsLive, :duplicate
    live "/settings", AgentSettingsLive, :index
    live "/status", HealthLive, :index
    live "/observatory", CapacityObservatoryLive, :index
    live "/cobbler", CobblerDashboardLive, :index
    live "/cobbler/goals/:goal_id", CobblerGoalLive, :show
    live "/goals/:goal_id/timeline", TrajectoryTimelineLive, :show
    live "/runs/new", RunNewLive, :new
    live "/runs/:run_id", RunShowLive, :show
    live "/runs/:run_id/terminal", TerminalLive, :show
  end

  scope "/", ShoestringWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # The coordinator's MCP tool endpoint (iteration 15, package B). No
  # `accepts`: Claude Code probes `GET /mcp` with `Accept: text/event-stream`,
  # and the MCP spec answers 405 when no event stream is offered, where
  # content negotiation would give 406.
  scope "/", ShoestringWeb do
    post "/mcp", McpController, :post
    get "/mcp", McpController, :not_allowed
    delete "/mcp", McpController, :not_allowed
  end
end
