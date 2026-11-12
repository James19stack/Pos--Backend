import Config

if System.get_env("PHX_SERVER") do
  config :pos, PosWeb.Endpoint, server: true
end

config :pos, PosWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# M-Pesa (Safaricom Daraja). Values come from environment variables, see .env.example.
config :pos, :daraja,
  env: if(System.get_env("DARAJA_ENV") == "production", do: :production, else: :sandbox),
  consumer_key: System.get_env("DARAJA_CONSUMER_KEY"),
  consumer_secret: System.get_env("DARAJA_CONSUMER_SECRET"),
  shortcode: System.get_env("DARAJA_SHORTCODE", "174379"),
  passkey: System.get_env("DARAJA_PASSKEY"),
  transaction_type: System.get_env("DARAJA_TRANSACTION_TYPE", "CustomerPayBillOnline"),
  party_b: System.get_env("DARAJA_PARTY_B"),
  callback_base_url: System.get_env("DARAJA_CALLBACK_BASE_URL", "http://localhost:4000"),
  callback_secret: System.get_env("DARAJA_CALLBACK_SECRET", "dev-callback-secret"),
  c2b_shortcode: System.get_env("DARAJA_C2B_SHORTCODE")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing. Example: ecto://USER:PASS@HOST/DATABASE"

  # Never run production with the development defaults for these.
  for var <- ~w(DARAJA_CONSUMER_KEY DARAJA_CONSUMER_SECRET DARAJA_PASSKEY
                DARAJA_CALLBACK_BASE_URL DARAJA_CALLBACK_SECRET JWT_SECRET) do
    System.get_env(var) || raise "environment variable #{var} is missing."
  end

  config :pos, :jwt_secret, System.fetch_env!("JWT_SECRET")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :pos, Pos.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing. Generate one with: mix phx.gen.secret"

  host = System.get_env("PHX_HOST") || "example.com"

  config :pos, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :pos, PosWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
