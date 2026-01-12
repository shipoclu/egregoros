defmodule Egregoros.UserEventsTest do
  use ExUnit.Case, async: true

  alias Egregoros.UserEvents

  test "subscribe/1 broadcasts updates and unsubscribe/1 stops receiving them" do
    user_ap_id = "https://example.com/users/#{Ecto.UUID.generate()}"

    assert :ok = UserEvents.subscribe(user_ap_id)
    assert :ok = UserEvents.broadcast_update(user_ap_id)

    assert_receive {:user_updated, %{ap_id: ^user_ap_id}}

    assert :ok = UserEvents.unsubscribe(user_ap_id)
    assert :ok = UserEvents.broadcast_update(user_ap_id)

    refute_receive {:user_updated, _}
  end

  test "no-ops on blank and non-binary user ap ids" do
    assert :ok = UserEvents.subscribe("  ")
    assert :ok = UserEvents.unsubscribe("  ")
    assert :ok = UserEvents.broadcast_update("  ")

    assert :ok = UserEvents.subscribe(nil)
    assert :ok = UserEvents.unsubscribe(nil)
    assert :ok = UserEvents.broadcast_update(nil)
  end
end
