defmodule EgregorosWeb.Plugs.CORSPlugTest do
  use EgregorosWeb.ConnCase, async: true

  import Plug.Conn

  alias EgregorosWeb.Plugs.CORS

  @origin "https://frontend.example"

  test "does nothing for non-CORS paths" do
    conn =
      :get
      |> Plug.Test.conn("/")
      |> put_req_header("origin", @origin)
      |> CORS.call(cors_opts())

    assert get_resp_header(conn, "access-control-allow-origin") == []
    assert get_resp_header(conn, "access-control-expose-headers") == []
  end

  test "does nothing when origin is missing" do
    conn =
      :get
      |> Plug.Test.conn("/api/v1/instance")
      |> CORS.call(cors_opts())

    assert get_resp_header(conn, "access-control-allow-origin") == []
    assert get_resp_header(conn, "access-control-expose-headers") == []
  end

  test "allows any origin when credentials are not allowed" do
    conn =
      :get
      |> Plug.Test.conn("/api/v1/instance")
      |> put_req_header("origin", @origin)
      |> CORS.call(cors_opts(origins: ["*"], allow_credentials: false))

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "vary") == []
    assert get_resp_header(conn, "access-control-allow-credentials") == []
    assert get_resp_header(conn, "access-control-expose-headers") == ["link"]
  end

  test "echoes origin when credentials are allowed" do
    conn =
      :get
      |> Plug.Test.conn("/api/v1/instance")
      |> put_req_header("origin", @origin)
      |> CORS.call(cors_opts(origins: ["*"], allow_credentials: true))

    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    assert get_resp_header(conn, "vary") == ["origin"]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
  end

  test "appends origin to vary when already set" do
    conn =
      :get
      |> Plug.Test.conn("/api/v1/instance")
      |> put_req_header("origin", @origin)
      |> put_resp_header("vary", "accept-encoding")
      |> CORS.call(cors_opts(origins: ["*"], allow_credentials: true))

    assert get_resp_header(conn, "vary") == ["accept-encoding, origin"]
  end

  test "supports allowlisted origins" do
    opts = cors_opts(origins: ["https://allowed.example"], allow_credentials: false)

    conn_allowed =
      :get
      |> Plug.Test.conn("/api/v1/instance")
      |> put_req_header("origin", "https://allowed.example")
      |> CORS.call(opts)

    assert get_resp_header(conn_allowed, "access-control-allow-origin") == [
             "https://allowed.example"
           ]

    conn_blocked =
      :get
      |> Plug.Test.conn("/api/v1/instance")
      |> put_req_header("origin", "https://blocked.example")
      |> CORS.call(opts)

    assert get_resp_header(conn_blocked, "access-control-allow-origin") == []
  end

  test "answers preflight requests with allow-methods/allow-headers/max-age" do
    conn =
      :options
      |> Plug.Test.conn("/api/v1/instance")
      |> put_req_header("origin", @origin)
      |> put_req_header("access-control-request-headers", "range")
      |> CORS.call(cors_opts(methods: ~w(GET POST), max_age: 10))

    assert conn.halted
    assert conn.status == 204
    assert conn.resp_body == ""

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "access-control-allow-methods") == ["GET,POST"]
    assert get_resp_header(conn, "access-control-allow-headers") == ["range"]
    assert get_resp_header(conn, "access-control-max-age") == ["10"]
  end

  test "preflight falls back to default allow-headers when request header is missing" do
    conn =
      :options
      |> Plug.Test.conn("/api/v1/instance")
      |> put_req_header("origin", @origin)
      |> CORS.call(cors_opts())

    assert conn.halted

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization,content-type,accept"
           ]
  end

  defp cors_opts(overrides \\ []) do
    [
      paths: ["/api"],
      origins: ["*"],
      methods: ~w(GET),
      expose_headers: ["link"],
      max_age: 86_400,
      allow_credentials: false
    ]
    |> Keyword.merge(overrides)
  end
end
