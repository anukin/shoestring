# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :shoestring,
  ecto_repos: [Shoestring.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  state_dir: nil,
  environment: config_env()

config :shoestring, Shoestring.Repo,
  journal_mode: :wal,
  busy_timeout: 2_000,
  foreign_keys: :on

# Configure the endpoint
config :shoestring, ShoestringWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ShoestringWeb.ErrorHTML, json: ShoestringWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Shoestring.PubSub,
  live_view: [signing_salt: "ORDSihlk"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
