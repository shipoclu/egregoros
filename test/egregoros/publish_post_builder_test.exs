defmodule Egregoros.Publish.PostBuilderTest do
  use ExUnit.Case, async: true

  alias Egregoros.Publish.PostBuilder

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  test "put_visibility/4 sets to/cc for public visibility" do
    actor_ap_id = "https://example.com/users/alice"

    post =
      PostBuilder.put_visibility(%{}, "public", actor_ap_id, [
        "https://remote.example/users/bob",
        actor_ap_id,
        "  ",
        "https://remote.example/users/bob"
      ])

    assert post["to"] == [@as_public]

    assert MapSet.new(post["cc"]) ==
             MapSet.new([
               actor_ap_id <> "/followers",
               "https://remote.example/users/bob"
             ])
  end

  test "put_visibility/4 sets to/cc for direct visibility" do
    actor_ap_id = "https://example.com/users/alice"

    post =
      PostBuilder.put_visibility(%{}, "direct", actor_ap_id, [
        "https://remote.example/users/bob",
        actor_ap_id
      ])

    assert post["to"] == ["https://remote.example/users/bob"]
    assert post["cc"] == []
  end

  test "put_tags/2 merges and dedupes tags by href" do
    post =
      PostBuilder.put_tags(
        %{
          "tag" => [
            %{"type" => "Hashtag", "href" => "https://example.com/tags/x", "name" => "#x"}
          ]
        },
        [
          %{"type" => "Hashtag", "href" => "https://example.com/tags/x", "name" => "#x2"},
          %{"type" => "Hashtag", "href" => "https://example.com/tags/y", "name" => "#y"}
        ]
      )

    assert post["tag"] == [
             %{"type" => "Hashtag", "href" => "https://example.com/tags/x", "name" => "#x"},
             %{"type" => "Hashtag", "href" => "https://example.com/tags/y", "name" => "#y"}
           ]
  end

  test "hashtag_tags/1 normalizes and dedupes hashtags" do
    tags = PostBuilder.hashtag_tags("hi #Hello #hello #world-1")

    assert Enum.count(tags, &(&1["name"] == "#hello")) == 1
    assert Enum.any?(tags, &(&1["name"] == "#world-1"))

    hello_tag = Enum.find(tags, &(&1["name"] == "#hello"))
    assert is_binary(hello_tag["href"])
    assert String.ends_with?(hello_tag["href"], "/tags/hello")
  end
end
