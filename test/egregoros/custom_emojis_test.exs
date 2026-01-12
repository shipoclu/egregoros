defmodule Egregoros.CustomEmojisTest do
  use ExUnit.Case, async: true

  alias Egregoros.CustomEmojis

  test "filters unsafe custom emoji URLs" do
    tags = [
      %{
        "type" => "Emoji",
        "name" => ":ok:",
        "icon" => %{"url" => "https://cdn.example/ok.png"}
      },
      %{
        "type" => "Emoji",
        "name" => ":loopback:",
        "icon" => %{"url" => "http://127.0.0.1/emoji.png"}
      },
      %{
        "type" => "Emoji",
        "name" => ":js:",
        "icon" => %{"url" => "javascript:alert(1)"}
      }
    ]

    assert [%{shortcode: "ok", url: "https://cdn.example/ok.png"}] =
             CustomEmojis.from_activity_tags(tags)
  end

  test "parses custom emoji icon urls from common tag shapes" do
    tags = [
      %{
        "type" => "Emoji",
        "name" => ":a:",
        "icon" => %{"url" => [%{"href" => "https://cdn.example/a.png"}]}
      },
      %{
        "type" => "Emoji",
        "name" => ":b:",
        "icon" => %{"url" => [%{"url" => "https://cdn.example/b.png"}]}
      },
      %{
        "type" => "Mention",
        "name" => "@alice",
        "href" => "https://example.com/users/alice"
      },
      %{
        "type" => "Emoji",
        "name" => ":::",
        "icon" => %{"url" => "https://cdn.example/blank.png"}
      }
    ]

    assert [
             %{shortcode: "a", url: "https://cdn.example/a.png"},
             %{shortcode: "b", url: "https://cdn.example/b.png"}
           ] = CustomEmojis.from_activity_tags(tags)

    assert [
             %{shortcode: "a", url: "https://cdn.example/a.png"},
             %{shortcode: "b", url: "https://cdn.example/b.png"}
           ] = CustomEmojis.from_object(%{data: %{"tag" => tags}})

    assert [] = CustomEmojis.from_object(:not_an_object)
  end
end
