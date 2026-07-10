defmodule Egregoros.MiniApps.CardMetadataTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.CardMetadata

  @page_url "https://app.example/polls/2026-budget"
  @app_origin "https://app.example"

  test "decodes strict page metadata" do
    json =
      Jason.encode!(%{
        "version" => "1",
        "title" => "Vote: 2026 budget",
        "imageUrl" => "https://app.example/cards/budget.png",
        "buttonTitle" => "Vote",
        "launchUrl" => @page_url
      })

    assert {:ok, card} = CardMetadata.decode(json, @page_url, @app_origin)
    assert card.title == "Vote: 2026 budget"
    assert card.button_title == "Vote"
    assert card.launch_url == @page_url
  end

  test "rejects duplicate keys and unknown fields" do
    duplicate =
      ~s|{"version":"1","title":"One","title":"Two","imageUrl":"https://app.example/card.png","buttonTitle":"Open","launchUrl":"https://app.example/"}|

    assert {:error, :duplicate_json_key} =
             CardMetadata.decode(duplicate, @page_url, @app_origin)

    unknown =
      Jason.encode!(%{
        "version" => "1",
        "title" => "One",
        "imageUrl" => "https://app.example/card.png",
        "buttonTitle" => "Open",
        "launchUrl" => "https://app.example/",
        "oauth" => %{}
      })

    assert {:error, :unknown_field} = CardMetadata.decode(unknown, @page_url, @app_origin)
  end

  test "requires the page, image, and launch url to use the app origin" do
    valid = %{
      "version" => "1",
      "title" => "One",
      "imageUrl" => "https://app.example/card.png",
      "buttonTitle" => "Open",
      "launchUrl" => "https://app.example/"
    }

    assert {:error, :origin_mismatch} =
             CardMetadata.decode(Jason.encode!(valid), "https://evil.example/page", @app_origin)

    for field <- ["imageUrl", "launchUrl"] do
      json = valid |> Map.put(field, "https://evil.example/") |> Jason.encode!()
      assert {:error, :origin_mismatch} = CardMetadata.decode(json, @page_url, @app_origin)
    end
  end

  test "enforces presentation length bounds" do
    base = %{
      "version" => "1",
      "title" => "One",
      "imageUrl" => "https://app.example/card.png",
      "buttonTitle" => "Open",
      "launchUrl" => "https://app.example/"
    }

    json = base |> Map.put("title", String.duplicate("a", 81)) |> Jason.encode!()
    assert {:error, :invalid_title} = CardMetadata.decode(json, @page_url, @app_origin)

    json = base |> Map.put("buttonTitle", String.duplicate("a", 33)) |> Jason.encode!()
    assert {:error, :invalid_button_title} = CardMetadata.decode(json, @page_url, @app_origin)
  end
end
