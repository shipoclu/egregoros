# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :egregoros,
  ecto_repos: [Egregoros.Repo],
  generators: [timestamp_type: :utc_datetime]

config :egregoros, Oban,
  repo: Egregoros.Repo,
  notifier: Oban.Notifiers.PG,
  queues: [
    federation_incoming: 10,
    federation_outgoing: 25
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24},
    {Oban.Plugins.Cron,
     crontab: [
       {"@daily", Egregoros.Workers.RefreshRemoteFollowingGraphsDaily}
     ]}
  ]

config :egregoros, Egregoros.Config, Egregoros.Config.Application
config :egregoros, Egregoros.Signature, Egregoros.Signature.HTTP
config :egregoros, Egregoros.Auth, Egregoros.Auth.BearerToken
config :egregoros, Egregoros.AuthZ, Egregoros.AuthZ.OAuthScopes
config :egregoros, Egregoros.Discovery, Egregoros.Discovery.DNS
config :egregoros, Egregoros.HTTP, Egregoros.HTTP.Req
config :egregoros, Egregoros.DNS, Egregoros.DNS.Cached
config :egregoros, Egregoros.AvatarStorage, Egregoros.AvatarStorage.Local
config :egregoros, Egregoros.MediaStorage, Egregoros.MediaStorage.Local

config :egregoros, Egregoros.DNS.Cached,
  resolver: Egregoros.DNS.Inet,
  ttl_ms: 60_000

config :egregoros, :password_iterations, 200_000

# Configure the endpoint
config :egregoros, EgregorosWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EgregorosWeb.ErrorHTML, json: EgregorosWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Egregoros.PubSub,
  live_view: [signing_salt: "o6GDDK1W"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :egregoros, Egregoros.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  egregoros: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  egregoros: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{
  "application/activity+json" => ["json"],
  "application/ld+json" => ["json"],
  "audio/mp4" => ["m4a"],
  "audio/ogg" => ["ogg"],
  "audio/opus" => ["opus"]
}

config :mime, :extensions, %{
  "json" => "application/json"
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
