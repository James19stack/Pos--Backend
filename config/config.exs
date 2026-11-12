# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pos,
  ecto_repos: [Pos.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :pos, PosWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PosWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pos.PubSub,
  live_view: [signing_salt: "7PXu41u/"]

config :pos, Oban,
  engine: Oban.Engines.Basic,
  repo: Pos.Repo,
  queues: [default: 10, mpesa: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [{"* * * * *", Pos.Workers.MpesaReconciler}]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :pos, :jwt_secret, "dev-only-secret-change-me-at-least-32-chars-long"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
