defmodule Egregoros.MiniApps.SecurityBoundaryHelpersTest do
  use ExUnit.Case, async: true

  import Mox

  alias Egregoros.MiniApps.Fetcher.BoundedHTTPError
  alias Egregoros.MiniApps.ImageSanitizer
  alias Egregoros.MiniApps.ImageSanitizer.Mock

  setup :verify_on_exit!

  test "bounded transport errors expose a stable diagnostic without flattening the reason" do
    error = %BoundedHTTPError{reason: {:invalid_response_headers, "content-length"}}

    assert Exception.message(error) ==
             "bounded HTTP fetch failed: {:invalid_response_headers, \"content-length\"}"
  end

  test "image sanitization delegates only binary payloads and media types" do
    body = <<0x89, "PNG">>
    sanitized = %{body: "sanitized", content_type: "image/webp"}

    expect(Mock, :sanitize, fn ^body, "image/png" -> {:ok, sanitized} end)

    assert {:ok, ^sanitized} = ImageSanitizer.sanitize(body, "image/png")

    for {invalid_body, invalid_content_type} <- [
          {nil, "image/png"},
          {body, nil},
          {[:not, :bytes], "image/png"},
          {body, :image_png}
        ] do
      assert {:error, :invalid_image} =
               ImageSanitizer.sanitize(invalid_body, invalid_content_type)
    end
  end
end
