defmodule Egregoros.MiniApps.Fetcher.ReqTest do
  use ExUnit.Case, async: true

  import Mox
  import Plug.Conn

  alias Egregoros.MiniApps.Fetcher

  setup :verify_on_exit!

  setup do
    stub(Egregoros.DNS.Mock, :lookup_ips, fn _host -> {:ok, [{93, 184, 216, 34}]} end)
    :ok
  end

  test "pins the validated address and returns raw manifest json" do
    expect(Egregoros.DNS.Mock, :lookup_ips, fn "app.example" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    Req.Test.stub(Fetcher.Req, fn conn ->
      assert conn.host == "93.184.216.34"
      assert get_req_header(conn, "accept") == ["application/json"]
      assert get_req_header(conn, "host") == ["app.example"]

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s|{"version":"1"}|)
    end)

    assert {:ok, %{body: ~s|{"version":"1"}|}} =
             Fetcher.Req.get(
               "https://app.example/.well-known/fediverse-miniapp.json",
               :manifest
             )
  end

  test "canonicalizes the accepted URL once before DNS and transport" do
    expect(Egregoros.DNS.Mock, :lookup_ips, fn "app.example" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    Req.Test.stub(Fetcher.Req, fn conn ->
      assert conn.host == "93.184.216.34"
      assert conn.request_path == "/path"
      assert conn.query_string == "mode=full"
      assert get_req_header(conn, "host") == ["app.example"]

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<html></html>")
    end)

    assert {:ok, %{body: "<html></html>"}} =
             Fetcher.Req.get("HTTPS://App.Example.:443/path?mode=full", :page)
  end

  test "fetches html pages with the page-specific limit" do
    Req.Test.stub(Fetcher.Req, fn conn ->
      assert get_req_header(conn, "accept") == ["text/html"]

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<html></html>")
    end)

    assert {:ok, %{body: "<html></html>"}} =
             Fetcher.Req.get("https://app.example/page", :page)
  end

  test "fetches bounded ActivityStreams actor documents without redirects" do
    Req.Test.stub(Fetcher.Req, fn conn ->
      assert get_req_header(conn, "accept") == [
               "application/activity+json,application/ld+json,application/json"
             ]

      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, ~s|{"id":"https://app.example/ap/actor"}|)
    end)

    assert {:ok, %{body: body}} =
             Fetcher.Req.get("https://app.example/ap/actor", :actor)

    assert byte_size(body) < 65_536
  end

  test "fetches only bounded raster image assets" do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    Req.Test.stub(Fetcher.Req, fn conn ->
      assert get_req_header(conn, "accept") == [
               "image/avif,image/webp,image/png,image/jpeg"
             ]

      assert get_req_header(conn, "accept-encoding") == ["identity"]

      conn
      |> put_resp_content_type("image/png")
      |> send_resp(200, png)
    end)

    assert {:ok, %{body: ^png}} =
             Fetcher.Req.get("https://app.example/card.png", :asset)
  end

  test "rejects active image formats and oversized assets" do
    Req.Test.stub(Fetcher.Req, fn conn ->
      conn
      |> put_resp_content_type("image/svg+xml")
      |> send_resp(200, "<svg></svg>")
    end)

    assert {:error, :invalid_content_type} =
             Fetcher.Req.get("https://app.example/card.svg", :asset)

    Req.Test.stub(Fetcher.Req, fn conn ->
      conn
      |> put_resp_content_type("image/png")
      |> send_resp(200, String.duplicate("x", 5_000_001))
    end)

    assert {:error, :response_too_large} =
             Fetcher.Req.get("https://app.example/huge.png", :asset)
  end

  test "follows a bounded same-origin redirect after revalidation" do
    test_pid = self()

    Req.Test.stub(Fetcher.Req, fn conn ->
      send(test_pid, {:request_path, conn.request_path})

      case conn.request_path do
        "/start" ->
          Req.Test.redirect(conn, external: "https://app.example/redirected")

        "/redirected" ->
          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, "<html></html>")
      end
    end)

    assert {:ok, %{body: "<html></html>"}} =
             Fetcher.Req.get("https://app.example/start", :page)

    assert_receive {:request_path, "/start"}
    assert_receive {:request_path, "/redirected"}
  end

  test "canonicalizes scheme-relative and mixed-case same-origin redirects" do
    test_pid = self()

    expect(Egregoros.DNS.Mock, :lookup_ips, 3, fn "app.example" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    Req.Test.stub(Fetcher.Req, fn conn ->
      send(test_pid, {
        :canonical_redirect_request,
        conn.request_path,
        conn.host,
        get_req_header(conn, "host")
      })

      case conn.request_path do
        "/start" ->
          conn
          |> put_resp_header("location", "//APP.EXAMPLE.:443/middle")
          |> send_resp(302, "")

        "/middle" ->
          conn
          |> put_resp_header("location", "HTTPS://App.Example.:443/final")
          |> send_resp(302, "")

        "/final" ->
          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, "<html></html>")
      end
    end)

    assert {:ok, %{body: "<html></html>"}} =
             Fetcher.Req.get("https://app.example/start", :page)

    for path <- ~w(/start /middle /final) do
      assert_receive {:canonical_redirect_request, ^path, "93.184.216.34", ["app.example"]}
    end
  end

  test "rejects malformed redirect locations before another DNS lookup" do
    for location <- [
          "https://app.example/encoded%0dheader",
          "https://app.example/encoded%00nul",
          "https://app.example/bare%",
          "https://app.example/back\\slash"
        ] do
      expect(Egregoros.DNS.Mock, :lookup_ips, fn "app.example" ->
        {:ok, [{93, 184, 216, 34}]}
      end)

      Req.Test.stub(Fetcher.Req, fn conn ->
        conn
        |> put_resp_header("location", location)
        |> send_resp(302, "")
      end)

      assert {:error, :invalid_redirect} =
               Fetcher.Req.get("https://app.example/start", :page)
    end
  end

  test "revalidates redirects and refuses a cross-origin hop before connecting" do
    test_pid = self()

    expect(Egregoros.DNS.Mock, :lookup_ips, fn "app.example" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    expect(Egregoros.DNS.Mock, :lookup_ips, 0, fn "other.example" ->
      flunk("a cross-origin redirect must be rejected before DNS resolution")
    end)

    Req.Test.stub(Fetcher.Req, fn conn ->
      send(test_pid, {:request_path, conn.request_path})
      Req.Test.redirect(conn, external: "https://other.example/private")
    end)

    assert {:error, :redirect_origin_mismatch} =
             Fetcher.Req.get("https://app.example/start", :page)

    assert_receive {:request_path, "/start"}
    refute_receive {:request_path, "/private"}
  end

  test "caps same-origin redirect chains" do
    test_pid = self()

    Req.Test.stub(Fetcher.Req, fn conn ->
      send(test_pid, {:request_path, conn.request_path})
      next = conn.request_path |> String.trim_leading("/") |> String.to_integer() |> Kernel.+(1)
      Req.Test.redirect(conn, external: "https://app.example/#{next}")
    end)

    assert {:error, :too_many_redirects} =
             Fetcher.Req.get("https://app.example/0", :page)

    assert_receive {:request_path, "/0"}
    assert_receive {:request_path, "/1"}
    assert_receive {:request_path, "/2"}
    refute_receive {:request_path, "/3"}
  end

  test "rejects wrong content types" do
    Req.Test.stub(Fetcher.Req, fn conn -> Req.Test.text(conn, "{}") end)

    assert {:error, :invalid_content_type} =
             Fetcher.Req.get(
               "https://app.example/.well-known/fediverse-miniapp.json",
               :manifest
             )
  end

  test "rejects ambiguous content types and any encoded response body" do
    Req.Test.stub(Fetcher.Req, fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> prepend_resp_headers([{"content-type", "application/json"}])
      |> send_resp(200, "{}")
    end)

    assert {:error, :invalid_content_type} =
             Fetcher.Req.get(
               "https://app.example/.well-known/fediverse-miniapp.json",
               :manifest
             )

    Req.Test.stub(Fetcher.Req, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, :zlib.gzip("{}"))
    end)

    assert {:error, :encoded_response_not_allowed} =
             Fetcher.Req.get(
               "https://app.example/.well-known/fediverse-miniapp.json",
               :manifest
             )
  end

  test "rejects an oversized declared content length before retaining the body" do
    Req.Test.stub(Fetcher.Req, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-length", "65537")
      |> send_resp(200, "{}")
    end)

    assert {:error, :response_too_large} =
             Fetcher.Req.get(
               "https://app.example/.well-known/fediverse-miniapp.json",
               :manifest
             )
  end

  test "rejects a response whose declared length does not match streamed bytes" do
    Req.Test.stub(Fetcher.Req, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-length", "10")
      |> send_resp(200, "{}")
    end)

    assert {:error, :invalid_response_body} =
             Fetcher.Req.get(
               "https://app.example/.well-known/fediverse-miniapp.json",
               :manifest
             )
  end

  test "enforces the manifest response limit" do
    Req.Test.stub(Fetcher.Req, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, String.duplicate("a", 65_537))
    end)

    assert {:error, :response_too_large} =
             Fetcher.Req.get(
               "https://app.example/.well-known/fediverse-miniapp.json",
               :manifest
             )
  end

  test "rejects non-https and ip-literal urls before issuing a request" do
    Egregoros.DNS.Mock
    |> expect(:lookup_ips, 0, fn _host -> {:ok, [{93, 184, 216, 34}]} end)

    assert {:error, :unsafe_url} = Fetcher.Req.get("http://app.example/page", :page)
    assert {:error, :unsafe_url} = Fetcher.Req.get("https://93.184.216.34/page", :page)
  end

  test "rejects unsupported fetch kinds" do
    assert {:error, :unsupported_resource_kind} =
             Fetcher.Req.get("https://app.example/file", :script)
  end
end
