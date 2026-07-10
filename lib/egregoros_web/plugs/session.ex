defmodule EgregorosWeb.Plugs.Session do
  @moduledoc false

  @behaviour Plug

  @default_secure Application.compile_env(:egregoros, :secure_cookies, false)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(options()))
  end

  @doc false
  def options(overrides \\ []) when is_list(overrides) do
    secure = Keyword.get(overrides, :secure, @default_secure)

    [
      store: :cookie,
      key: if(secure, do: "__Host-egregoros", else: "_egregoros_key"),
      signing_salt: "4JqvCM51",
      path: "/",
      http_only: true,
      same_site: "Lax",
      secure: secure
    ]
  end
end
