defmodule Egregoros.MiniApps.CardsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.MiniApps.Card
  alias Egregoros.Objects
  alias Egregoros.Repo
  alias Egregoros.Workers.ResolveMiniAppCard

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    enable_mini_apps()
    :ok
  end

  test "stores a derived card separately from canonical and internal object data" do
    object = object_fixture()
    original_data = object.data
    original_internal = object.internal

    assert {:ok, stored} = Cards.put(object, resolved_card("Chapter 2"))
    assert stored.object_id == object.id
    assert stored.source_url == "https://app.example/shared/chapter-2"
    assert stored.title == "Chapter 2"
    assert stored.expires_at == DateTime.add(stored.resolved_at, 600, :second)
    assert Cards.get_active(object) == stored
    assert Cards.list_active_for_objects([object]) == %{object.id => stored}
    assert Cards.list_active_for_objects([]) == %{}

    reloaded = Objects.get_by_ap_id(object.ap_id)
    assert reloaded.data == original_data
    assert reloaded.internal == original_internal
  end

  test "refreshes metadata without invalidating an unchanged app identity" do
    object = object_fixture()

    assert {:ok, first} = Cards.put(object, resolved_card("First"))
    assert {:ok, second} = Cards.put(object, resolved_card("Second"))

    assert first.id == second.id
    assert first.resolution_token == second.resolution_token
    assert Cards.active?(first)
    assert Cards.active?(second)
    assert Cards.get_active_by_id(second.id, second.resolution_token) == second
    assert Cards.get_active(object).title == "Second"
    assert Repo.aggregate(Card, :count) == 1
  end

  test "rotates identity when the exact source or launch URL changes" do
    object = object_fixture()

    assert {:ok, first} = Cards.put(object, resolved_card("First"))

    replacement = %{
      resolved_card("Second")
      | source_url: "https://app.example/shared/chapter-3",
        launch_url: "https://app.example/book/chapter-3"
    }

    assert {:ok, second} = Cards.put(object, replacement)

    assert first.id == second.id
    refute first.resolution_token == second.resolution_token
    refute Cards.active?(first)
    assert Cards.active?(second)
    assert Cards.get_active_by_id(first.id, first.resolution_token) == nil
  end

  test "pins security declarations before caching a resolved card" do
    object = object_fixture()
    resolved = resolved_card("Wallet", wallet?: true)

    assert {:ok, _card} = Cards.put(object, resolved)
    assert Declarations.wallet_enabled?("https://app.example")

    changed_wallet =
      put_in(resolved.manifest.wallet, [:evm, :required_chains], ["eip155:1"])

    changed_manifest = %{resolved.manifest | wallet: changed_wallet}
    changed = %{resolved | manifest: changed_manifest, title: "Changed"}

    assert {:error, :manifest_changed} = Cards.put(object, changed)
    assert Cards.get_active(object).title == "Wallet"
  end

  test "expired cards remain available while a unique revalidation is enqueued" do
    object = object_fixture()
    assert {:ok, stored} = Cards.put(object, resolved_card("Reader"))

    past = DateTime.add(DateTime.utc_now(), -1, :second)
    expired = stored |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

    assert Cards.get_active(object) == expired

    assert_enqueued(
      worker: ResolveMiniAppCard,
      args: %{"object_id" => object.id, "resolution_token" => stored.resolution_token}
    )

    assert Cards.get_active_by_id(stored.id, stored.resolution_token) == expired
    assert :ok = Cards.delete(object)
    assert Repo.get(Card, stored.id) == nil
  end

  test "cards beyond the bounded stale grace are hidden but still revalidated" do
    object = object_fixture()
    assert {:ok, stored} = Cards.put(object, resolved_card("Reader"))

    too_old = DateTime.add(DateTime.utc_now(), -3_601, :second)
    stored |> Ecto.Changeset.change(expires_at: too_old) |> Repo.update!()

    assert Cards.get_active(object) == nil

    assert_enqueued(
      worker: ResolveMiniAppCard,
      args: %{"object_id" => object.id, "resolution_token" => stored.resolution_token}
    )
  end

  test "refuses to persist a card whose URLs cross the app origin" do
    object = object_fixture()
    card = %{resolved_card("Reader") | launch_url: "https://evil.example/"}

    assert {:error, changeset} = Cards.put(object, card)
    assert "is not on the app origin" in errors_on(changeset).launch_url
  end

  test "feature and domain policy changes hide cached cards immediately" do
    object = object_fixture()
    assert {:ok, _stored} = Cards.put(object, resolved_card("Reader"))
    assert Cards.get_active(object)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> false
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    assert Cards.get_active(object) == nil

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    assert Cards.get_active(object) == nil
  end

  test "unpersisted objects cannot create, retrieve, or delete cache records" do
    object = %Egregoros.Object{type: "Note", data: %{}}

    assert {:error, changeset} = Cards.put(object, resolved_card("Reader"))
    assert "must identify a persisted object" in errors_on(changeset).object_id
    assert Cards.get_active(object) == nil
    assert Cards.delete(object) == :ok
  end

  defp object_fixture do
    {:ok, object} =
      Objects.create_object(%{
        ap_id: "https://social.example/notes/#{System.unique_integer([:positive])}",
        type: "Note",
        actor: "https://social.example/users/alice",
        data: %{
          "id" => "https://social.example/notes/card-test",
          "type" => "Note",
          "content" => ~s(<a href="https://app.example/shared/chapter-2">reader</a>),
          "to" => [@public]
        }
      })

    object
  end

  defp resolved_card(title, options \\ []) do
    wallet? = Keyword.get(options, :wallet?, false)

    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      wallet:
        if(wallet?,
          do: %{
            evm: %{enabled: true, required: false, required_chains: ["eip155:8453"]}
          },
          else: nil
        ),
      capabilities: [],
      cache_ttl_seconds: 600
    }

    %ResolvedCard{
      source_url: "https://app.example/shared/chapter-2",
      app_origin: "https://app.example",
      app_name: "Reader",
      title: title,
      button_title: "Read",
      launch_url: "https://app.example/book/chapter-2",
      image_url: "https://app.example/card.png",
      manifest: manifest
    }
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
