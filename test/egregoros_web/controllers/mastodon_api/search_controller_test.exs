defmodule EgregorosWeb.MastodonAPI.SearchControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Users

  test "GET /api/v2/search returns matching local accounts", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, _bob} = Users.create_local_user("bob")

    conn = get(conn, "/api/v2/search", %{"q" => "ali"})
    response = json_response(conn, 200)

    assert is_list(response["accounts"])
    assert response["statuses"] == []
    assert response["hashtags"] == []

    assert Enum.any?(
             response["accounts"],
             &(&1["id"] == Integer.to_string(alice.id) and &1["username"] == "alice")
           )
  end

  test "GET /api/v2/search resolves remote accounts when resolve=true", %{conn: conn} do
    actor_url = "https://remote.example/users/bob"

    Egregoros.HTTP.Mock
    |> expect(:get, fn url, _headers ->
      assert url ==
               "https://remote.example/.well-known/webfinger?resource=acct:bob@remote.example"

      {:ok,
       %{
         status: 200,
         body: %{
           "links" => [
             %{
               "rel" => "self",
               "type" => "application/activity+json",
               "href" => actor_url
             }
           ]
         },
         headers: []
       }}
    end)
    |> expect(:get, fn url, _headers ->
      assert url == actor_url

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => actor_url,
           "type" => "Person",
           "preferredUsername" => "bob",
           "inbox" => "https://remote.example/users/bob/inbox",
           "outbox" => "https://remote.example/users/bob/outbox",
           "publicKey" => %{
             "id" => actor_url <> "#main-key",
             "owner" => actor_url,
             "publicKeyPem" => "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n"
           }
         },
         headers: []
       }}
    end)

    conn = get(conn, "/api/v2/search", %{"q" => "bob@remote.example", "resolve" => "true"})
    response = json_response(conn, 200)

    assert is_list(response["accounts"])

    assert Enum.any?(
             response["accounts"],
             &(&1["username"] == "bob" and &1["acct"] == "bob@remote.example")
           )
  end

  test "GET /api/v2/search resolves remote accounts with extra @ segments (elk compatibility)", %{
    conn: conn
  } do
    actor_url = "https://remote.example/users/bob"

    Egregoros.HTTP.Mock
    |> expect(:get, fn url, _headers ->
      assert url ==
               "https://remote.example/.well-known/webfinger?resource=acct:bob@remote.example"

      {:ok,
       %{
         status: 200,
         body: %{
           "links" => [
             %{
               "rel" => "self",
               "type" => "application/activity+json",
               "href" => actor_url
             }
           ]
         },
         headers: []
       }}
    end)
    |> expect(:get, fn url, _headers ->
      assert url == actor_url

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => actor_url,
           "type" => "Person",
           "preferredUsername" => "bob",
           "inbox" => "https://remote.example/users/bob/inbox",
           "outbox" => "https://remote.example/users/bob/outbox",
           "publicKey" => %{
             "id" => actor_url <> "#main-key",
             "owner" => actor_url,
             "publicKeyPem" => "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n"
           }
         },
         headers: []
       }}
    end)

    conn =
      get(conn, "/api/v2/search", %{"q" => "bob@remote.example@localhost", "resolve" => "true"})

    response = json_response(conn, 200)

    assert Enum.any?(
             response["accounts"],
             &(&1["username"] == "bob" and &1["acct"] == "bob@remote.example")
           )
  end
end
