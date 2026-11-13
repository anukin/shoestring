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
    live "/teams", TeamsLive, :index
    live "/teams/new", TeamsLive, :new
    live "/teams/:slug/edit", TeamsLive, :edit
    live "/teams/:slug/duplicate", TeamsLive, :duplicate
    live "/agents", AgentsLive, :index
    live "/agents/new", AgentsLive, :new
    live "/agents/:slug", AgentsLive, :show
    live "/agents/:slug/edit", AgentsLive, :edit
    live "/sessions", SessionsLive, :index
    live "/sessions/:session_id", SessionsLive, :show
    live "/lessons", LessonsLive, :index
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

  # A decision candidate's bytes (iteration 19): loopback only, and only an
  # artifact one of the goal's decisions offers. No pipeline: nothing here
  # reads a session or a form.
  scope "/", ShoestringWeb do
    get "/goals/:goal_id/artifacts/:artifact_id", ArtifactController, :show
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
