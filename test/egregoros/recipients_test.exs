defmodule Egregoros.RecipientsTest do
  use ExUnit.Case, async: true

  alias Egregoros.Recipients

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  test "recipient_actor_ids/2 filters public, followers, blanks and dedupes" do
    data = %{
      "to" => [
        @as_public,
        "https://example.com/users/alice/followers",
        " https://remote.example/users/bob ",
        "",
        nil
      ],
      "cc" => ["https://remote.example/users/carl", "https://remote.example/users/bob"]
    }

    assert Recipients.recipient_actor_ids(data, fields: ["to", "cc"]) == [
             "https://remote.example/users/bob",
             "https://remote.example/users/carl"
           ]
  end

  test "recipient_actor_ids/2 extracts ids from recipient maps" do
    data = %{
      "to" => [
        %{"id" => "https://remote.example/users/bob"},
        %{id: "https://remote.example/users/carl"}
      ]
    }

    assert MapSet.new(Recipients.recipient_actor_ids(data)) ==
             MapSet.new(["https://remote.example/users/bob", "https://remote.example/users/carl"])
  end

  test "recipient_actor_ids/2 supports custom recipient fields" do
    data = %{
      "to" => ["https://remote.example/users/bob"],
      "audience" => ["https://remote.example/users/carl"]
    }

    assert Recipients.recipient_actor_ids(data, fields: ["audience"]) == [
             "https://remote.example/users/carl"
           ]
  end
end
