defmodule EgregorosWeb.Plugs.PleromaMedia do
  @behaviour Plug

  import Plug.Conn

  alias Egregoros.RuntimeConfig

  @secure_headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"x-xss-protection", "1; mode=block"}
  ]

  def init(_opts) do
    static_opts =
      Plug.Static.init(
        at: "/media",
        from: {__MODULE__, :pleroma_media_root, []},
        gzip: false,
        headers: @secure_headers
      )

    %{static_opts: static_opts}
  end

  def call(%Plug.Conn{request_path: "/media" <> _rest} = conn, %{static_opts: static_opts}) do
    conn = Plug.Static.call(conn, static_opts)
    if conn.halted, do: conn, else: not_found(conn)
  end

  def call(conn, _opts), do: conn

  defp not_found(conn) do
    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end

  @doc false
  def pleroma_media_root do
    priv_dir =
      :egregoros
      |> :code.priv_dir()
      |> to_string()

    default = Path.join([priv_dir, "static", "pleroma_media"])

    RuntimeConfig.get(:pleroma_media_dir, default)
  end
end
