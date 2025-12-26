defmodule Egregoros.TimelineTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Timeline

  test "ingesting a note broadcasts to the timeline" do
    Timeline.subscribe()

    note = %{
      "id" => "https://remote.example/objects/stream-1",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Remote hello"
    }

    assert {:ok, object} = Pipeline.ingest(note, local: false)

    assert_receive {:post_created, ^object}
  end
end
