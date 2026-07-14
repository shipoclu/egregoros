defmodule Egregoros.MiniApps.DiagnosticTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Diagnostic
  alias Egregoros.MiniApps.Diagnostic.Report
  alias Egregoros.Keys

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

  test "probes distinct pages, declared images, rich metadata, and an ActivityPub actor" do
    home_url = @origin <> "/home"
    launch_url = @origin <> "/launch"
    icon_url = @origin <> "/icon.png"
    splash_url = @origin <> "/splash.png"
    card_image_url = @origin <> "/card.png"
    actor_url = @origin <> "/ap/actor"
    {public_key, _private_key} = Keys.generate_rsa_keypair()

    manifest = %{
      "version" => "1",
      "name" => "Reader",
      "homeUrl" => home_url,
      "iconUrl" => icon_url,
      "splash" => %{"imageUrl" => splash_url, "backgroundColor" => "#123456"},
      "activityPub" => %{
        "actorUrl" => actor_url,
        "publicNotes" => true,
        "transactionalMentions" => false
      },
      "capabilities" => []
    }

    metadata =
      Jason.encode!(%{
        "version" => "1",
        "title" => "Reader chapter",
        "buttonTitle" => "Read",
        "imageUrl" => card_image_url,
        "launchUrl" => launch_url
      })

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @manifest_url, :manifest ->
      response(Jason.encode!(manifest), json_headers())
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @url, :page ->
      response(~s|<meta name="fediverse:miniapp" content='#{metadata}'>|, good_headers())
    end)

    for page_url <- [home_url, launch_url] do
      expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn ^page_url, :page ->
        response("<html><body>Page</body></html>", good_headers())
      end)
    end

    for asset_url <- [icon_url, splash_url, card_image_url] do
      expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn ^asset_url, :asset ->
        response("image", asset_headers())
      end)
    end

    expect(Egregoros.MiniApps.ImageSanitizer.Mock, :sanitize, 3, fn "image", "image/png" ->
      {:ok, %{body: "safe-webp", content_type: "image/webp"}}
    end)

    actor = valid_actor(actor_url, public_key)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn ^actor_url, :actor ->
      response(Jason.encode!(actor), %{
        "content-type" => ["application/activity+json"],
        "x-content-type-options" => ["nosniff"],
        "strict-transport-security" => ["max-age=31536000"]
      })
    end)

    report = Diagnostic.run(@url, @host_origin)

    assert Report.required_pass?(report)
    assert report.resolved_card.title == "Reader chapter"
    assert report.resolved_card.launch_url == launch_url
    assert check(report, "manifest_icon_safe_image").status == :pass
    assert check(report, "splash_image_safe_image").status == :pass
    assert check(report, "card_image_safe_image").status == :pass
    assert check(report, "activity_pub_actor_document").status == :pass
  end

  test "reports optional fetch and actor-document failures without persisting trust" do
    icon_url = @origin <> "/icon.png"
    actor_url = @origin <> "/ap/actor"

    manifest = %{
      "version" => "1",
      "name" => "Reader",
      "homeUrl" => @url,
      "iconUrl" => icon_url,
      "activityPub" => %{
        "actorUrl" => actor_url,
        "publicNotes" => true,
        "transactionalMentions" => false
      },
      "capabilities" => []
    }

    expect_fetches(manifest, "<html><body>Reader</body></html>", good_headers())

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn ^icon_url, :asset ->
      {:error, :response_too_large}
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn ^actor_url, :actor ->
      response(~s|{"id":"#{actor_url}","type":"Application"}|, json_headers())
    end)

    report = Diagnostic.run(@url, @host_origin)

    refute Report.required_pass?(report)
    assert check(report, "manifest_icon_fetch").status == :fail
    assert check(report, "manifest_icon_fetch").detail =~ "size limit"
    assert check(report, "activity_pub_actor_document").status == :fail
  end

  test "reports malformed manifests, linked-page failures, and missing page policies" do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @manifest_url, :manifest ->
      response("not-json", json_headers())
    end)

    malformed_manifest = Diagnostic.run(@url, @host_origin)
    assert check(malformed_manifest, "manifest_parse").status == :fail

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @manifest_url, :manifest ->
      response(Jason.encode!(valid_manifest()), json_headers())
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @url, :page ->
      {:error, :redirect_origin_mismatch}
    end)

    failed_page = Diagnostic.run(@url, @host_origin)
    assert check(failed_page, "linked_page_fetch").status == :fail
    assert check(failed_page, "linked_page_fetch").detail =~ "redirect"

    expect_fetches(
      valid_manifest(),
      "<html><body>Reader</body></html>",
      [{"content-type", "text/html"}]
    )

    missing_headers = Diagnostic.run(@url, @host_origin)
    assert check(missing_headers, "linked_page_frame_ancestors").detail =~ "No enforced"
    assert check(missing_headers, "linked_page_permissions_policy").status == :fail
    assert check(missing_headers, "linked_page_hsts").status == :fail
  end

  test "contains both raised and thrown fetcher failures" do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @manifest_url, :manifest ->
      raise "remote adapter crashed"
    end)

    raised = Diagnostic.run(@url, @host_origin)
    assert check(raised, "diagnostic_internal").status == :fail

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @manifest_url, :manifest ->
      throw(:remote_adapter_threw)
    end)

    thrown = Diagnostic.run(@url, @host_origin)
    assert check(thrown, "diagnostic_internal").status == :fail
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

  defp valid_actor(actor_url, public_key) do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => actor_url,
      "type" => "Application",
      "preferredUsername" => "reader",
      "inbox" => @origin <> "/ap/inbox",
      "outbox" => @origin <> "/ap/outbox",
      "followers" => @origin <> "/ap/followers",
      "publicKey" => %{
        "id" => actor_url <> "#main-key",
        "owner" => actor_url,
        "publicKeyPem" => public_key
      }
    }
  end

  defp response(body, headers), do: {:ok, %{status: 200, body: body, headers: headers}}

  defp json_headers, do: replace_header(good_headers(), "content-type", "application/json")
  defp asset_headers, do: replace_header(good_headers(), "content-type", "image/png")

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
