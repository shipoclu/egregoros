import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/egregoros start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :egregoros, EgregorosWeb.Endpoint, server: true
end

config :egregoros, EgregorosWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

allow_private_federation =
  System.get_env("EGREGOROS_ALLOW_PRIVATE_FEDERATION", "")
  |> String.trim()
  |> String.downcase()

if allow_private_federation in ~w(true 1) do
  config :egregoros, :allow_private_federation, true
end

webfinger_scheme =
  System.get_env("EGREGOROS_FEDERATION_WEBFINGER_SCHEME", "")
  |> String.trim()
  |> String.downcase()

if webfinger_scheme in ~w(http https) do
  config :egregoros, :federation_webfinger_scheme, webfinger_scheme
end

req_cacertfile =
  System.get_env("EGREGOROS_REQ_CACERTFILE", "")
  |> String.trim()

if req_cacertfile != "" do
  config :egregoros, :req_https_transport_opts,
    verify: :verify_peer,
    cacertfile: req_cacertfile,
    depth: 20,
    reuse_sessions: false,
    log_level: :warning,
    customize_hostname_check: [
      match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
    ]
end

bootstrap_admin_nickname = System.get_env("EGREGOROS_BOOTSTRAP_ADMIN")

if is_binary(bootstrap_admin_nickname) and bootstrap_admin_nickname != "" do
  config :egregoros, :bootstrap_admin_nickname, bootstrap_admin_nickname
end

if config_env() != :test do
  external_host = System.get_env("PHX_HOST") || System.get_env("EGREGOROS_EXTERNAL_HOST")

  if is_binary(external_host) and external_host != "" do
    external_scheme =
      System.get_env("PHX_SCHEME") || System.get_env("EGREGOROS_EXTERNAL_SCHEME") || "https"

    external_port =
      System.get_env("PHX_PORT") || System.get_env("EGREGOROS_EXTERNAL_PORT") ||
        if(external_scheme == "https", do: "443", else: "80")

    config :egregoros, EgregorosWeb.Endpoint,
      url: [
        host: external_host,
        scheme: external_scheme,
        port: String.to_integer(external_port)
      ]
  end

  uploads_base_url =
    System.get_env("EGREGOROS_UPLOADS_BASE_URL") || System.get_env("UPLOADS_BASE_URL")

  if is_binary(uploads_base_url) and uploads_base_url != "" do
    config :egregoros, :uploads_base_url, uploads_base_url
  end

  session_cookie_domain =
    System.get_env("EGREGOROS_SESSION_COOKIE_DOMAIN") || System.get_env("SESSION_COOKIE_DOMAIN")

  if is_binary(session_cookie_domain) and session_cookie_domain != "" do
    config :egregoros, :session_cookie_domain, session_cookie_domain
  end
end

if config_env() == :prod do
  uploads_dir = System.get_env("EGREGOROS_UPLOADS_DIR") || System.get_env("UPLOADS_DIR")

  if is_binary(uploads_dir) and uploads_dir != "" do
    config :egregoros, :uploads_dir, uploads_dir
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :egregoros, Egregoros.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || System.get_env("EGREGOROS_EXTERNAL_HOST") || "example.com"
  scheme = System.get_env("PHX_SCHEME") || System.get_env("EGREGOROS_EXTERNAL_SCHEME") || "https"

  external_port =
    System.get_env("PHX_PORT") || System.get_env("EGREGOROS_EXTERNAL_PORT") ||
      if(scheme == "https", do: "443", else: "80")

  http_port = String.to_integer(System.get_env("PORT", "4000"))

  config :egregoros, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :egregoros, EgregorosWeb.Endpoint,
    url: [host: host, port: String.to_integer(external_port), scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: http_port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :egregoros, EgregorosWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :egregoros, EgregorosWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :egregoros, Egregoros.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
