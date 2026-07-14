defmodule Egregoros.MiniApps.ActorActivationTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Keys
  alias Egregoros.MiniApps.ActorActivation
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.Workers.ActivateMiniAppActor

  @origin "https://app.example"
  @actor @origin <> "/ap/actor"

  setup do
    enable_mini_apps()
    {public_key, _private_key} = Keys.generate_rsa_keypair()
    %{public_key: public_key}
  end

  test "keeps the actor capability disabled until a valid document is pinned", %{
    public_key: public_key
  } do
    assert {:ok, declaration, :created} = Declarations.ensure(manifest_fixture())
    refute declaration.activity_pub_actor_activated_at
    refute declaration.activity_pub_actor_fingerprint
    assert {:error, :actor_not_activated} = Declarations.notification_actor(@origin)

    assert_enqueued(
      worker: ActivateMiniAppActor,
      queue: "federation_incoming",
      args: %{"app_origin" => @origin}
    )

    expect_actor_fetch(valid_actor(public_key))

    assert :ok =
             perform_job(ActivateMiniAppActor, %{"app_origin" => @origin})

    activated = Declarations.get_by_origin(@origin)
    assert activated.activity_pub_actor_activated_at
    assert byte_size(activated.activity_pub_actor_fingerprint) == 32
    assert activated.activity_pub_actor_key_id == @actor <> "#main-key"
    assert byte_size(activated.activity_pub_actor_key_fingerprint) == 32
    assert activated.activity_pub_actor_public_key_pem == public_key
    assert {:ok, @actor} = Declarations.notification_actor(@origin)

    [entry] = :public_key.pem_decode(public_key)
    key = :public_key.pem_entry_decode(entry)

    assert :ok =
             ActorActivation.authorize_signing_key(@actor, @actor <> "#main-key", key)

    assert {:ok, ^key} =
             ActorActivation.pinned_signing_key(@actor, @actor <> "#main-key")

    {other_public_key, _other_private_key} = Keys.generate_rsa_keypair()
    [other_entry] = :public_key.pem_decode(other_public_key)
    other_key = :public_key.pem_entry_decode(other_entry)

    assert {:error, :mini_app_actor_key_mismatch} =
             ActorActivation.authorize_signing_key(@actor, @actor <> "#main-key", other_key)

    assert {:error, :mini_app_actor_key_mismatch} =
             ActorActivation.authorize_signing_key(@actor, @actor <> "#rotated-key", key)
  end

  test "validates a manifest actor document without creating or pinning a declaration", %{
    public_key: public_key
  } do
    manifest = manifest_fixture()

    assert :ok =
             ActorActivation.validate_document(
               Jason.encode!(valid_actor(public_key)),
               manifest
             )

    assert Declarations.get_by_origin(@origin) == nil
  end

  test "does not refetch or silently repin an activated actor", %{public_key: public_key} do
    assert {:ok, _declaration, :created} = Declarations.ensure(manifest_fixture())
    expect_actor_fetch(valid_actor(public_key))
    assert {:ok, first} = ActorActivation.activate(@origin)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("an activated actor must remain pinned")
    end)

    assert {:ok, second} = ActorActivation.activate(@origin)
    assert second.activity_pub_actor_fingerprint == first.activity_pub_actor_fingerprint
    assert second.activity_pub_actor_activated_at == first.activity_pub_actor_activated_at
  end

  test "a declared actor never falls back to a signature-triggered network fetch" do
    assert {:ok, _declaration, :created} = Declarations.ensure(manifest_fixture())

    assert {:error, :mini_app_actor_not_activated} =
             ActorActivation.pinned_signing_key(@actor, @actor <> "#main-key")

    assert {:error, :mini_app_actor_not_activated} =
             ActorActivation.pinned_signing_key(@actor, @actor <> "#other-key")
  end

  test "backfills a legacy activation only when the pinned actor fingerprint is unchanged", %{
    public_key: public_key
  } do
    assert {:ok, _declaration, :created} = Declarations.ensure(manifest_fixture())
    expect_actor_fetch(valid_actor(public_key))
    assert {:ok, activated} = ActorActivation.activate(@origin)

    activated
    |> Ecto.Changeset.change(%{
      activity_pub_actor_key_id: nil,
      activity_pub_actor_key_fingerprint: nil,
      activity_pub_actor_public_key_pem: nil
    })
    |> Repo.update!()

    expect_actor_fetch(valid_actor(public_key))
    assert {:ok, backfilled} = ActorActivation.activate(@origin)
    assert backfilled.activity_pub_actor_key_id == @actor <> "#main-key"
    assert byte_size(backfilled.activity_pub_actor_key_fingerprint) == 32
    assert backfilled.activity_pub_actor_fingerprint == activated.activity_pub_actor_fingerprint
  end

  test "rejects identity, type, endpoint, key ownership, and key material violations", %{
    public_key: public_key
  } do
    invalid_kinds = [
      :id,
      :type,
      :key_owner,
      :unsafe_inbox,
      :cross_origin_outbox,
      :cross_origin_followers,
      :cross_origin_key,
      :unbound_key,
      :invalid_key,
      :oversized_key,
      :even_modulus_key
    ]

    Enum.with_index(invalid_kinds, fn invalid_kind, index ->
      origin = "https://app#{index}.example"
      actor = origin <> "/ap/actor"

      document =
        public_key
        |> valid_actor()
        |> rewrite_origin(origin, actor)
        |> invalidate(invalid_kind, origin, actor)

      assert {:ok, _declaration, :created} = Declarations.ensure(manifest_fixture(origin, actor))
      expect_actor_fetch(document, actor)
      assert {:error, :invalid_actor_document} = ActorActivation.activate(origin)
      assert {:error, :actor_not_activated} = Declarations.notification_actor(origin)
    end)
  end

  test "rejects duplicate-key JSON and treats fetch failures as retryable" do
    assert {:ok, _declaration, :created} = Declarations.ensure(manifest_fixture())

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @actor, :actor ->
      {:ok,
       %{
         status: 200,
         body: ~s|{"id":"#{@actor}","id":"#{@actor}"}|,
         headers: [{"content-type", "application/activity+json"}]
       }}
    end)

    assert {:discard, :invalid_actor_document} =
             perform_job(ActivateMiniAppActor, %{"app_origin" => @origin})

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @actor, :actor ->
      {:error, :timeout}
    end)

    assert {:error, :timeout} =
             perform_job(ActivateMiniAppActor, %{"app_origin" => @origin})
  end

  defp expect_actor_fetch(document, actor_url \\ @actor) do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn ^actor_url, :actor ->
      {:ok,
       %{
         status: 200,
         body: Jason.encode!(document),
         headers: [{"content-type", "application/activity+json"}]
       }}
    end)
  end

  defp valid_actor(public_key) do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => @actor,
      "type" => "Application",
      "preferredUsername" => "app",
      "inbox" => @origin <> "/ap/inbox",
      "outbox" => @origin <> "/ap/outbox",
      "followers" => @origin <> "/ap/followers",
      "publicKey" => %{
        "id" => @actor <> "#main-key",
        "owner" => @actor,
        "publicKeyPem" => public_key
      }
    }
  end

  defp rewrite_origin(document, origin, actor) do
    document
    |> Map.put("id", actor)
    |> Map.update!("inbox", &String.replace(&1, @origin, origin))
    |> Map.update!("outbox", &String.replace(&1, @origin, origin))
    |> Map.update!("followers", &String.replace(&1, @origin, origin))
    |> update_in(["publicKey", "id"], &String.replace(&1, @origin, origin))
    |> update_in(["publicKey", "owner"], &String.replace(&1, @origin, origin))
  end

  defp invalidate(document, :id, _origin, actor),
    do: Map.put(document, "id", actor <> "/other")

  defp invalidate(document, :type, _origin, _actor), do: Map.put(document, "type", "Person")

  defp invalidate(document, :key_owner, _origin, actor),
    do: put_in(document, ["publicKey", "owner"], actor <> "/other")

  defp invalidate(document, :unsafe_inbox, _origin, _actor),
    do: Map.put(document, "inbox", "http://127.0.0.1/inbox")

  defp invalidate(document, :cross_origin_outbox, _origin, _actor),
    do: Map.put(document, "outbox", "https://other.example/outbox")

  defp invalidate(document, :cross_origin_followers, _origin, _actor),
    do: Map.put(document, "followers", "https://other.example/followers")

  defp invalidate(document, :cross_origin_key, _origin, _actor),
    do: put_in(document, ["publicKey", "id"], "https://other.example/key#main")

  defp invalidate(document, :unbound_key, origin, _actor),
    do: put_in(document, ["publicKey", "id"], origin <> "/keys/1")

  defp invalidate(document, :invalid_key, _origin, _actor),
    do: put_in(document, ["publicKey", "publicKeyPem"], "not a PEM key")

  defp invalidate(document, :oversized_key, _origin, _actor) do
    modulus = :erlang.bsl(1, 9_000) + 1
    der = :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, modulus, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPublicKey, {:RSAPublicKey, modulus, 65_537})
    true = byte_size(der) < 16_384

    put_in(document, ["publicKey", "publicKeyPem"], :public_key.pem_encode([entry]))
  end

  defp invalidate(document, :even_modulus_key, _origin, _actor) do
    modulus = :erlang.bsl(1, 2_047) + 2
    entry = :public_key.pem_entry_encode(:RSAPublicKey, {:RSAPublicKey, modulus, 65_537})

    put_in(document, ["publicKey", "publicKeyPem"], :public_key.pem_encode([entry]))
  end

  defp manifest_fixture(origin \\ @origin, actor \\ @actor) do
    attrs = %{
      "version" => "1",
      "name" => "Actor app",
      "homeUrl" => origin <> "/",
      "oauth" => %{
        "redirectUris" => [origin <> "/oauth/callback"],
        "scopes" => ["identify"]
      },
      "activityPub" => %{
        "actorUrl" => actor,
        "publicNotes" => true,
        "transactionalMentions" => true
      },
      "capabilities" => []
    }

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(attrs),
               origin <> "/.well-known/fediverse-miniapp.json"
             )

    manifest
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
