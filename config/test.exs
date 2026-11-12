import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :pos, Pos.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5434,
  database: "pos_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pos, PosWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NZoGcNc4VVn6oCCmI3FBiNAD6RNnjyXVtIG0/u64y70IlBlGS8utl8QFvvXjDrZC",
  server: false

config :pos, Oban, testing: :manual, queues: false, plugins: false
config :pos, :daraja_client, Pos.Payments.FakeDaraja
config :pos, :etims_enabled, true

config :pos, :daraja,
  callback_base_url: "http://localhost:4000",
  callback_secret: "test-callback-secret"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :bcrypt_elixir, log_rounds: 1
