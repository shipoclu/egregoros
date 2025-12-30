defmodule Egregoros.TimelineTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Timeline

  test "ingesting a note broadcasts to the timeline" do
    Timeline.subscribe_public()

    note = %{
      "id" => "https://remote.example/objects/stream-1",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["https://remote.example/users/alice/followers"],
      "content" => "Remote hello"
    }

    assert {:ok, object} = Pipeline.ingest(note, local: false)

    assert_receive {:post_created, ^object}
  end
end
