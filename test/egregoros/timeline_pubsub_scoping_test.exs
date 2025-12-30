defmodule Egregoros.TimelinePubSubScopingTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @public_topic "timeline:public"

  test "public notes are broadcast to the public timeline topic" do
    Phoenix.PubSub.subscribe(Egregoros.PubSub, @public_topic)

    {:ok, alice} = Users.create_local_user("alice")

    note =
      build_note(%{
        id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        actor: alice.ap_id,
        to: [@as_public],
        cc: [alice.ap_id <> "/followers"],
        content: "<p>Hello world</p>"
      })

    assert {:ok, object} = Pipeline.ingest(note, local: true)
    assert_receive {:post_created, ^object}
  end

  test "unlisted notes are broadcast to follower home topics, not public" do
    Phoenix.PubSub.subscribe(Egregoros.PubSub, @public_topic)

    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    Phoenix.PubSub.subscribe(Egregoros.PubSub, user_topic(bob.ap_id))

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: bob.ap_id,
               object: alice.ap_id,
               activity_ap_id: Endpoint.url() <> "/activities/follow/" <> Ecto.UUID.generate()
             })

    note =
      build_note(%{
        id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        actor: alice.ap_id,
        to: [alice.ap_id <> "/followers"],
        cc: [@as_public],
        content: "<p>Unlisted</p>"
      })

    assert {:ok, object} = Pipeline.ingest(note, local: true)

    assert_receive {:post_created, ^object}
    refute_receive {:post_created, ^object}, 20
  end

  test "direct notes are broadcast only to the recipients' topics" do
    Phoenix.PubSub.subscribe(Egregoros.PubSub, @public_topic)

    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, eve} = Users.create_local_user("eve")

    Phoenix.PubSub.subscribe(Egregoros.PubSub, user_topic(bob.ap_id))
    Phoenix.PubSub.subscribe(Egregoros.PubSub, user_topic(eve.ap_id))

    note =
      build_note(%{
        id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        actor: alice.ap_id,
        to: [bob.ap_id],
        cc: [],
        content: "<p>Secret</p>"
      })

    assert {:ok, object} = Pipeline.ingest(note, local: true)

    assert_receive {:post_created, ^object}
    refute_receive {:post_created, ^object}, 20
  end

  defp user_topic(ap_id) when is_binary(ap_id), do: "timeline:user:" <> ap_id
  defp user_topic(_), do: "timeline:user:unknown"

  defp build_note(%{id: id, actor: actor, to: to, cc: cc, content: content})
       when is_binary(id) and is_binary(actor) and is_list(to) and is_list(cc) and
              is_binary(content) do
    %{
      "id" => id,
      "type" => "Note",
      "attributedTo" => actor,
      "to" => to,
      "cc" => cc,
      "content" => content,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
