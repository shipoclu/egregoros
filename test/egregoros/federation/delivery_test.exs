defmodule Egregoros.Federation.DeliveryTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Federation.Delivery
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity

  test "deliver posts a signed activity to the inbox" do
    {:ok, user} = Users.create_local_user("alice")

    inbox = "https://remote.example/users/bob/inbox"

    activity = %{
      "id" => "https://local.example/activities/follow/1",
      "type" => "Follow",
      "actor" => user.ap_id,
      "object" => "https://remote.example/users/bob"
    }

    body =
      activity
      |> Map.put_new("@context", "https://www.w3.org/ns/activitystreams")
      |> Jason.encode!()

    expected_digest = "SHA-256=" <> (:crypto.hash(:sha256, body) |> Base.encode64())

    Egregoros.HTTP.Mock
    |> expect(:post, fn ^inbox, ^body, headers ->
      assert %{"@context" => "https://www.w3.org/ns/activitystreams"} = Jason.decode!(body)
      assert {"content-type", "application/activity+json"} in headers
      assert {"accept", "application/activity+json"} in headers
      assert {"digest", expected_digest} in headers

      assert {"content-length", Integer.to_string(byte_size(body))} in headers

      assert Enum.any?(headers, fn
               {"signature", value} ->
                 is_binary(value) and String.contains?(value, "keyId=\"#{user.ap_id}#main-key\"")

               _ ->
                 false
             end)

      {:ok, %{status: 202, body: "", headers: []}}
    end)

    assert {:ok, _job} = Delivery.deliver(user, inbox, activity)

    assert_enqueued(
      worker: DeliverActivity,
      queue: "federation_outgoing",
      args: %{"user_id" => user.id, "inbox_url" => inbox, "activity" => activity}
    )

    assert :ok =
             perform_job(DeliverActivity, %{
               "user_id" => user.id,
               "inbox_url" => inbox,
               "activity" => activity
             })
  end

  test "deliver rejects unsafe inbox urls" do
    {:ok, user} = Users.create_local_user("alice")

    inbox = "http://127.0.0.1/users/bob/inbox"

    activity = %{
      "id" => "https://local.example/activities/follow/1",
      "type" => "Follow",
      "actor" => user.ap_id,
      "object" => "https://remote.example/users/bob"
    }

    stub(Egregoros.HTTP.Mock, :post, fn _url, _body, _headers ->
      flunk("unexpected delivery for unsafe inbox url")
    end)

    assert {:error, :unsafe_url} = Delivery.deliver(user, inbox, activity)
    refute_enqueued(worker: DeliverActivity)

    assert {:error, :unsafe_url} = Delivery.deliver_now(user, inbox, activity)
  end
end
