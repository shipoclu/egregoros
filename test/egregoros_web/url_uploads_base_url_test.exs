defmodule EgregorosWeb.URLUploadsBaseURLTest do
  use ExUnit.Case, async: true

  alias Egregoros.RuntimeConfig
  alias EgregorosWeb.Endpoint
  alias EgregorosWeb.URL

  test "absolute/1 uses uploads_base_url for /uploads paths and Endpoint.url for other paths" do
    RuntimeConfig.with(%{uploads_base_url: "https://i.example.com"}, fn ->
      assert URL.absolute("/uploads/media/1/file.png") ==
               "https://i.example.com/uploads/media/1/file.png"

      assert URL.absolute("/objects/123") == Endpoint.url() <> "/objects/123"
    end)
  end

  test "absolute/2 keeps remote base for /uploads paths on remote actors" do
    RuntimeConfig.with(%{uploads_base_url: "https://i.example.com"}, fn ->
      assert URL.absolute("/uploads/avatars/1/avatar.png", "https://remote.example/users/alice") ==
               "https://remote.example/uploads/avatars/1/avatar.png"
    end)
  end

  test "absolute/2 uses uploads_base_url for /uploads paths on local actors" do
    RuntimeConfig.with(%{uploads_base_url: "https://i.example.com"}, fn ->
      base = Endpoint.url() <> "/users/alice"

      assert URL.absolute("/uploads/avatars/1/avatar.png", base) ==
               "https://i.example.com/uploads/avatars/1/avatar.png"
    end)
  end

  test "absolute/1 returns the empty string for an empty string" do
    assert URL.absolute("") == ""
  end

  test "absolute/2 returns the empty string for empty or whitespace-only strings" do
    assert URL.absolute("", Endpoint.url()) == ""
    assert URL.absolute("   ", Endpoint.url()) == ""
  end

  test "absolute/2 falls back to absolute/1 for invalid bases" do
    assert URL.absolute("objects/123", "ftp://example.com") == Endpoint.url() <> "/objects/123"
    assert URL.absolute("objects/123", :not_a_url) == Endpoint.url() <> "/objects/123"
  end

  test "absolute/2 falls back to absolute/1 for non-binary urls" do
    assert URL.absolute(123, Endpoint.url()) == ""
  end
end
