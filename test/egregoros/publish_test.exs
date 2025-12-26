defmodule Egregoros.PublishTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity

  test "post_note/2 rejects content longer than 5000 characters" do
    {:ok, local} = Users.create_local_user("alice")
    assert {:error, :too_long} = Publish.post_note(local, String.duplicate("a", 5001))
  end

  test "post_note/2 delivers Create with addressing to remote followers" do
    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote_follower} =
      Users.create_user(%{
        nickname: "lain",
        ap_id: "https://lain.com/users/lain",
        inbox: "https://lain.com/users/lain/inbox",
        outbox: "https://lain.com/users/lain/outbox",
        public_key: "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n",
        local: false
      })

    follow = %{
      "id" => "https://lain.com/activities/follow/1",
      "type" => "Follow",
      "actor" => remote_follower.ap_id,
      "object" => local.ap_id
    }

    assert {:ok, _} = Pipeline.ingest(follow, local: false)

    Egregoros.HTTP.Mock
    |> expect(:post, fn url, body, _headers ->
      assert url == remote_follower.inbox

      decoded = Jason.decode!(body)
      assert decoded["type"] == "Create"
      assert decoded["actor"] == local.ap_id

      assert "https://www.w3.org/ns/activitystreams#Public" in decoded["to"]
      assert (local.ap_id <> "/followers") in decoded["cc"]

      assert is_map(decoded["object"])
      assert "https://www.w3.org/ns/activitystreams#Public" in decoded["object"]["to"]
      assert (local.ap_id <> "/followers") in decoded["object"]["cc"]

      {:ok, %{status: 202, body: "", headers: []}}
    end)

    assert {:ok, _} = Publish.post_note(local, "Hello followers")

    args =
      all_enqueued(worker: DeliverActivity)
      |> Enum.map(& &1.args)
      |> Enum.find(fn
        %{"activity" => %{"type" => "Create"}} -> true
        _ -> false
      end)

    assert is_map(args)
    assert :ok = perform_job(DeliverActivity, args)
  end
end
