defmodule EgregorosWeb.E2EEControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Users

  defp register_user!(suffix) do
    {:ok, user} =
      Users.register_local_user(%{
        nickname: "alice-#{suffix}",
        email: "alice-#{suffix}@example.com",
        password: "very secure password"
      })

    user
  end

  defp public_key_jwk do
    %{
      "kty" => "EC",
      "crv" => "P-256",
      "x" => "pQECAwQFBgcICQoLDA0ODw",
      "y" => "AQIDBAUGBwgJCgsMDQ4PEA"
    }
  end

  defp mnemonic_payload(kid, wrapped_private_key) do
    %{
      "kid" => kid,
      "public_key_jwk" => public_key_jwk(),
      "wrapper" => %{
        "type" => "recovery_mnemonic_v1",
        "wrapped_private_key" => wrapped_private_key,
        "params" => %{
          "hkdf_salt" => Base.url_encode64("hkdf-salt", padding: false),
          "iv" => Base.url_encode64("iv", padding: false),
          "alg" => "A256GCM",
          "kdf" => "HKDF-SHA256",
          "info" => "egregoros:e2ee:wrap:mnemonic:v1"
        }
      }
    }
  end

  test "GET /settings/e2ee returns 401 when not logged in", %{conn: conn} do
    conn = get(conn, "/settings/e2ee")
    assert conn.status == 401
  end

  test "GET /settings/e2ee returns disabled status when no key is enabled", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    user = register_user!(uniq)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> get("/settings/e2ee")

    assert conn.status == 200
    assert %{"enabled" => false, "active_key" => nil, "wrappers" => []} = json_response(conn, 200)
  end

  test "POST /settings/e2ee/mnemonic enables E2EE and stores encrypted key material", %{
    conn: conn
  } do
    uniq = System.unique_integer([:positive])
    user = register_user!(uniq)

    kid = "e2ee-2025-12-26T00:00:00Z"

    wrapped_private_key_b64 =
      <<1, 2, 3, 4, 5, 6>>
      |> Base.url_encode64(padding: false)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/settings/e2ee/mnemonic", mnemonic_payload(kid, wrapped_private_key_b64))

    assert conn.status == 201
    decoded = json_response(conn, 201)
    assert decoded["kid"] == kid
    assert String.starts_with?(decoded["fingerprint"], "sha256:")

    conn = get(conn, "/settings/e2ee")
    assert conn.status == 200
    status = json_response(conn, 200)
    assert status["enabled"] == true
    assert status["active_key"]["kid"] == kid
    assert is_list(status["wrappers"])
    assert length(status["wrappers"]) == 1
  end

  test "POST /settings/e2ee/mnemonic returns 401 when not logged in", %{conn: conn} do
    kid = "e2ee-unauthorized"
    wrapped_private_key_b64 = Base.url_encode64(<<1, 2, 3>>, padding: false)

    conn = post(conn, "/settings/e2ee/mnemonic", mnemonic_payload(kid, wrapped_private_key_b64))

    assert conn.status == 401
    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  test "POST /settings/e2ee/mnemonic returns 409 when already enabled", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    user = register_user!(uniq)
    kid = "e2ee-already-enabled"
    wrapped_private_key_b64 = Base.url_encode64(<<1, 2, 3>>, padding: false)
    payload = mnemonic_payload(kid, wrapped_private_key_b64)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/settings/e2ee/mnemonic", payload)

    assert conn.status == 201

    conn = post(conn, "/settings/e2ee/mnemonic", payload)

    assert conn.status == 409
    assert %{"error" => "already_enabled"} = json_response(conn, 409)
  end

  test "POST /settings/e2ee/mnemonic returns 422 for invalid payloads", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    user = register_user!(uniq)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/settings/e2ee/mnemonic", %{})

    assert conn.status == 422
    assert %{"error" => "invalid_payload"} = json_response(conn, 422)
  end

  test "POST /settings/e2ee/mnemonic returns 422 for invalid base64 key material", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    user = register_user!(uniq)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/settings/e2ee/mnemonic", mnemonic_payload("e2ee-invalid-base64", "!!!not-b64!!!"))

    assert conn.status == 422
    assert %{"error" => "invalid_payload"} = json_response(conn, 422)
  end

  test "POST /settings/e2ee/mnemonic returns 422 for non-base64 key material", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    user = register_user!(uniq)

    payload =
      "e2ee-non-b64"
      |> mnemonic_payload(123)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/settings/e2ee/mnemonic", payload)

    assert conn.status == 422
    assert %{"error" => "invalid_payload"} = json_response(conn, 422)
  end

  test "POST /settings/e2ee/mnemonic returns 422 for invalid JWKs", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    user = register_user!(uniq)

    wrapped_private_key_b64 = Base.url_encode64(<<1, 2, 3>>, padding: false)

    payload =
      "e2ee-invalid-jwk"
      |> mnemonic_payload(wrapped_private_key_b64)
      |> Map.put("public_key_jwk", %{
        "kty" => "EC",
        "crv" => "P-256",
        "y" => "AQIDBAUGBwgJCgsMDQ4PEA"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/settings/e2ee/mnemonic", payload)

    assert conn.status == 422
    assert %{"error" => "invalid_payload"} = json_response(conn, 422)
  end

  test "POST /settings/e2ee/mnemonic returns 422 with details for invalid changesets", %{
    conn: conn
  } do
    uniq = System.unique_integer([:positive])
    user = register_user!(uniq)

    kid = String.duplicate("k", 256)
    wrapped_private_key_b64 = Base.url_encode64(<<1, 2, 3>>, padding: false)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/settings/e2ee/mnemonic", mnemonic_payload(kid, wrapped_private_key_b64))

    assert conn.status == 422

    assert %{"error" => "invalid_payload", "details" => %{"kid" => _}} =
             json_response(conn, 422)
  end

  describe "POST /settings/e2ee/actor_key" do
    test "returns 401 when not logged in", %{conn: conn} do
      conn =
        post(conn, "/settings/e2ee/actor_key", %{
          "actor_ap_id" => "https://remote.example/users/bob"
        })

      assert conn.status == 401
      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "returns 422 for invalid payload", %{conn: conn} do
      uniq = System.unique_integer([:positive])
      user = register_user!(uniq)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/settings/e2ee/actor_key", %{})

      assert conn.status == 422
      assert %{"error" => "invalid_payload"} = json_response(conn, 422)
    end

    test "returns remote actor key data when available", %{conn: conn} do
      uniq = System.unique_integer([:positive])
      user = register_user!(uniq)

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
              "x" => "pQECAwQFBgcICQoLDA0ODw",
              "y" => "AQIDBAUGBwgJCgsMDQ4PEA",
              "fingerprint" => "sha256:abc"
            }
          ]
        }
      }

      expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
        assert url == actor_ap_id
        {:ok, %{status: 200, body: actor, headers: []}}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/settings/e2ee/actor_key", %{"actor_ap_id" => actor_ap_id})

      assert conn.status == 200

      assert %{
               "actor_ap_id" => ^actor_ap_id,
               "key" => %{
                 "kid" => "e2ee-remote",
                 "jwk" => %{"kty" => "EC", "crv" => "P-256", "x" => _, "y" => _},
                 "fingerprint" => "sha256:abc"
               }
             } = json_response(conn, 200)
    end

    test "returns 404 when actor has no e2ee keys", %{conn: conn} do
      uniq = System.unique_integer([:positive])
      user = register_user!(uniq)

      actor_ap_id = "https://remote.example/users/bob"

      actor = %{
        "id" => actor_ap_id,
        "type" => "Person"
      }

      expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
        assert url == actor_ap_id
        {:ok, %{status: 200, body: actor, headers: []}}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/settings/e2ee/actor_key", %{"actor_ap_id" => actor_ap_id})

      assert conn.status == 404
      assert %{"error" => "no_e2ee_keys"} = json_response(conn, 404)
    end

    test "resolves handles via WebFinger when a handle is provided", %{conn: conn} do
      uniq = System.unique_integer([:positive])
      user = register_user!(uniq)

      handle = "@bob@remote.example"
      actor_ap_id = "https://remote.example/users/bob"

      jrd = %{
        "links" => [
          %{
            "rel" => "self",
            "type" => "application/activity+json",
            "href" => actor_ap_id
          }
        ]
      }

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
              "x" => "pQECAwQFBgcICQoLDA0ODw",
              "y" => "AQIDBAUGBwgJCgsMDQ4PEA",
              "fingerprint" => "sha256:abc"
            }
          ]
        }
      }

      expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
        assert url ==
                 "https://remote.example/.well-known/webfinger?resource=acct:bob@remote.example"

        {:ok, %{status: 200, body: jrd, headers: []}}
      end)

      expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
        assert url == actor_ap_id
        {:ok, %{status: 200, body: actor, headers: []}}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/settings/e2ee/actor_key", %{"handle" => handle})

      assert conn.status == 200

      assert %{"actor_ap_id" => ^actor_ap_id, "key" => %{"kid" => "e2ee-remote"}} =
               json_response(conn, 200)
    end

    test "falls back to signed fetch when the actor endpoint requires auth", %{conn: conn} do
      uniq = System.unique_integer([:positive])
      user = register_user!(uniq)

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
              "x" => "pQECAwQFBgcICQoLDA0ODw",
              "y" => "AQIDBAUGBwgJCgsMDQ4PEA",
              "fingerprint" => "sha256:abc"
            }
          ]
        }
      }

      expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
        assert url == actor_ap_id
        {:ok, %{status: 401, body: %{}, headers: []}}
      end)

      expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
        assert url == actor_ap_id
        {:ok, %{status: 200, body: Jason.encode!(actor), headers: []}}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/settings/e2ee/actor_key", %{"actor_ap_id" => actor_ap_id})

      assert conn.status == 200

      assert %{"actor_ap_id" => ^actor_ap_id, "key" => %{"kid" => "e2ee-remote"}} =
               json_response(conn, 200)
    end
  end
end
