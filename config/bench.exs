import Config

# Configure your database (recommended: keep this isolated from dev/prod)
config :egregoros, Egregoros.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "egregoros_bench",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 20

# We don't run an HTTP server during benchmarks; the suite runs directly against the DB.
config :egregoros, EgregorosWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "tB7hBkFAvy/E0h6QnykVSJfIEY3o9b3tTpnJ+vL+E6mkL4Sji4d6bt/smQGJPSuQ",
  server: false

# Faster password hashing for bench data generation.
config :egregoros, :password_iterations, 1_000

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# Keep logs readable for interactive bench runs.
config :logger, level: :info

# Avoid noisy shutdown logs / alarms from os_mon during benches.
config :os_mon,
  start_cpu_sup: false,
  start_memsup: false,
  start_disksup: false
