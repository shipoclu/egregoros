defmodule Egregoros.Workers.DeliverToActorTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity
  alias Egregoros.Workers.DeliverToActor

  test "perform enqueues DeliverActivity for an already stored remote actor without fetching" do
    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    stub(Egregoros.HTTP.Mock, :get, fn _url, _headers ->
      flunk("unexpected HTTP GET during DeliverToActor.perform/1")
    end)

    stub(Egregoros.HTTP.Mock, :post, fn _url, _body, _headers ->
      flunk("unexpected HTTP POST during DeliverToActor.perform/1")
    end)

    assert :ok =
             perform_job(DeliverToActor, %{
               "user_id" => local.id,
               "target_actor_ap_id" => remote.ap_id,
               "activity_id" => "https://local.example/activities/like/1",
               "activity" => %{
                 "id" => "https://local.example/activities/like/1",
                 "type" => "Like",
                 "actor" => local.ap_id,
                 "object" => "https://remote.example/objects/1"
               }
             })

    assert Enum.any?(all_enqueued(worker: DeliverActivity), fn job ->
             job.args["inbox_url"] == remote.inbox and
               match?(%{"type" => "Like"}, job.args["activity"])
           end)
  end

  test "perform fetches and stores the target actor when missing, then enqueues DeliverActivity" do
    {:ok, local} = Users.create_local_user("alice")

    actor_url = "https://remote.example/users/bob"

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
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

    assert :ok =
             perform_job(DeliverToActor, %{
               "user_id" => local.id,
               "target_actor_ap_id" => actor_url,
               "activity_id" => "https://local.example/activities/like/2",
               "activity" => %{
                 "id" => "https://local.example/activities/like/2",
                 "type" => "Like",
                 "actor" => local.ap_id,
                 "object" => "https://remote.example/objects/2"
               }
             })

    assert %Egregoros.User{} = Users.get_by_ap_id(actor_url)

    assert Enum.any?(all_enqueued(worker: DeliverActivity), fn job ->
             job.args["inbox_url"] == "https://remote.example/users/bob/inbox" and
               match?(%{"type" => "Like"}, job.args["activity"])
           end)
  end

  test "perform discards when the local user cannot be found" do
    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    assert {:discard, :unknown_user} =
             perform_job(DeliverToActor, %{
               "user_id" => -1,
               "target_actor_ap_id" => remote.ap_id,
               "activity_id" => "https://local.example/activities/like/unknown-user",
               "activity" => %{
                 "id" => "https://local.example/activities/like/unknown-user",
                 "type" => "Like",
                 "actor" => "https://local.example/users/unknown",
                 "object" => "https://remote.example/objects/1"
               }
             })

    assert all_enqueued(worker: DeliverActivity) == []
  end

  test "perform short-circuits when delivering to a local target actor" do
    {:ok, local} = Users.create_local_user("alice")
    {:ok, local_target} = Users.create_local_user("bob")

    stub(Egregoros.HTTP.Mock, :get, fn _url, _headers ->
      flunk("unexpected HTTP GET during DeliverToActor.perform/1")
    end)

    stub(Egregoros.HTTP.Mock, :post, fn _url, _body, _headers ->
      flunk("unexpected HTTP POST during DeliverToActor.perform/1")
    end)

    assert :ok =
             perform_job(DeliverToActor, %{
               "user_id" => local.id,
               "target_actor_ap_id" => local_target.ap_id,
               "activity_id" => "https://local.example/activities/like/local-target",
               "activity" => %{
                 "id" => "https://local.example/activities/like/local-target",
                 "type" => "Like",
                 "actor" => local.ap_id,
                 "object" => "https://local.example/objects/1"
               }
             })

    assert all_enqueued(worker: DeliverActivity) == []
  end

  test "perform discards when the target actor ap id is unsafe" do
    {:ok, local} = Users.create_local_user("alice")

    assert {:discard, :unsafe_url} =
             perform_job(DeliverToActor, %{
               "user_id" => local.id,
               "target_actor_ap_id" => "not-a-url",
               "activity_id" => "https://local.example/activities/like/unsafe-target",
               "activity" => %{
                 "id" => "https://local.example/activities/like/unsafe-target",
                 "type" => "Like",
                 "actor" => local.ap_id,
                 "object" => "https://remote.example/objects/1"
               }
             })

    assert all_enqueued(worker: DeliverActivity) == []
  end

  test "perform returns an error when the target actor has no inbox" do
    import Ecto.Query

    alias Egregoros.Repo
    alias Egregoros.User

    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    {1, _} = Repo.update_all(from(u in User, where: u.id == ^remote.id), set: [inbox: ""])

    assert {:error, :delivery_failed} =
             perform_job(DeliverToActor, %{
               "user_id" => local.id,
               "target_actor_ap_id" => remote.ap_id,
               "activity_id" => "https://local.example/activities/like/missing-inbox",
               "activity" => %{
                 "id" => "https://local.example/activities/like/missing-inbox",
                 "type" => "Like",
                 "actor" => local.ap_id,
                 "object" => "https://remote.example/objects/1"
               }
             })

    assert all_enqueued(worker: DeliverActivity) == []
  end

  test "perform discards when the target inbox url is unsafe" do
    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: "https://remote.example/users/bob",
        inbox: "http://127.0.0.1/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    assert {:discard, :unsafe_url} =
             perform_job(DeliverToActor, %{
               "user_id" => local.id,
               "target_actor_ap_id" => remote.ap_id,
               "activity_id" => "https://local.example/activities/like/unsafe-inbox",
               "activity" => %{
                 "id" => "https://local.example/activities/like/unsafe-inbox",
                 "type" => "Like",
                 "actor" => local.ap_id,
                 "object" => "https://remote.example/objects/1"
               }
             })

    assert all_enqueued(worker: DeliverActivity) == []
  end
end
