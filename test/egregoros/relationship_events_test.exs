defmodule Egregoros.RelationshipEventsTest do
  use ExUnit.Case, async: true

  alias Egregoros.RelationshipEvents

  test "broadcast_change/3 notifies both actor and object topics and de-dups them" do
    actor = "https://example.com/users/#{Ecto.UUID.generate()}"
    object = "https://example.com/users/#{Ecto.UUID.generate()}"

    assert :ok = RelationshipEvents.subscribe(actor)
    assert :ok = RelationshipEvents.subscribe(object)

    assert :ok = RelationshipEvents.broadcast_change("Follow", actor, object)

    assert_receive {:relationship_changed, %{type: "Follow", actor: ^actor, object: ^object}}
    assert_receive {:relationship_changed, %{type: "Follow", actor: ^actor, object: ^object}}

    assert :ok = RelationshipEvents.broadcast_change("Follow", actor, actor)

    assert_receive {:relationship_changed, %{type: "Follow", actor: ^actor, object: ^actor}}
    refute_receive {:relationship_changed, %{type: "Follow", actor: ^actor, object: ^actor}}
  end

  test "no-ops on blank and non-binary values" do
    assert :ok = RelationshipEvents.subscribe("  ")
    assert :ok = RelationshipEvents.unsubscribe("  ")

    assert :ok = RelationshipEvents.broadcast_change(nil, nil, nil)
    assert :ok = RelationshipEvents.broadcast_change("Follow", "  ", "  ")
  end
end
