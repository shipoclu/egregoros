defmodule EgregorosWeb.URLUploadsBaseURLTest do
  use ExUnit.Case, async: false

  alias EgregorosWeb.Endpoint
  alias EgregorosWeb.URL

  test "absolute/1 uses uploads_base_url for /uploads paths and Endpoint.url for other paths" do
    original = Application.get_env(:egregoros, :uploads_base_url)
    Application.put_env(:egregoros, :uploads_base_url, "https://i.example.com")

    try do
      assert URL.absolute("/uploads/media/1/file.png") ==
               "https://i.example.com/uploads/media/1/file.png"

      assert URL.absolute("/objects/123") == Endpoint.url() <> "/objects/123"
    after
      restore_uploads_base_url(original)
    end
  end

  test "absolute/2 keeps remote base for /uploads paths on remote actors" do
    original = Application.get_env(:egregoros, :uploads_base_url)
    Application.put_env(:egregoros, :uploads_base_url, "https://i.example.com")

    try do
      assert URL.absolute("/uploads/avatars/1/avatar.png", "https://remote.example/users/alice") ==
               "https://remote.example/uploads/avatars/1/avatar.png"
    after
      restore_uploads_base_url(original)
    end
  end

  test "absolute/2 uses uploads_base_url for /uploads paths on local actors" do
    original = Application.get_env(:egregoros, :uploads_base_url)
    Application.put_env(:egregoros, :uploads_base_url, "https://i.example.com")

    try do
      base = Endpoint.url() <> "/users/alice"

      assert URL.absolute("/uploads/avatars/1/avatar.png", base) ==
               "https://i.example.com/uploads/avatars/1/avatar.png"
    after
      restore_uploads_base_url(original)
    end
  end

  defp restore_uploads_base_url(nil) do
    Application.delete_env(:egregoros, :uploads_base_url)
  end

  defp restore_uploads_base_url(value) do
    Application.put_env(:egregoros, :uploads_base_url, value)
  end
end
