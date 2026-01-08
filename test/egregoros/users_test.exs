defmodule Egregoros.UsersTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Repo
  alias Egregoros.Relationships
  alias Egregoros.User
  alias Egregoros.Users

  defp unique_nickname(prefix) do
    prefix <> Integer.to_string(System.unique_integer([:positive]))
  end

  test "create_user stores a user" do
    attrs = %{
      nickname: "alice",
      ap_id: "https://example.com/users/alice",
      inbox: "https://example.com/users/alice/inbox",
      outbox: "https://example.com/users/alice/outbox",
      public_key: "PUB",
      private_key: "PRIV",
      local: true
    }

    assert {:ok, %User{} = user} = Users.create_user(attrs)
    assert user.nickname == "alice"
    assert user.ap_id == attrs.ap_id
  end

  test "create_user allows remote user without private key" do
    attrs = %{
      nickname: "remote",
      ap_id: "https://remote.example/users/remote",
      inbox: "https://remote.example/users/remote/inbox",
      outbox: "https://remote.example/users/remote/outbox",
      public_key: "PUB",
      private_key: nil,
      local: false
    }

    assert {:ok, %User{} = user} = Users.create_user(attrs)
    assert user.local == false
    assert is_nil(user.private_key)
  end

  test "create_local_user generates keys and urls" do
    {:ok, user} = Users.create_local_user("bob")

    assert user.local == true
    assert user.nickname == "bob"
    assert user.admin == false
    assert user.ap_id == EgregorosWeb.Endpoint.url() <> "/users/bob"
    assert user.inbox == user.ap_id <> "/inbox"
    assert user.outbox == user.ap_id <> "/outbox"
    assert String.starts_with?(user.public_key, "-----BEGIN PUBLIC KEY-----")
    assert String.starts_with?(user.private_key, "-----BEGIN PRIVATE KEY-----")
  end

  test "create_local_user does not grant admin based on nickname" do
    {:ok, user} = Users.create_local_user("alice")
    assert user.admin == false
  end

  test "set_admin/2 updates the admin flag for local users" do
    {:ok, user} = Users.create_local_user("alice")
    assert user.admin == false

    assert {:ok, user} = Users.set_admin(user, true)
    assert user.admin == true

    assert {:ok, user} = Users.set_admin(user, false)
    assert user.admin == false
  end

  test "get_or_create_local_user returns existing" do
    {:ok, user} = Users.create_local_user("dora")
    {:ok, fetched} = Users.get_or_create_local_user("dora")
    assert fetched.id == user.id
  end

  test "ap_id is unique" do
    {:ok, _} =
      Users.create_user(%{
        nickname: "carol",
        ap_id: "https://example.com/users/carol",
        inbox: "https://example.com/users/carol/inbox",
        outbox: "https://example.com/users/carol/outbox",
        public_key: "PUB",
        private_key: "PRIV",
        local: true
      })

    assert {:error, changeset} =
             Users.create_user(%{
               nickname: "carol2",
               ap_id: "https://example.com/users/carol",
               inbox: "https://example.com/users/carol/inbox",
               outbox: "https://example.com/users/carol/outbox",
               public_key: "PUB",
               private_key: "PRIV",
               local: true
             })

    assert "has already been taken" in errors_on(changeset).ap_id
  end

  test "search_mentions/2 finds local users by nickname" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, alicia} = Users.create_local_user("alicia")

    results = Users.search_mentions("ali", limit: 10)

    assert Enum.any?(results, &(&1.id == alice.id))
    assert Enum.any?(results, &(&1.id == alicia.id))
  end

  test "search_mentions/2 finds remote users when query includes a domain" do
    {:ok, remote} =
      Users.create_user(%{
        nickname: "toast",
        domain: "donotsta.re",
        ap_id: "https://donotsta.re/users/toast",
        inbox: "https://donotsta.re/users/toast/inbox",
        outbox: "https://donotsta.re/users/toast/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    results = Users.search_mentions("toast@dono", limit: 10)

    assert Enum.any?(results, &(&1.id == remote.id))
  end

  test "search/2 prefers exact and prefix matches over substring matches" do
    {:ok, exact} =
      Users.create_user(%{
        nickname: "lain",
        domain: "lain.com",
        ap_id: "https://lain.com/users/lain",
        inbox: "https://lain.com/users/lain/inbox",
        outbox: "https://lain.com/users/lain/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    {:ok, substring} =
      Users.create_user(%{
        nickname: "alain9423",
        domain: "mastodon.social",
        ap_id: "https://mastodon.social/users/alain9423",
        inbox: "https://mastodon.social/users/alain9423/inbox",
        outbox: "https://mastodon.social/users/alain9423/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    [first, second | _] = Users.search("lain", limit: 10)
    assert first.id == exact.id
    assert second.id == substring.id
  end

  test "search/2 prefers followed users when current_user is provided" do
    {:ok, current_user} = Users.create_local_user(unique_nickname("searcher"))

    {:ok, followed} =
      Users.create_user(%{
        nickname: "lain",
        domain: "lain.com",
        ap_id: "https://lain.com/users/lain",
        inbox: "https://lain.com/users/lain/inbox",
        outbox: "https://lain.com/users/lain/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    {:ok, other} =
      Users.create_user(%{
        nickname: "lainy",
        domain: "pleroma.example",
        ap_id: "https://pleroma.example/users/lainy",
        inbox: "https://pleroma.example/users/lainy/inbox",
        outbox: "https://pleroma.example/users/lainy/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: current_user.ap_id,
               object: followed.ap_id
             })

    [first | _] = Users.search("lai", limit: 10, current_user: current_user)
    assert first.id == followed.id
    assert first.id != other.id
  end

  test "search/2 prefers recently active users" do
    {:ok, older} =
      Users.create_user(%{
        nickname: "toast0",
        domain: "donotsta.re",
        ap_id: "https://donotsta.re/users/toast0",
        inbox: "https://donotsta.re/users/toast0/inbox",
        outbox: "https://donotsta.re/users/toast0/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    {:ok, newer} =
      Users.create_user(%{
        nickname: "toast9",
        domain: "donotsta.re",
        ap_id: "https://donotsta.re/users/toast9",
        inbox: "https://donotsta.re/users/toast9/inbox",
        outbox: "https://donotsta.re/users/toast9/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             Objects.create_object(%{
               ap_id: "https://donotsta.re/objects/toast0-note",
               type: "Note",
               actor: older.ap_id,
               data: %{},
               published: DateTime.add(now, -3600, :second),
               local: false
             })

    assert {:ok, _} =
             Objects.create_object(%{
               ap_id: "https://donotsta.re/objects/toast9-note",
               type: "Note",
               actor: newer.ap_id,
               data: %{},
               published: now,
               local: false
             })

    [first | _] = Users.search("toast", limit: 10)
    assert first.id == newer.id
    assert first.id != older.id
  end

  test "create_user derives remote domain with non-default port from ap_id" do
    {:ok, user} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example:8443/users/bob",
        inbox: "https://remote.example:8443/users/bob/inbox",
        outbox: "https://remote.example:8443/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    assert user.domain == "remote.example:8443"
  end

  test "create_object bumps user's last_activity_at when actor matches" do
    {:ok, user} =
      Users.create_user(%{
        nickname: "toast",
        domain: "donotsta.re",
        ap_id: "https://donotsta.re/users/toast",
        inbox: "https://donotsta.re/users/toast/inbox",
        outbox: "https://donotsta.re/users/toast/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    assert Repo.get(User, user.id).last_activity_at == nil

    assert {:ok, _} =
             Objects.create_object(%{
               ap_id: "https://donotsta.re/objects/toast-note",
               type: "Note",
               actor: user.ap_id,
               data: %{},
               local: false
             })

    assert %User{} = reloaded = Repo.get(User, user.id)
    assert reloaded.last_activity_at != nil
  end

  test "update_profile/2 strips admin from attrs while allowing other fields" do
    {:ok, user} = Users.create_local_user(unique_nickname("alice"))

    assert user.admin == false

    assert {:ok, updated} =
             Users.update_profile(user, %{
               admin: true,
               name: "New Name"
             })

    assert updated.admin == false
    assert updated.name == "New Name"
  end

  test "update_profile/2 normalizes blank email values to nil" do
    {:ok, user} = Users.create_local_user(unique_nickname("alice"))

    assert {:ok, updated} = Users.update_profile(user, %{email: "alice@example.com"})
    assert updated.email == "alice@example.com"

    assert {:ok, updated} = Users.update_profile(updated, %{"email" => "   \n"})
    assert updated.email == nil
  end

  test "update_password/3 enforces current password checks and minimum length" do
    nickname = unique_nickname("alice")

    assert {:ok, user} =
             Users.register_local_user(%{
               nickname: nickname,
               password: "current-password"
             })

    assert {:error, :unauthorized} = Users.update_password(user, "wrong", "new-password")

    assert {:error, :invalid_password} =
             Users.update_password(user, "current-password", "short")

    assert {:ok, _updated} =
             Users.update_password(user, "current-password", "new-password")

    assert {:error, :unauthorized} = Users.authenticate_local_user(nickname, "current-password")

    assert {:ok, %User{nickname: ^nickname}} =
             Users.authenticate_local_user(nickname, "new-password")
  end

  test "update_password/3 rejects password changes for passkey-only users" do
    nickname = unique_nickname("alice")
    assert {:ok, user} = Users.create_local_user(nickname)
    assert user.password_hash == nil

    assert {:error, :unauthorized} =
             Users.update_password(user, "current-password", "new-password")
  end
end
