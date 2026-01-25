defmodule Egregoros.Federation.DeliveryPayloadTest do
  use ExUnit.Case, async: true

  alias Egregoros.Federation.DeliveryPayload

  test "for_delivery/1 normalizes Answer objects for delivery" do
    data = %{
      "type" => "Create",
      "to" => ["https://example.com/users/alice"],
      "cc" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => %{
        "type" => "Answer",
        "to" => ["https://example.com/users/alice"],
        "cc" => ["https://example.com/users/alice/followers"]
      }
    }

    normalized = DeliveryPayload.for_delivery(data)

    assert normalized["object"]["type"] == "Note"
    refute Map.has_key?(normalized["object"], "cc")
    assert normalized["to"] == ["https://example.com/users/alice"]
    assert normalized["cc"] == []
  end

  test "for_delivery/1 leaves non-Answer payloads unchanged" do
    data = %{"type" => "Create", "object" => %{"type" => "Note"}}
    assert DeliveryPayload.for_delivery(data) == data
  end
end
