defmodule Egregoros.MiniApps.LaunchContextTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.LaunchContext
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Objects

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    :ok
  end

  test "returns a bounded DTO containing only documented public launch fields" do
    card = card_fixture()

    assert {:ok, context} = LaunchContext.for_card(card)

    assert context == %{
             "version" => "1",
             "launchUrl" => "https://app.example/read?chapter=2",
             "sourceUrl" => "https://app.example/shared?chapter=2",
             "note" => %{
               "id" => "https://social.example/notes/context",
               "url" => "https://social.example/notes/context",
               "content" => "Hello @bob",
               "author" => "https://social.example/users/alice",
               "mentions" => ["https://social.example/users/bob"]
             }
           }

    refute inspect(context) =~ "internal-secret"
    refute inspect(context) =~ "followers"
    refute inspect(context) =~ "current_user"
  end

  test "fails closed if the source note is no longer fully public" do
    card = card_fixture()
    object = Objects.get_by_ap_id("https://social.example/notes/context")
    assert {:ok, _object} = Objects.update_object(object, %{data: Map.put(object.data, "to", [])})

    assert {:error, :ineligible_note} = LaunchContext.for_card(card)
  end

  test "uses empty bounded fields when optional public content is malformed" do
    card = card_fixture()
    object = Objects.get_by_ap_id("https://social.example/notes/context")

    assert {:ok, _object} =
             Objects.update_object(object, %{
               data: object.data |> Map.put("content", nil) |> Map.put("tag", nil)
             })

    assert {:ok, %{"note" => note}} = LaunchContext.for_card(card)
    assert note["content"] == ""
    assert note["mentions"] == []
    assert {:error, :ineligible_note} = LaunchContext.for_card(nil)
  end

  defp card_fixture do
    {:ok, object} =
      Objects.create_object(%{
        ap_id: "https://social.example/notes/context",
        type: "Note",
        actor: "https://social.example/users/alice",
        internal: %{"private" => "internal-secret"},
        data: %{
          "id" => "https://social.example/notes/context",
          "type" => "Note",
          "content" =>
            "<p>Hello <a class=\"mention\" href=\"https://social.example/users/bob\">@bob</a></p>",
          "to" => [@public],
          "cc" => ["https://social.example/users/alice/followers"],
          "tag" => [
            %{
              "type" => "Mention",
              "href" => "https://social.example/users/bob",
              "name" => "@bob"
            }
          ]
        }
      })

    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      capabilities: [],
      cache_ttl_seconds: 600
    }

    resolved = %ResolvedCard{
      source_url: "https://app.example/shared?chapter=2",
      app_origin: "https://app.example",
      app_name: "Reader",
      title: "Reader",
      button_title: "Read",
      launch_url: "https://app.example/read?chapter=2",
      manifest: manifest
    }

    {:ok, card} = Cards.put(object, resolved)
    card
  end
end
