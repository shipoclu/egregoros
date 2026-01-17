defmodule Egregoros.Activities.EncryptedMessageIngestTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Users

  test "ingests EncryptedMessage objects" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    msg = %{
      "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
      "type" => "EncryptedMessage",
      "attributedTo" => alice.ap_id,
      "to" => [bob.ap_id],
      "content" => "Encrypted message",
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "egregoros:e2ee_dm" => %{"version" => 1, "ciphertext" => "abc"}
    }

    assert {:ok, object} = Pipeline.ingest(msg, local: true)
    assert object.type == "EncryptedMessage"
    assert get_in(object.data, ["egregoros:e2ee_dm", "ciphertext"]) == "abc"
  end
end
