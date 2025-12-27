defmodule Egregoros.Federation.ThreadFetchTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Workers.FetchThreadAncestors

  test "ingesting a reply note enqueues a thread ancestor fetch" do
    note_id = "https://remote.example/objects/reply-1"
    parent_id = "https://remote.example/objects/parent-1"

    reply =
      %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => "https://remote.example/users/alice",
        "content" => "Reply",
        "inReplyTo" => parent_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

    assert {:ok, _} = Pipeline.ingest(reply, local: false)

    assert_enqueued(
      worker: FetchThreadAncestors,
      args: %{"start_ap_id" => note_id}
    )
  end

  test "thread ancestor worker fetches and ingests missing parents" do
    reply_id = "https://remote.example/objects/reply-2"
    parent_id = "https://remote.example/objects/parent-2"

    reply =
      %{
        "id" => reply_id,
        "type" => "Note",
        "attributedTo" => "https://remote.example/users/alice",
        "content" => "Reply",
        "inReplyTo" => parent_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

    assert {:ok, _} = Pipeline.ingest(reply, local: false)
    assert Objects.get_by_ap_id(parent_id) == nil

    expect(Egregoros.HTTP.Mock, :get, fn url, headers ->
      assert url == parent_id
      assert List.keyfind(headers, "signature", 0)
      assert List.keyfind(headers, "authorization", 0)

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => parent_id,
           "type" => "Note",
           "attributedTo" => "https://remote.example/users/alice",
           "content" => "Parent",
           "to" => ["https://www.w3.org/ns/activitystreams#Public"]
         },
         headers: []
       }}
    end)

    job = %Oban.Job{args: %{"start_ap_id" => reply_id, "max_depth" => 5}}
    assert :ok = FetchThreadAncestors.perform(job)

    assert Objects.get_by_ap_id(parent_id)

    reply_object = Objects.get_by_ap_id(reply_id)
    ancestors = Objects.thread_ancestors(reply_object)
    assert Enum.any?(ancestors, &(&1.ap_id == parent_id))
  end
end
