defmodule Egregoros.MiniAppsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Egregoros.MiniApps
  alias Egregoros.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "is disabled by default" do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> false
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      refute MiniApps.enabled?()
    end)
  end

  test "recognizes explicit enabled values" do
    for configured <- [true, "true", 1, "1"] do
      stub(Egregoros.Config.Mock, :get, fn
        :mini_apps_enabled, false -> configured
        key, default -> Egregoros.Config.Stub.get(key, default)
      end)

      Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
        assert MiniApps.enabled?()
      end)
    end
  end

  test "does not treat other values as enabled" do
    for configured <- [false, nil, "false", "yes", 0, "0"] do
      stub(Egregoros.Config.Mock, :get, fn
        :mini_apps_enabled, false -> configured
        key, default -> Egregoros.Config.Stub.get(key, default)
      end)

      Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
        refute MiniApps.enabled?()
      end)
    end
  end

  test "does not fetch a manifest while the feature is disabled" do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> false
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("disabled mini apps must not make network requests")
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert {:error, :disabled} = MiniApps.fetch_manifest("https://app.example")
    end)
  end

  test "does not fetch a manifest for a denied domain" do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("denied domains must not make network requests")
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert {:error, :domain_denied} = MiniApps.fetch_manifest("https://app.example")
    end)
  end

  test "does not allow a configured public instance hostname as a mini-app domain" do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      :public_host_aliases, [] -> ["App.Example."]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("the instance cookie hostname must be rejected before any network request")
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      refute MiniApps.domain_allowed?("app.example")
      assert {:error, :domain_denied} = MiniApps.fetch_manifest("https://app.example:444")
    end)
  end

  test "fetches and validates a manifest only after feature and policy checks" do
    json =
      Jason.encode!(%{
        "version" => "1",
        "name" => "Reader",
        "homeUrl" => "https://app.example/",
        "capabilities" => []
      })

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> ["app.example"]
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        {:ok, %{status: 200, body: json, headers: [{"content-type", "application/json"}]}}
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert {:ok, manifest} = MiniApps.fetch_manifest("https://app.example")
      assert manifest.name == "Reader"
    end)
  end

  test "rejects malformed origins before policy or fetch" do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("malformed origins must not make network requests")
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert {:error, :invalid_origin} = MiniApps.fetch_manifest("http://app.example")
      assert {:error, :invalid_origin} = MiniApps.fetch_manifest("https://app.example/path")
    end)
  end

  test "resolves the first valid candidate and uses exact page metadata" do
    manifest = manifest_json("Reader")

    card =
      Jason.encode!(%{
        "version" => "1",
        "title" => "Chapter 2",
        "imageUrl" => "https://app.example/chapter.png",
        "buttonTitle" => "Read",
        "launchUrl" => "https://app.example/book/chapter-2"
      })

    enable_mini_apps()

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 3, fn
      "https://ordinary.example/.well-known/fediverse-miniapp.json", :manifest ->
        {:error, {:unexpected_status, 404}}

      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        ok_response(manifest, "application/json")

      "https://app.example/shared/chapter-2?mode=focus", :page ->
        html = ~s(<meta name="fediverse:miniapp" content='#{html_escape(card)}'>)
        ok_response(html, "text/html")
    end)

    note =
      public_note(
        ~s(<a href="https://ordinary.example/a">ordinary</a>) <>
          ~s(<a href="https://app.example/shared/chapter-2?mode=focus">reader</a>)
      )

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert {:ok, resolved} = MiniApps.resolve_note(note)
      assert resolved.source_url == "https://app.example/shared/chapter-2?mode=focus"
      assert resolved.app_origin == "https://app.example"
      assert resolved.app_name == "Reader"
      assert resolved.title == "Chapter 2"
      assert resolved.button_title == "Read"
      assert resolved.launch_url == "https://app.example/book/chapter-2"
      assert resolved.image_url == "https://app.example/chapter.png"
    end)
  end

  test "uses the generic manifest card when page metadata is absent or invalid" do
    for page_html <- ["<html><body>Reader</body></html>", invalid_card_meta()] do
      manifest = manifest_json("Reader", "https://app.example/icon.png")
      enable_mini_apps()

      expect(Egregoros.MiniApps.Fetcher.Mock, :get, 2, fn
        "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
          ok_response(manifest, "application/json")

        "https://app.example/exact?chapter=2", :page ->
          ok_response(page_html, "text/html")
      end)

      Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
        assert {:ok, resolved} =
                 MiniApps.resolve_note(
                   public_note(~s(<a href="https://app.example/exact?chapter=2">reader</a>))
                 )

        assert resolved.title == "Reader"
        assert resolved.button_title == "Open"
        assert resolved.launch_url == "https://app.example/exact?chapter=2"
        assert resolved.image_url == "https://app.example/icon.png"
      end)
    end
  end

  test "does not fetch or resolve cards for disabled or non-public notes" do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("ineligible notes must not make network requests")
    end)

    assert {:error, :disabled} =
             MiniApps.resolve_note(public_note(~s(<a href="https://app.example/">app</a>)))

    enable_mini_apps()

    unlisted = %Object{
      type: "Note",
      data: %{
        "content" => ~s(<a href="https://app.example/">app</a>),
        "to" => [],
        "cc" => [@public]
      }
    }

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert {:error, :no_mini_app} = MiniApps.resolve_note(unlisted)
    end)
  end

  test "rechecks operator policy before fetching the linked page" do
    manifest = manifest_json("Reader")
    Process.put(:mini_app_policy_reads, 0)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false ->
        true

      :mini_apps_domain_allowlist, [] ->
        []

      :mini_apps_domain_denylist, [] ->
        reads = Process.get(:mini_app_policy_reads, 0)
        Process.put(:mini_app_policy_reads, reads + 1)
        if reads == 0, do: [], else: ["app.example"]

      key, default ->
        Egregoros.Config.Stub.get(key, default)
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        ok_response(manifest, "application/json")
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert {:error, :no_mini_app} =
               MiniApps.resolve_note(
                 public_note(~s(<a href="https://app.example/read">reader</a>))
               )
    end)
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end

  defp public_note(content) do
    %Object{type: "Note", data: %{"content" => content, "to" => [@public]}}
  end

  defp manifest_json(name, icon_url \\ nil) do
    %{
      "version" => "1",
      "name" => name,
      "homeUrl" => "https://app.example/",
      "capabilities" => []
    }
    |> then(fn manifest ->
      if icon_url, do: Map.put(manifest, "iconUrl", icon_url), else: manifest
    end)
    |> Jason.encode!()
  end

  defp invalid_card_meta do
    json = Jason.encode!(%{"version" => "1", "title" => "missing fields"})
    ~s(<meta name="fediverse:miniapp" content='#{html_escape(json)}'>)
  end

  defp html_escape(value), do: String.replace(value, "\"", "&quot;")

  defp ok_response(body, content_type) do
    {:ok, %{status: 200, body: body, headers: [{"content-type", content_type}]}}
  end
end
