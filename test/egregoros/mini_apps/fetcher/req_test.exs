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

  test "rejects redirects without following them" do
    test_pid = self()

    Req.Test.stub(Fetcher.Req, fn conn ->
      send(test_pid, {:request_path, conn.request_path})
      Req.Test.redirect(conn, external: "https://app.example/redirected")
    end)

    assert {:error, :redirect_not_allowed} =
             Fetcher.Req.get("https://app.example/start", :page)

    assert_receive {:request_path, "/start"}
    refute_receive {:request_path, "/redirected"}
  end

  test "rejects wrong content types" do
    Req.Test.stub(Fetcher.Req, fn conn -> Req.Test.text(conn, "{}") end)

    assert {:error, :invalid_content_type} =
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
