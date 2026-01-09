defmodule EgregorosWeb.Plugs.Session do
  @moduledoc false

  @behaviour Plug

  @base_session_options [
    store: :cookie,
    key: "_egregoros_key",
    signing_salt: "4JqvCM51",
    same_site: "Lax",
    secure: Application.compile_env(:egregoros, :secure_cookies, false)
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end

  defp session_options do
    options = @base_session_options

    case Application.get_env(:egregoros, :session_cookie_domain) do
      domain when is_binary(domain) ->
        domain = String.trim(domain)
        if domain == "", do: options, else: Keyword.put(options, :domain, domain)

      _ ->
        options
    end
  end
end

