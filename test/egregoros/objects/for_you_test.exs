defmodule Egregoros.Objects.ForYouTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Like
  alias Egregoros.Activities.Note
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  test "list_for_you_statuses shows statuses liked by similar actors and excludes already-liked ones" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, carol} = Users.create_local_user("carol")
    {:ok, dave} = Users.create_local_user("dave")
    {:ok, eve} = Users.create_local_user("eve")

    assert {:ok, note_1} = Pipeline.ingest(Note.build(bob, "A"), local: true)
    assert {:ok, note_2} = Pipeline.ingest(Note.build(carol, "B"), local: true)
    assert {:ok, note_3} = Pipeline.ingest(Note.build(dave, "C"), local: true)

    assert {:ok, _} = Pipeline.ingest(Like.build(alice, note_1), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(alice, note_2), local: true)

    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_1), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_2), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_3), local: true)

    statuses = Objects.list_for_you_statuses(alice.ap_id, limit: 20)

    assert Enum.any?(statuses, &(&1.ap_id == note_3.ap_id))
    refute Enum.any?(statuses, &(&1.ap_id == note_1.ap_id))
    refute Enum.any?(statuses, &(&1.ap_id == note_2.ap_id))
  end

  test "list_for_you_statuses excludes statuses by muted actors" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, muted} = Users.create_local_user("muted")
    {:ok, eve} = Users.create_local_user("eve")

    assert {:ok, note_1} = Pipeline.ingest(Note.build(bob, "A"), local: true)
    assert {:ok, note_2} = Pipeline.ingest(Note.build(muted, "Muted post"), local: true)

    assert {:ok, _} = Pipeline.ingest(Like.build(alice, note_1), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_1), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_2), local: true)

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Mute",
               actor: alice.ap_id,
               object: muted.ap_id,
               activity_ap_id: nil
             })

    statuses = Objects.list_for_you_statuses(alice.ap_id, limit: 20)

    refute Enum.any?(statuses, &(&1.ap_id == note_2.ap_id))
  end

  test "list_for_you_statuses supports pagination on like id" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, carol} = Users.create_local_user("carol")
    {:ok, dave} = Users.create_local_user("dave")
    {:ok, frank} = Users.create_local_user("frank")
    {:ok, eve} = Users.create_local_user("eve")

    assert {:ok, note_1} = Pipeline.ingest(Note.build(bob, "A"), local: true)
    assert {:ok, note_2} = Pipeline.ingest(Note.build(carol, "B"), local: true)
    assert {:ok, note_3} = Pipeline.ingest(Note.build(dave, "C"), local: true)
    assert {:ok, note_4} = Pipeline.ingest(Note.build(frank, "D"), local: true)

    assert {:ok, _} = Pipeline.ingest(Like.build(alice, note_1), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(alice, note_2), local: true)

    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_1), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_2), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_3), local: true)
    assert {:ok, _} = Pipeline.ingest(Like.build(eve, note_4), local: true)

    [status_1, status_2] = Objects.list_for_you_statuses(alice.ap_id, limit: 20)
    assert Enum.map([status_1.ap_id, status_2.ap_id], & &1) == [note_4.ap_id, note_3.ap_id]

    like_id_1 = status_1.internal["for_you_like_id"]
    like_id_2 = status_2.internal["for_you_like_id"]

    assert is_binary(like_id_1) and is_binary(like_id_2)

    like_1_int = like_id_1 |> FlakeId.from_string() |> FlakeId.to_integer()
    like_2_int = like_id_2 |> FlakeId.from_string() |> FlakeId.to_integer()
    assert like_1_int > like_2_int

    statuses = Objects.list_for_you_statuses(alice.ap_id, limit: 20, max_id: like_id_1)
    assert Enum.any?(statuses, &(&1.ap_id == note_3.ap_id))
    refute Enum.any?(statuses, &(&1.ap_id == note_4.ap_id))

    statuses = Objects.list_for_you_statuses(alice.ap_id, limit: 20, since_id: like_id_2)
    assert Enum.any?(statuses, &(&1.ap_id == note_4.ap_id))
    refute Enum.any?(statuses, &(&1.ap_id == note_3.ap_id))

    statuses = Objects.list_for_you_statuses(alice.ap_id, limit: 20, max_id: like_id_2)
    refute Enum.any?(statuses, &(&1.ap_id in [note_3.ap_id, note_4.ap_id]))

    statuses = Objects.list_for_you_statuses(alice.ap_id, limit: 20, since_id: like_id_1)
    refute Enum.any?(statuses, &(&1.ap_id in [note_3.ap_id, note_4.ap_id]))
  end
end
