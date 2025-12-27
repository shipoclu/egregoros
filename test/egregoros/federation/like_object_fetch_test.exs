defmodule Egregoros.Federation.LikeObjectFetchTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Workers.FetchThreadAncestors

  test "ingesting a remote Like for an unknown object enqueues a low priority object+thread fetch" do
    liked_object_id = "https://remote.example/objects/liked-1"

    like =
      %{
        "id" => "https://remote.example/activities/like/1",
        "type" => "Like",
        "actor" => "https://remote.example/users/alice",
        "object" => liked_object_id
      }

    assert {:ok, _} = Pipeline.ingest(like, local: false)

    assert_enqueued(
      worker: FetchThreadAncestors,
      args: %{"start_ap_id" => liked_object_id},
      priority: 9
    )
  end

  test "ingesting a remote Like for an object we already have does not enqueue an object fetch" do
    liked_object_id = "https://remote.example/objects/liked-2"

    note =
      %{
        "id" => liked_object_id,
        "type" => "Note",
        "attributedTo" => "https://remote.example/users/alice",
        "content" => "hello",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

    assert {:ok, _} = Pipeline.ingest(note, local: false)

    like =
      %{
        "id" => "https://remote.example/activities/like/2",
        "type" => "Like",
        "actor" => "https://remote.example/users/bob",
        "object" => liked_object_id
      }

    assert {:ok, _} = Pipeline.ingest(like, local: false)

    refute_enqueued(
      worker: FetchThreadAncestors,
      args: %{"start_ap_id" => liked_object_id}
    )
  end
end

