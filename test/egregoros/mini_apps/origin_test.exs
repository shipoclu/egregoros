defmodule Egregoros.MiniApps.OriginTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.Origin

  test "derives an exact normalized origin from a strict launch URL" do
    assert {:ok, "https://app.example"} =
             Origin.from_url("https://App.Example:443/path?mode=full")

    assert {:ok, "https://app.example:8443"} =
             Origin.from_url("https://app.example:8443/path")
  end

  test "rejects malformed launch URLs and non-string values" do
    for url <- [
          "http://app.example/",
          "https://127.0.0.1/",
          "https://user@app.example/",
          "https://app.example/path#fragment",
          "https://app.example:0/"
        ] do
      assert {:error, :invalid_url} = Origin.from_url(url)
    end

    assert {:error, :invalid_url} = Origin.from_url(nil)
    assert {:error, :invalid_origin} = Origin.parse_origin(nil)
    assert {:error, :invalid_manifest_url} = Origin.from_manifest_url(nil)
  end

  test "enforces exact well-known manifest and origin URL relationships" do
    assert {:error, :invalid_manifest_url} =
             Origin.from_manifest_url(
               "https://app.example/.well-known/fediverse-miniapp.json?cache=no"
             )

    assert {:error, :invalid_origin} = Origin.parse_origin("https://app.example/path")

    assert {:error, :origin_mismatch} =
             Origin.validate_url("https://other.example/page", "https://app.example")

    assert {:error, :invalid_url} = Origin.validate_url(nil, "https://app.example")
  end
end
