import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

# In production (releases), we get env vars directly from the system
# In dev/test, we load .env files using Dotenvy
# Load .env file for development
if config_env() in [:dev, :test] and File.exists?(".env") and Code.ensure_loaded?(Dotenvy) do
  Dotenvy.source!([".env"], side_effect: &System.put_env/1)
end

# Phoenix server
if System.get_env("PHX_SERVER") do
  config :mini_me, MiniMeWeb.Endpoint, server: true
end

# Mini Me specific configuration (all environments)
config :mini_me,
  sprites_token: System.get_env("SPRITES_TOKEN"),
  github_token: System.get_env("GITHUB_TOKEN"),
  auth_password: System.get_env("MINI_ME_PASSWORD", "dev"),
  # OAuth token for Claude Code - generate with `claude setup-token`
  claude_oauth_token: System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :mini_me, MiniMe.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6,
    # Connection pool tuning for resilience
    queue_target: 5_000,
    queue_interval: 1_000,
    # Detect dead connections faster with TCP keepalive
    parameters: [
      tcp_keepalives_idle: "60",
      tcp_keepalives_interval: "10",
      tcp_keepalives_count: "3"
    ]

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :mini_me, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :mini_me, MiniMeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
