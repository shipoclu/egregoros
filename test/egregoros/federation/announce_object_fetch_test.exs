defmodule Egregoros.Federation.AnnounceObjectFetchTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Workers.FetchThreadAncestors

  test "ingesting a remote Announce for an unknown object enqueues a low priority object+thread fetch" do
    announced_id = "https://remote.example/objects/announced-1"

    announce =
      %{
        "id" => "https://remote.example/activities/announce/1",
        "type" => "Announce",
        "actor" => "https://remote.example/users/alice",
        "object" => announced_id
      }

    assert {:ok, _} = Pipeline.ingest(announce, local: false)

    assert_enqueued(
      worker: FetchThreadAncestors,
      args: %{"start_ap_id" => announced_id},
      priority: 9
    )
  end

  test "remote Announce does not enqueue fetch when the announced object already exists" do
    announced_id = "https://remote.example/objects/announced-2"

    note =
      %{
        "id" => announced_id,
        "type" => "Note",
        "attributedTo" => "https://remote.example/users/alice",
        "content" => "hello",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

    assert {:ok, _} = Pipeline.ingest(note, local: false)

    announce =
      %{
        "id" => "https://remote.example/activities/announce/2",
        "type" => "Announce",
        "actor" => "https://remote.example/users/bob",
        "object" => announced_id
      }

    assert {:ok, _} = Pipeline.ingest(announce, local: false)

    refute_enqueued(
      worker: FetchThreadAncestors,
      args: %{"start_ap_id" => announced_id}
    )
  end

  test "remote Announce enqueues fetch even when the announce isn't public" do
    announced_id = "https://remote.example/objects/announced-3"

    announce =
      %{
        "id" => "https://remote.example/activities/announce/3",
        "type" => "Announce",
        "actor" => "https://remote.example/users/alice",
        "object" => announced_id,
        "to" => ["https://remote.example/users/alice"]
      }

    assert {:ok, _} = Pipeline.ingest(announce, local: false)

    assert_enqueued(
      worker: FetchThreadAncestors,
      args: %{"start_ap_id" => announced_id},
      priority: 9
    )
  end
end
