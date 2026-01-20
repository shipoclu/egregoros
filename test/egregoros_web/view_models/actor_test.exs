defmodule EgregorosWeb.ViewModels.ActorTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Users
  alias EgregorosWeb.ViewModels.Actor

  test "local actors use a short handle" do
    {:ok, user} = Users.create_local_user("alice")

    assert %{handle: "@alice", nickname: "alice"} = Actor.card(user.ap_id)
  end

  test "remote actors include the host in the handle" do
    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    assert %{handle: "@bob@remote.example", nickname: "bob"} = Actor.card(remote.ap_id)
  end

  test "remote actors resolve relative avatar urls against their ap id host" do
    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false,
        avatar_url: "/media/avatar.png"
      })

    assert %{avatar_url: "https://remote.example/media/avatar.png"} = Actor.card(remote.ap_id)
  end

  test "remote actors include non-default ports in the handle" do
    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example:8443/users/bob",
        inbox: "https://remote.example:8443/users/bob/inbox",
        outbox: "https://remote.example:8443/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    assert %{handle: "@bob@remote.example:8443", nickname: "bob"} = Actor.card(remote.ap_id)
  end

  test "unknown actors derive a handle from their ap id" do
    ap_id = "https://remote.example/users/bob"

    assert Users.get_by_ap_id(ap_id) == nil

    assert %{handle: "@bob@remote.example", nickname: "bob", display_name: "bob"} =
             Actor.card(ap_id)
  end

  test "unknown actors ignore ambiguous path segments" do
    ap_id = "https://remote.example/users"

    assert Users.get_by_ap_id(ap_id) == nil
    assert %{handle: ^ap_id, nickname: nil, display_name: ^ap_id} = Actor.card(ap_id)
  end

  test "unknown actors parse handles with an at-sign path" do
    ap_id = "https://remote.example/@bob"

    assert Users.get_by_ap_id(ap_id) == nil

    assert %{handle: "@bob@remote.example", nickname: "bob", display_name: "bob"} =
             Actor.card(ap_id)
  end

  test "unknown actors keep non-url identifiers as-is" do
    ap_id = "bob"

    assert Users.get_by_ap_id(ap_id) == nil
    assert %{handle: "bob", nickname: nil, display_name: "bob"} = Actor.card(ap_id)
  end
end
