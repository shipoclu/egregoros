defmodule Egregoros.E2EE.ActorKeysTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.E2EE
  alias Egregoros.E2EE.ActorKey
  alias Egregoros.E2EE.ActorKeys
  alias Egregoros.Repo
  alias Egregoros.Users

  test "resolve_actor_ap_id accepts local actor ids even when SafeURL would reject them" do
    {:ok, bob} = Users.create_local_user("bob")
    ap_id = bob.ap_id

    assert {:ok, ^ap_id} = ActorKeys.resolve_actor_ap_id(%{"actor_ap_id" => ap_id})
  end

  test "get_actor_key returns a local user's active key" do
    {:ok, bob} = Users.create_local_user("bob")
    enable_e2ee_key!(bob)

    assert {:ok, %{"kid" => "e2ee-bob"}} = ActorKeys.get_actor_key(bob.ap_id, nil)
  end

  test "list_actor_keys returns cached keys when ttl is disabled" do
    actor_ap_id = "https://remote.example/users/bob"

    stub(Egregoros.Config.Mock, :get, fn
      :e2ee_actor_keys_cache_ttl_seconds, _default -> 0
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      flunk("unexpected fetch for #{url}")
    end)

    insert_cached_key!(actor_ap_id, %{
      kid: "e2ee-remote",
      jwk: %{"kty" => "EC", "crv" => "P-256", "x" => "x", "y" => "y"},
      fingerprint: "sha256:abc",
      position: 0,
      present: true,
      fetched_at:
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)
    })

    assert {:ok, [%{"kid" => "e2ee-remote"} | _]} = ActorKeys.list_actor_keys(actor_ap_id)
  end

  test "list_actor_keys refreshes remote actor keys when the cache is stale" do
    actor_ap_id = "https://remote.example/users/bob"

    stub(Egregoros.Config.Mock, :get, fn
      :e2ee_actor_keys_cache_ttl_seconds, _default -> 1
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    insert_cached_key!(actor_ap_id, %{
      kid: "e2ee-old",
      jwk: %{"kty" => "EC", "crv" => "P-256", "x" => "oldx", "y" => "oldy"},
      fingerprint: "sha256:old",
      position: 0,
      present: true,
      fetched_at:
        DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:microsecond)
    })

    actor = %{
      "id" => actor_ap_id,
      "type" => "Person",
      "egregoros:e2ee" => %{
        "version" => 1,
        "keys" => [
          %{
            "kid" => "e2ee-new",
            "kty" => "EC",
            "crv" => "P-256",
            "x" => "newx",
            "y" => "newy",
            "fingerprint" => "sha256:new"
          }
        ]
      }
    }

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == actor_ap_id
      {:ok, %{status: 200, body: actor, headers: []}}
    end)

    assert {:ok, [%{"kid" => "e2ee-new"}, %{"kid" => "e2ee-old"}]} =
             ActorKeys.list_actor_keys(actor_ap_id)
  end

  test "get_actor_key uses the cached default key when it is fresh" do
    actor_ap_id = "https://remote.example/users/bob"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      flunk("unexpected fetch for #{url}")
    end)

    insert_cached_key!(actor_ap_id, %{
      kid: "e2ee-cached",
      jwk: %{"kty" => "EC", "crv" => "P-256", "x" => "x", "y" => "y"},
      fingerprint: "sha256:abc",
      position: 0,
      present: true,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })

    assert {:ok, %{"kid" => "e2ee-cached"}} = ActorKeys.get_actor_key(actor_ap_id, nil)
  end

  test "get_actor_key refreshes the default key when the cache is stale" do
    actor_ap_id = "https://remote.example/users/bob"

    stub(Egregoros.Config.Mock, :get, fn
      :e2ee_actor_keys_cache_ttl_seconds, _default -> 1
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    insert_cached_key!(actor_ap_id, %{
      kid: "e2ee-stale",
      jwk: %{"kty" => "EC", "crv" => "P-256", "x" => "stale", "y" => "stale"},
      fingerprint: "sha256:stale",
      position: 0,
      present: true,
      fetched_at:
        DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:microsecond)
    })

    actor = %{
      "id" => actor_ap_id,
      "type" => "Person",
      "egregoros:e2ee" => %{
        "version" => 1,
        "keys" => [
          %{
            "kid" => "e2ee-fresh",
            "kty" => "EC",
            "crv" => "P-256",
            "x" => "freshx",
            "y" => "freshy",
            "fingerprint" => "sha256:fresh"
          }
        ]
      }
    }

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == actor_ap_id
      {:ok, %{status: 200, body: actor, headers: []}}
    end)

    assert {:ok, %{"kid" => "e2ee-fresh"}} = ActorKeys.get_actor_key(actor_ap_id, nil)
  end

  test "list_actor_keys rejects unsafe remote URLs" do
    assert {:error, :invalid_payload} = ActorKeys.list_actor_keys("http://localhost/users/bob")
  end

  test "list_actor_keys caches remote keys after first fetch" do
    actor_ap_id = "https://remote.example/users/bob"

    actor = %{
      "id" => actor_ap_id,
      "type" => "Person",
      "egregoros:e2ee" => %{
        "version" => 1,
        "keys" => [
          %{
            "kid" => "e2ee-remote",
            "kty" => "EC",
            "crv" => "P-256",
            "x" => "x",
            "y" => "y",
            "fingerprint" => "sha256:abc"
          }
        ]
      }
    }

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == actor_ap_id
      {:ok, %{status: 200, body: actor, headers: []}}
    end)

    assert {:ok, [%{"kid" => "e2ee-remote"}]} = ActorKeys.list_actor_keys(actor_ap_id)
    assert {:ok, [%{"kid" => "e2ee-remote"}]} = ActorKeys.list_actor_keys(actor_ap_id)
  end

  test "get_actor_key returns a cached key by kid without refreshing" do
    actor_ap_id = "https://remote.example/users/bob"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      flunk("unexpected fetch for #{url}")
    end)

    insert_cached_key!(actor_ap_id, %{
      kid: "e2ee-remote-kid",
      jwk: %{"kty" => "EC", "crv" => "P-256", "x" => "x", "y" => "y"},
      fingerprint: "sha256:abc",
      position: 0,
      present: false,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })

    assert {:ok, %{"kid" => "e2ee-remote-kid"}} =
             ActorKeys.get_actor_key(actor_ap_id, "e2ee-remote-kid")
  end

  test "extract_actor_key selects the requested kid" do
    actor = %{
      "egregoros:e2ee" => %{
        "version" => 1,
        "keys" => [
          %{"kid" => "first", "kty" => "EC", "crv" => "P-256", "x" => "x1", "y" => "y1"},
          %{"kid" => "second", "kty" => "EC", "crv" => "P-256", "x" => "x2", "y" => "y2"}
        ]
      }
    }

    assert {:ok, %{"kid" => "second"}} = ActorKeys.extract_actor_key(actor, "second")
  end

  test "extract_actor_key defaults to the first key when kid is missing" do
    actor = %{
      "egregoros:e2ee" => %{
        "version" => 1,
        "keys" => [
          %{"kid" => "first", "kty" => "EC", "crv" => "P-256", "x" => "x1", "y" => "y1"},
          %{"kid" => "second", "kty" => "EC", "crv" => "P-256", "x" => "x2", "y" => "y2"}
        ]
      }
    }

    assert {:ok, %{"kid" => "first"}} = ActorKeys.extract_actor_key(actor, nil)
  end

  test "extract_actor_key returns an error when the actor has no keys" do
    assert {:error, :no_e2ee_keys} = ActorKeys.extract_actor_key(%{}, nil)
  end

  test "get_actor_key returns invalid_payload for blank actor ids" do
    assert {:error, :invalid_payload} = ActorKeys.get_actor_key("  ", nil)
  end

  test "get_actor_key rejects unsafe remote URLs" do
    assert {:error, :invalid_payload} = ActorKeys.get_actor_key("http://localhost/users/bob", nil)
  end

  test "list_actor_keys returns invalid_payload for blank actor ids" do
    assert {:error, :invalid_payload} = ActorKeys.list_actor_keys("  ")
  end

  test "get_actor_key returns no_e2ee_keys for local users without an active key" do
    {:ok, bob} = Users.create_local_user("bob")
    assert {:error, :no_e2ee_keys} = ActorKeys.get_actor_key(bob.ap_id, nil)
  end

  test "get_actor_key selects a local key by kid" do
    {:ok, bob} = Users.create_local_user("bob")
    enable_e2ee_key!(bob)

    assert {:ok, %{"kid" => "e2ee-bob"}} = ActorKeys.get_actor_key(bob.ap_id, "e2ee-bob")
  end

  test "get_actor_key caches remote keys after first fetch" do
    actor_ap_id = "https://remote.example/users/bob"

    actor = %{
      "id" => actor_ap_id,
      "type" => "Person",
      "egregoros:e2ee" => %{
        "version" => 1,
        "keys" => [
          %{
            "kid" => "e2ee-remote",
            "kty" => "EC",
            "crv" => "P-256",
            "x" => "x",
            "y" => "y",
            "fingerprint" => "sha256:abc"
          }
        ]
      }
    }

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == actor_ap_id
      {:ok, %{status: 200, body: actor, headers: []}}
    end)

    assert {:ok, %{"kid" => "e2ee-remote"}} = ActorKeys.get_actor_key(actor_ap_id, nil)
    assert {:ok, %{"kid" => "e2ee-remote"}} = ActorKeys.get_actor_key(actor_ap_id, nil)
  end

  test "fetch_actor returns invalid_json for non-JSON responses" do
    actor_ap_id = "https://remote.example/users/bob"

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == actor_ap_id
      {:ok, %{status: 200, body: "<html>not-json</html>", headers: []}}
    end)

    assert {:error, :invalid_json} = ActorKeys.fetch_actor(actor_ap_id)
  end

  test "get_actor_key returns no_e2ee_keys when the remote actor publishes none" do
    actor_ap_id = "https://remote.example/users/bob"

    actor = %{
      "id" => actor_ap_id,
      "type" => "Person"
    }

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == actor_ap_id
      {:ok, %{status: 200, body: actor, headers: []}}
    end)

    assert {:error, :no_e2ee_keys} = ActorKeys.get_actor_key(actor_ap_id, nil)
  end

  defp enable_e2ee_key!(user) do
    {:ok, %{key: key}} =
      E2EE.enable_key_with_wrapper(user, %{
        kid: "e2ee-bob",
        public_key_jwk: %{"kty" => "EC", "crv" => "P-256", "x" => "x", "y" => "y"},
        wrapper: %{
          type: "recovery_mnemonic_v1",
          wrapped_private_key: <<1, 2, 3>>,
          params: %{}
        }
      })

    key
  end

  defp insert_cached_key!(actor_ap_id, attrs) when is_binary(actor_ap_id) and is_map(attrs) do
    attrs = Map.put(attrs, :actor_ap_id, actor_ap_id)

    %ActorKey{}
    |> ActorKey.changeset(attrs)
    |> Repo.insert!()
  end
end
