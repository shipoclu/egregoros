import Config

# Override docker defaults to run the instance as plain HTTP inside the compose network.
config :pleroma, Pleroma.Web.Endpoint,
  url: [host: System.get_env("DOMAIN", "pleroma.test"), scheme: "http", port: 80]

# Keep it permissive for local testing.
config :pleroma, :instance,
  registrations_open: true

# Disable CAPTCHA for fedbox user seeding / smoke tests.
config :pleroma, Pleroma.Captcha, enabled: false
