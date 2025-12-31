defmodule Egregoros.Activities.UpdateIngestTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Keys
  alias Egregoros.Object
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "ingest stores Update and applies Person profile updates" do
    {:ok, inbox_user} = Users.create_local_user("inbox-user")
    actor_ap_id = "https://remote.example/users/alice"

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: inbox_user.ap_id,
               object: actor_ap_id,
               activity_ap_id: "https://egregoros.example/activities/follow/update-targeting"
             })

    {public_key, _private_key} = Keys.generate_rsa_keypair()

    update = %{
      "id" => "https://remote.example/activities/update/1",
      "type" => "Update",
      "actor" => actor_ap_id,
      "to" => [@public],
      "cc" => [actor_ap_id <> "/followers"],
      "object" => %{
        "id" => actor_ap_id,
        "type" => "Person",
        "preferredUsername" => "alice",
        "name" => ":linux: Alice",
        "summary" => "bio",
        "tag" => [
          %{
            "type" => "Emoji",
            "name" => ":linux:",
            "icon" => %{"url" => "https://remote.example/emoji/linux.png"}
          }
        ],
        "inbox" => actor_ap_id <> "/inbox",
        "outbox" => actor_ap_id <> "/outbox",
        "icon" => %{"url" => "https://remote.example/media/avatar.png"},
        "image" => %{"url" => "https://remote.example/media/banner.png"},
        "manuallyApprovesFollowers" => true,
        "publicKey" => %{
          "id" => actor_ap_id <> "#main-key",
          "owner" => actor_ap_id,
          "publicKeyPem" => public_key
        }
      }
    }

    assert {:ok, %Object{} = object} =
             Pipeline.ingest(update, local: false, inbox_user_ap_id: inbox_user.ap_id)

    assert object.type == "Update"
    assert object.actor == actor_ap_id
    assert object.object == actor_ap_id

    user = Users.get_by_ap_id(actor_ap_id)
    assert user.nickname == "alice"
    assert user.domain == "remote.example"
    assert user.local == false
    assert user.public_key == public_key
    assert user.locked == true
    assert user.name == ":linux: Alice"
    assert user.bio == "bio"
    assert user.avatar_url == "https://remote.example/media/avatar.png"
    assert user.banner_url == "https://remote.example/media/banner.png"

    assert %{"shortcode" => "linux", "url" => "https://remote.example/emoji/linux.png"} in user.emojis
  end
end
