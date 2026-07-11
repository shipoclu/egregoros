defmodule Egregoros.MiniApps.ComposeDraftTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.ComposeDraft
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

    %{card: card_fixture()}
  end

  test "normalizes a bounded draft and only permits replying to the public launch note", %{
    card: card
  } do
    draft = %{
      "text" => "I finished it",
      "spoilerText" => "Result",
      "language" => "en-GB",
      "visibility" => "followers",
      "inReplyTo" => "https://social.example/notes/launch",
      "links" => ["https://app.example/result/1", "https://other.example/details"]
    }

    assert {:ok, prepared} = ComposeDraft.prepare(card, draft)

    assert prepared == %{
             "content" =>
               "I finished it\n\nhttps://app.example/result/1\nhttps://other.example/details",
             "spoiler_text" => "Result",
             "language" => "en-GB",
             "visibility" => "followers",
             "in_reply_to" => "https://social.example/notes/launch"
           }

    assert {:error, :invalid_reply_target} =
             ComposeDraft.prepare(card, %{
               draft
               | "inReplyTo" => "https://social.example/notes/other"
             })

    launch_note = Objects.get_by_ap_id("https://social.example/notes/launch")
    {:ok, _} = Objects.update_object(launch_note, %{data: Map.put(launch_note.data, "to", [])})
    assert {:error, :invalid_reply_target} = ComposeDraft.prepare(card, draft)
  end

  test "rejects unknown fields, unsafe links, invalid visibility, and oversized content", %{
    card: card
  } do
    assert {:error, :invalid_draft} = ComposeDraft.prepare(card, %{"media" => []})

    assert {:error, :invalid_link} =
             ComposeDraft.prepare(card, %{"links" => ["http://app.example/result"]})

    assert {:error, :invalid_link} =
             ComposeDraft.prepare(card, %{
               "links" => ["https://app.example/result%0d%0aInjected"]
             })

    assert {:error, :invalid_visibility} =
             ComposeDraft.prepare(card, %{"visibility" => "private"})

    assert {:error, :invalid_language} =
             ComposeDraft.prepare(card, %{"language" => "not a language tag!"})

    assert {:error, :too_long} =
             ComposeDraft.prepare(card, %{"text" => String.duplicate("x", 5_001)})
  end

  test "validates edited host form values and maps followers visibility to publishing scope" do
    params = %{
      "content" => "Edited by the user",
      "spoiler_text" => "",
      "language" => "ja",
      "visibility" => "followers"
    }

    assert {:ok, publish} = ComposeDraft.validate_form(params)
    assert publish.content == "Edited by the user"
    assert publish.visibility == "private"
    assert publish.scope == "followers"
    assert publish.language == "ja"

    assert {:error, :invalid_visibility} =
             ComposeDraft.validate_form(%{params | "visibility" => "hidden"})
  end

  test "fails closed for malformed draft and edited-form value types", %{card: card} do
    assert {:error, :invalid_draft} = ComposeDraft.prepare(nil, %{})
    assert {:error, :invalid_draft} = ComposeDraft.prepare(card, nil)
    assert {:error, :invalid_draft} = ComposeDraft.prepare(card, %{"text" => 42})
    assert {:error, :invalid_reply_target} = ComposeDraft.prepare(card, %{"inReplyTo" => 42})

    assert {:error, :invalid_link} =
             ComposeDraft.prepare(card, %{
               "links" => List.duplicate("https://app.example/result", 9)
             })

    assert {:error, :invalid_link} =
             ComposeDraft.prepare(card, %{
               "links" => ["https://user:password@app.example/result"]
             })

    assert {:error, :invalid_draft} = ComposeDraft.validate_form(nil)
    assert {:error, :invalid_draft} = ComposeDraft.validate_form(%{"content" => 42})

    assert {:error, :too_long} =
             ComposeDraft.validate_form(%{"spoiler_text" => String.duplicate("x", 501)})

    assert {:error, :invalid_language} =
             ComposeDraft.validate_form(%{"language" => "invalid language"})
  end

  defp card_fixture do
    {:ok, object} =
      Objects.create_object(%{
        ap_id: "https://social.example/notes/launch",
        type: "Note",
        actor: "https://social.example/users/alice",
        data: %{
          "id" => "https://social.example/notes/launch",
          "type" => "Note",
          "content" => "Launch",
          "to" => [@public],
          "cc" => ["https://social.example/users/alice/followers"]
        }
      })

    manifest = %Manifest{
      version: "1",
      name: "Writer",
      origin: "https://app.example",
      home_url: "https://app.example/",
      oauth: %{
        redirect_uris: ["https://app.example/oauth/callback"],
        scopes: ["read", "write"]
      },
      capabilities: ["compose_note"],
      cache_ttl_seconds: 600
    }

    {:ok, card} =
      Cards.put(object, %ResolvedCard{
        source_url: "https://app.example/shared",
        app_origin: "https://app.example",
        app_name: "Writer",
        title: "Write",
        button_title: "Open",
        launch_url: "https://app.example/write",
        manifest: manifest
      })

    card
  end
end
