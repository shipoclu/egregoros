defmodule EgregorosWeb.Plugs.Uploads do
  @behaviour Plug

  import Plug.Conn

  alias Egregoros.RuntimeConfig
  alias Egregoros.Media
  alias Egregoros.Signature
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  @secure_headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"x-xss-protection", "1; mode=block"}
  ]

  def init(_opts) do
    public_static_opts =
      Plug.Static.init(
        at: "/uploads",
        from: {__MODULE__, :uploads_root, []},
        gzip: false,
        headers: @secure_headers,
        cache_control_for_etags: "public, max-age=31536000, immutable",
        cache_control_for_vsn_requests: "public, max-age=31536000, immutable",
        only_matching: ~w(avatars banners media)
      )

    restricted_static_opts =
      Plug.Static.init(
        at: "/uploads",
        from: {__MODULE__, :uploads_root, []},
        gzip: false,
        headers: [{"vary", "authorization, cookie, signature"} | @secure_headers],
        cache_control_for_etags: "private, no-store",
        cache_control_for_vsn_requests: "private, no-store",
        only_matching: ~w(media)
      )

    %{public_static_opts: public_static_opts, restricted_static_opts: restricted_static_opts}
  end

  def call(
        %Plug.Conn{request_path: "/uploads" <> _rest} = conn,
        %{public_static_opts: public_opts, restricted_static_opts: restricted_opts}
      ) do
    case conn.request_path do
      "/uploads/media/" <> _ ->
        serve_media(conn, public_opts, restricted_opts)

      _ ->
        if uploads_host_allowed?(conn) do
          case conn.request_path do
            "/uploads/avatars/" <> _ ->
              serve_static(conn, public_opts)

            "/uploads/banners/" <> _ ->
              serve_static(conn, public_opts)

            _ ->
              not_found(conn)
          end
        else
          not_found(conn)
        end
    end
  end

  def call(conn, _opts), do: conn

  defp serve_media(conn, public_opts, restricted_opts) do
    requester = requester_actor_ap_id(conn)

    case Media.access_for_path(conn.request_path, requester) do
      :public ->
        if uploads_host_allowed?(conn),
          do: serve_static(conn, public_opts),
          else: not_found(conn)

      :restricted ->
        if restricted_host_allowed?(conn),
          do: serve_static(conn, restricted_opts),
          else: not_found(conn)

      :denied ->
        not_found(conn)
    end
  end

  defp requester_actor_ap_id(conn) do
    session_actor(conn) || bearer_actor(conn) || signature_actor(conn)
  end

  defp session_actor(conn) do
    conn = fetch_session(conn)

    case get_session(conn, :user_id) do
      user_id when is_binary(user_id) ->
        case Users.get(user_id) do
          %{ap_id: ap_id} when is_binary(ap_id) -> ap_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp bearer_actor(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token | _] ->
        case Egregoros.Auth.current_user(conn) do
          {:ok, %{ap_id: ap_id}} when is_binary(ap_id) -> ap_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp signature_actor(conn) do
    case get_req_header(conn, "signature") do
      [_signature | _] ->
        case Signature.verify_request(conn) do
          {:ok, ap_id} when is_binary(ap_id) -> ap_id
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

    RuntimeConfig.get(:uploads_dir, default)
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

  defp restricted_host_allowed?(%Plug.Conn{} = conn) do
    if uploads_host_restricted?() do
      is_binary(conn.host) and String.downcase(conn.host) == String.downcase(endpoint_host())
    else
      true
    end
  end

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
           RuntimeConfig.get(:uploads_base_url),
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
