defmodule EgregorosWeb.MastodonAPI.DirectoryControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Keys
  alias Egregoros.Publish
  alias Egregoros.Users

  test "GET /api/v1/directory returns [] when disabled", %{conn: conn} do
    stub(Egregoros.Config.Mock, :get, fn
      :profile_directory, _default -> false
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, _alice} = Users.create_local_user("alice")

    assert conn |> get("/api/v1/directory") |> json_response(200) == []
  end

  test "GET /api/v1/directory returns local users and excludes system actors", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    response = conn |> get("/api/v1/directory") |> json_response(200)

    assert is_list(response)

    assert Enum.any?(response, &(&1["id"] == alice.id))
    assert Enum.any?(response, &(&1["id"] == bob.id))

    refute Enum.any?(response, &(&1["username"] in ["internal.fetch", "instance.actor"]))
  end

  test "GET /api/v1/directory supports limit, offset, and order=new", %{conn: conn} do
    {:ok, _alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, _carol} = Users.create_local_user("carol")

    response =
      conn
      |> get("/api/v1/directory", %{"limit" => "1", "offset" => "1", "order" => "new"})
      |> json_response(200)

    assert [%{"id" => id}] = response
    assert id == bob.id
  end

  test "GET /api/v1/directory orders accounts by recent activity", %{conn: conn} do
    {:ok, _alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    assert {:ok, _} = Publish.post_note(bob, "Hello directory")

    response = conn |> get("/api/v1/directory", %{"order" => "active"}) |> json_response(200)

    assert List.first(response)["id"] == bob.id
  end

  test "GET /api/v1/directory includes remote users when local=false", %{conn: conn} do
    {public_key, _private_key} = Keys.generate_rsa_keypair()

    {:ok, remote} =
      Users.create_user(%{
        nickname: "remote",
        ap_id: "https://remote.example/users/remote",
        inbox: "https://remote.example/users/remote/inbox",
        outbox: "https://remote.example/users/remote/outbox",
        public_key: public_key,
        local: false
      })

    response = conn |> get("/api/v1/directory", %{"local" => "false"}) |> json_response(200)

    assert Enum.any?(response, &(&1["id"] == remote.id))
  end

  test "GET /api/v1/directory excludes the current user when authenticated", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, bob} end)

    response =
      conn
      |> put_req_header("authorization", "Bearer token")
      |> get("/api/v1/directory")
      |> json_response(200)

    assert Enum.any?(response, &(&1["id"] == alice.id))
    refute Enum.any?(response, &(&1["id"] == bob.id))
  end
end
