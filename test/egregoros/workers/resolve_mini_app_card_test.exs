defmodule Egregoros.Workers.ResolveMiniAppCardTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Cards
  alias Egregoros.Objects
  alias Egregoros.Workers.ResolveMiniAppCard

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "enqueues only eligible notes while mini apps are enabled" do
    public = note_fixture(~s(<a href="https://app.example/read">reader</a>))
    plain = note_fixture("nothing to resolve")

    assert :ok = ResolveMiniAppCard.maybe_enqueue(public)
    refute_enqueued(worker: ResolveMiniAppCard)

    enable_mini_apps()
    assert :ok = ResolveMiniAppCard.maybe_enqueue(public)
    assert :ok = ResolveMiniAppCard.maybe_enqueue(plain)

    assert_enqueued(
      worker: ResolveMiniAppCard,
      queue: "federation_incoming",
      args: %{"object_id" => public.id}
    )

    refute_enqueued(worker: ResolveMiniAppCard, args: %{"object_id" => plain.id})
  end

  test "resolves and stores a card asynchronously" do
    object = note_fixture(~s(<a href="https://app.example/read">reader</a>))
    enable_mini_apps()

    manifest =
      Jason.encode!(%{
        "version" => "1",
        "name" => "Reader",
        "homeUrl" => "https://app.example/",
        "capabilities" => [],
        "cacheTtlSeconds" => 600
      })

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 2, fn
      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        ok_response(manifest, "application/json")

      "https://app.example/read", :page ->
        ok_response("<html><body>Reader</body></html>", "text/html")
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert :ok =
               ResolveMiniAppCard.perform(%Oban.Job{args: %{"object_id" => object.id}})
    end)

    assert stored = Cards.get_active(object)
    assert stored.title == "Reader"
    assert stored.launch_url == "https://app.example/read"
  end

  test "clears a stale card when a note is no longer eligible" do
    object = note_fixture(~s(<a href="https://app.example/read">reader</a>))
    enable_mini_apps()
    stored_card_fixture(object)
    assert Cards.get_active(object)

    {:ok, object} = Objects.update_object(object, %{data: Map.put(object.data, "to", [])})

    assert :ok = ResolveMiniAppCard.perform(%Oban.Job{args: %{"object_id" => object.id}})
    assert Cards.get_active(object) == nil
  end

  test "discards malformed jobs and missing objects" do
    assert {:discard, :invalid_args} = ResolveMiniAppCard.perform(%Oban.Job{args: %{}})

    assert :ok =
             ResolveMiniAppCard.perform(%Oban.Job{args: %{"object_id" => Ecto.UUID.generate()}})
  end

  test "returns a retryable error when candidates cannot be resolved" do
    object = note_fixture(~s(<a href="https://app.example/read">reader</a>))
    enable_mini_apps()

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        {:error, :timeout}
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert {:error, :no_mini_app} =
               ResolveMiniAppCard.perform(%Oban.Job{args: %{"object_id" => object.id}})
    end)
  end

  test "does not enqueue an unpersisted note" do
    enable_mini_apps()

    note = %Egregoros.Object{
      type: "Note",
      data: %{
        "content" => ~s(<a href="https://app.example/read">reader</a>),
        "to" => [@public]
      }
    }

    assert :ok = ResolveMiniAppCard.maybe_enqueue(note)
    refute_enqueued(worker: ResolveMiniAppCard)
  end

  defp note_fixture(content) do
    {:ok, object} =
      Objects.create_object(%{
        ap_id: "https://social.example/notes/#{System.unique_integer([:positive])}",
        type: "Note",
        actor: "https://social.example/users/alice",
        data: %{
          "id" => "https://social.example/notes/worker-test",
          "type" => "Note",
          "content" => content,
          "to" => [@public]
        }
      })

    object
  end

  defp stored_card_fixture(object) do
    manifest = %Egregoros.MiniApps.Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      capabilities: [],
      cache_ttl_seconds: 600
    }

    card = %Egregoros.MiniApps.ResolvedCard{
      source_url: "https://app.example/read",
      app_origin: "https://app.example",
      app_name: "Reader",
      title: "Reader",
      button_title: "Open",
      launch_url: "https://app.example/read",
      manifest: manifest
    }

    Cards.put(object, card)
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end

  defp ok_response(body, content_type) do
    {:ok, %{status: 200, body: body, headers: [{"content-type", content_type}]}}
  end
end
