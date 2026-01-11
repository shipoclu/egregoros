defmodule EgregorosWeb.Plugs.Uploads do
  @behaviour Plug

  import Plug.Conn

  alias Egregoros.Media
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  @secure_headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"x-xss-protection", "1; mode=block"}
  ]

  def init(_opts) do
    static_opts =
      Plug.Static.init(
        at: "/uploads",
        from: {__MODULE__, :uploads_root, []},
        gzip: false,
        headers: @secure_headers,
        only_matching: ~w(avatars banners media)
      )

    %{static_opts: static_opts}
  end

  def call(%Plug.Conn{request_path: "/uploads" <> _rest} = conn, %{static_opts: static_opts}) do
    if uploads_host_allowed?(conn) do
      conn = fetch_session(conn)

      case conn.request_path do
        "/uploads/media/" <> _ ->
          user = current_user(conn)

          if Media.local_href_visible_to?(conn.request_path, user) do
            serve_static(conn, static_opts)
          else
            not_found(conn)
          end

        "/uploads/avatars/" <> _ ->
          serve_static(conn, static_opts)

        "/uploads/banners/" <> _ ->
          serve_static(conn, static_opts)

        _ ->
          not_found(conn)
      end
    else
      not_found(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp current_user(conn) do
    case get_session(conn, :user_id) do
      id when is_integer(id) ->
        Users.get(id)

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int, ""} -> Users.get(int)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp serve_static(conn, static_opts) do
    conn = Plug.Static.call(conn, static_opts)
    if conn.halted, do: conn, else: not_found(conn)
  end

  defp not_found(conn) do
    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end

  @doc false
  def uploads_root do
    priv_dir =
      :egregoros
      |> :code.priv_dir()
      |> to_string()

    default = Path.join([priv_dir, "static", "uploads"])

    Application.get_env(:egregoros, :uploads_dir, default)
  end

  defp uploads_host_allowed?(%Plug.Conn{} = conn) do
    if uploads_host_restricted?() do
      case uploads_host() do
        host when is_binary(host) and host != "" ->
          is_binary(conn.host) and String.downcase(conn.host) == String.downcase(host)

        _ ->
          false
      end
    else
      true
    end
  end

  defp uploads_host_allowed?(_conn), do: true

  defp uploads_host_restricted? do
    with uploads_host when is_binary(uploads_host) and uploads_host != "" <- uploads_host(),
         endpoint_host when is_binary(endpoint_host) and endpoint_host != "" <- endpoint_host() do
      String.downcase(uploads_host) != String.downcase(endpoint_host)
    else
      _ -> false
    end
  end

  defp uploads_host do
    with base when is_binary(base) and base != "" <-
           Application.get_env(:egregoros, :uploads_base_url),
         %URI{host: host} when is_binary(host) and host != "" <- URI.parse(base) do
      host
    else
      _ -> nil
    end
  end

  defp endpoint_host do
    with url when is_binary(url) and url != "" <- Endpoint.url(),
         %URI{host: host} when is_binary(host) and host != "" <- URI.parse(url) do
      host
    else
      _ -> nil
    end
  end
end
