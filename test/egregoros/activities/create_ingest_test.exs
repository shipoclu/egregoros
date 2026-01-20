defmodule Egregoros.Activities.CreateIngestTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Users

  test "rejects remote Create when not targeted to the inbox user" do
    {:ok, inbox_user} = Users.create_local_user("create_ingest_inbox_user")

    actor = "https://remote.example/users/alice"

    activity = %{
      "id" => "https://remote.example/activities/" <> Ecto.UUID.generate(),
      "type" => "Create",
      "actor" => actor,
      "to" => [],
      "cc" => [],
      "object" => %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Note",
        "actor" => actor,
        "attributedTo" => actor,
        "content" => "Hello",
        "to" => [],
        "cc" => []
      }
    }

    assert {:error, :not_targeted} =
             Pipeline.ingest(activity, local: false, inbox_user_ap_id: inbox_user.ap_id)
  end
end
