import Config

# Runtime production configuration lives in config/runtime.exs so packaged
# releases can choose a local state root and loopback endpoint at startup.
config :logger, level: :info
