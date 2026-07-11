defmodule Egregoros.MiniApps.OriginTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.Origin

  test "derives an exact normalized origin from a strict launch URL" do
    assert {:ok, "https://app.example"} =
             Origin.from_url("https://App.Example:443/path?mode=full")

    assert {:ok, "https://app.example:8443"} =
             Origin.from_url("https://app.example:8443/path")
  end

  test "returns one canonical URL for the exact URI accepted by the origin parser" do
    assert {:ok, "https://app.example/path?mode=full", "https://app.example"} =
             Origin.normalize_url("HTTPS://App.Example.:443/path?mode=full")

    assert {:ok, "https://app.example:8443/path", "https://app.example:8443"} =
             Origin.normalize_url("https://App.Example.:8443/path")
  end

  test "rejects malformed launch URLs and non-string values" do
    for url <- [
          "http://app.example/",
          "https://127.0.0.1/",
          "https://127.0x0.1/",
          "https://127.0.0x0.1/",
          "https://user@app.example/",
          "https://@app.example/",
          "https://app.example/path#fragment",
          "https://app.example:0/"
        ] do
      assert {:error, :invalid_url} = Origin.from_url(url)
    end

    assert {:error, :invalid_url} = Origin.from_url(nil)
    assert {:error, :invalid_origin} = Origin.parse_origin(nil)
    assert {:error, :invalid_manifest_url} = Origin.from_manifest_url(nil)
  end

  test "rejects URL parser differentials before any URL is fetched" do
    for suffix <- [
          "/raw\r\nheader:value",
          "/raw\0value",
          "/raw\tvalue",
          "/has space",
          "/back\\slash",
          "/bare%",
          "/short%0",
          "/invalid%zz",
          "/encoded%00nul",
          "/encoded%0dreturn",
          "/encoded%0Alinefeed",
          "/encoded%7fdelete",
          "/encoded%5cbackslash"
        ] do
      assert {:error, :invalid_url} = Origin.from_url("https://app.example" <> suffix)
      assert {:error, :invalid_url} = Origin.normalize_url("https://app.example" <> suffix)
    end

    assert {:error, :invalid_url} = Origin.from_url("//app.example/path")
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
