defmodule Egregoros.MiniApps.DiagnosticTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Diagnostic
  alias Egregoros.MiniApps.Diagnostic.Report

  @origin "https://app.example"
  @url @origin <> "/reader"
  @manifest_url @origin <> "/.well-known/fediverse-miniapp.json"
  @host_origin "https://social.example"

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    :ok
  end

  test "reports a minimal generic miniapp as conformant" do
    expect_fetches(valid_manifest(), "<html><body>Reader</body></html>", good_headers())

    report = Diagnostic.run(@url, @host_origin)

    assert %Report{resolved_card: %{launch_url: @url, title: "Reader"}} = report
    assert Report.required_pass?(report)
    assert check(report, "manifest_parse").status == :pass
    assert check(report, "linked_page_frame_ancestors").status == :pass
    assert check(report, "home_page_permissions_policy").status == :pass
  end

  test "keeps a detected card available while reporting unsafe framing headers" do
    headers =
      good_headers()
      |> replace_header("content-security-policy", "default-src 'self'; frame-ancestors 'none'")
      |> then(&[{"x-frame-options", "DENY"} | &1])

    expect_fetches(valid_manifest(), "<html><body>Reader</body></html>", headers)

    report = Diagnostic.run(@url, @host_origin)

    assert report.resolved_card.launch_url == @url
    refute Report.required_pass?(report)
    assert check(report, "linked_page_frame_ancestors").status == :fail
    assert check(report, "linked_page_x_frame_options").status == :fail
  end

  test "reports invalid rich metadata and falls back only for diagnostic display" do
    metadata =
      Jason.encode!(%{
        "version" => "1",
        "title" => "Reader chapter",
        "buttonTitle" => "Read",
        "imageUrl" => "https://cdn.example/card.png",
        "launchUrl" => @url
      })

    html = ~s|<meta name="fediverse:miniapp" content='#{metadata}'>|
    expect_fetches(valid_manifest(), html, good_headers())

    report = Diagnostic.run(@url, @host_origin)

    assert report.resolved_card.title == "Reader"
    assert check(report, "page_metadata").status == :fail
    refute Report.required_pass?(report)
  end

  test "rejects an unsafe input before making a network request" do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("unsafe URLs must not reach the fetcher")
    end)

    report = Diagnostic.run("http://127.0.0.1/admin", @host_origin)

    assert report.resolved_card == nil
    assert check(report, "input_url").status == :fail
  end

  defp expect_fetches(manifest, html, page_headers) do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @manifest_url, :manifest ->
      {:ok,
       %{
         status: 200,
         body: Jason.encode!(manifest),
         headers: replace_header(good_headers(), "content-type", "application/json")
       }}
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @url, :page ->
      {:ok,
       %{
         status: 200,
         body: html,
         headers: page_headers
       }}
    end)
  end

  defp valid_manifest do
    %{
      "version" => "1",
      "name" => "Reader",
      "homeUrl" => @url,
      "capabilities" => []
    }
  end

  defp good_headers do
    [
      {"content-type", "text/html; charset=utf-8"},
      {"content-security-policy",
       "default-src 'self'; object-src 'none'; frame-ancestors #{@host_origin}"},
      {"x-content-type-options", "nosniff"},
      {"referrer-policy", "no-referrer"},
      {"permissions-policy",
       "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=(), hid=(), midi=(), display-capture=()"},
      {"strict-transport-security", "max-age=31536000"}
    ]
  end

  defp replace_header(headers, name, value) do
    [{name, value} | Enum.reject(headers, fn {key, _value} -> key == name end)]
  end

  defp check(report, id), do: Enum.find(report.checks, &(&1.id == id))
end
