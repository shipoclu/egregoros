defmodule EgregorosWeb.MastodonAPI.SuggestionsControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Publish
  alias Egregoros.Relationships
  alias Egregoros.Users

  test "GET /api/v1/suggestions suggests accounts followed by your followings", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, carol} = Users.create_local_user("carol")

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: alice.ap_id,
               object: bob.ap_id,
               activity_ap_id: nil
             })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: bob.ap_id,
               object: carol.ap_id,
               activity_ap_id: nil
             })

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    response =
      conn
      |> put_req_header("authorization", "Bearer token")
      |> get("/api/v1/suggestions")
      |> json_response(200)

    assert Enum.any?(response, &(&1["id"] == carol.id))
    refute Enum.any?(response, &(&1["id"] == bob.id))
  end

  test "GET /api/v1/suggestions uses remote following graph relationships", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, carol} =
      Users.create_user(%{
        nickname: "carol",
        domain: "other.example",
        ap_id: "https://other.example/users/carol",
        inbox: "https://other.example/users/carol/inbox",
        outbox: "https://other.example/users/carol/outbox",
        public_key: "other-key",
        private_key: nil,
        local: false
      })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: alice.ap_id,
               object: bob.ap_id,
               activity_ap_id: nil
             })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "GraphFollow",
               actor: bob.ap_id,
               object: carol.ap_id,
               activity_ap_id: nil
             })

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    response =
      conn
      |> put_req_header("authorization", "Bearer token")
      |> get("/api/v1/suggestions")
      |> json_response(200)

    assert Enum.any?(response, &(&1["id"] == carol.id))
  end

  test "GET /api/v1/suggestions falls back to recent local accounts", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    assert {:ok, _} = Publish.post_note(bob, "Hello explore")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    response =
      conn
      |> put_req_header("authorization", "Bearer token")
      |> get("/api/v1/suggestions")
      |> json_response(200)

    assert Enum.any?(response, &(&1["id"] == bob.id))
    refute Enum.any?(response, &(&1["id"] == alice.id))
  end

  test "GET /api/v1/suggestions respects limit", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, carol} = Users.create_local_user("carol")

    assert {:ok, _} = Publish.post_note(bob, "Hello bob")
    assert {:ok, _} = Publish.post_note(carol, "Hello carol")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    response =
      conn
      |> put_req_header("authorization", "Bearer token")
      |> get("/api/v1/suggestions", %{"limit" => "1"})
      |> json_response(200)

    assert length(response) == 1
  end
end
