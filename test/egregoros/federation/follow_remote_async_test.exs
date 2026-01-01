defmodule Egregoros.Federation.FollowRemoteAsyncTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Objects
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity
  alias Egregoros.Workers.FollowRemote

  test "follow_remote_async/2 enqueues a job without doing HTTP when the remote actor is unknown" do
    {:ok, local} = Users.create_local_user("alice")

    expect(Egregoros.HTTP.Mock, :get, 0, fn _url, _headers -> :ok end)
    expect(Egregoros.HTTP.Mock, :post, 0, fn _url, _body, _headers -> :ok end)

    assert {:ok, :queued} = Egregoros.Federation.follow_remote_async(local, "bob@remote.example")

    assert Enum.any?(all_enqueued(), fn job ->
             job.worker == "Egregoros.Workers.FollowRemote"
           end)

    assert [] = all_enqueued(worker: DeliverActivity)
  end

  test "follow_remote_async/2 follows already stored remote users without HTTP" do
    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote} =
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

    expect(Egregoros.HTTP.Mock, :get, 0, fn _url, _headers -> :ok end)
    expect(Egregoros.HTTP.Mock, :post, 0, fn _url, _body, _headers -> :ok end)

    assert {:ok, %Egregoros.User{} = returned} =
             Egregoros.Federation.follow_remote_async(local, "bob@remote.example")

    assert returned.ap_id == remote.ap_id

    assert Objects.get_by_type_actor_object("Follow", local.ap_id, remote.ap_id)

    assert [] = all_enqueued(worker: FollowRemote)

    follow_jobs =
      all_enqueued(worker: DeliverActivity)
      |> Enum.filter(fn job ->
        match?(%{"activity" => %{"type" => "Follow"}}, job.args)
      end)

    assert Enum.any?(follow_jobs, &(&1.args["inbox_url"] == remote.inbox))
  end
end

