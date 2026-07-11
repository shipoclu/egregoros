defmodule Egregoros.MiniApps.ExternalURLTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.ExternalURL

  test "accepts one absolute public HTTPS URL without rewriting it" do
    url = "https://Docs.Example.:8443/guide?page=2#section"
    assert {:ok, ^url} = ExternalURL.validate(url)

    encoded_url = "https://docs.example/a%2Fb"
    assert {:ok, ^encoded_url} = ExternalURL.validate(encoded_url)
  end

  test "rejects browser and server parser differentials" do
    for url <- [
          "http://docs.example/",
          "//docs.example/",
          "https://localhost/",
          "https://127.0.0.1/",
          "https://127.0x0.1/",
          "https://127.0.0x0.1/",
          "https://user@docs.example/",
          "https://@docs.example/",
          "https://docs.example/has space",
          "https://docs.example/back\\slash",
          "https://docs.example/raw\r\nheader:value",
          "https://docs.example/bare%",
          "https://docs.example/encoded%00nul",
          "https://docs.example/encoded%0dreturn",
          "https://docs.example/encoded%0alinefeed",
          "https://docs.example/encoded%0Alinefeed",
          "https://docs.example/encoded%7fdelete",
          "https://docs.example/encoded%5cbackslash",
          "https://docs.example/invalid%GGescape"
        ] do
      assert {:error, :invalid_url} = ExternalURL.validate(url)
    end
  end

  test "rejects non-binary, oversized, and invalid UTF-8 input" do
    for input <- [nil, :undefined, 12, ["https://docs.example/"], %{}] do
      assert {:error, :invalid_url} = ExternalURL.validate(input)
    end

    prefix = "https://docs.example/"
    maximum = prefix <> String.duplicate("a", 2_048 - byte_size(prefix))

    assert byte_size(maximum) == 2_048
    assert {:ok, ^maximum} = ExternalURL.validate(maximum)
    assert {:error, :invalid_url} = ExternalURL.validate(maximum <> "a")

    assert {:error, :invalid_url} =
             ExternalURL.validate(<<"https://docs.example/", 0xC3, 0x28>>)

    assert {:error, :invalid_url} =
             ExternalURL.validate(<<"https://docs.example/", 0xFF>>)
  end

  test "accepts only TCP port numbers inside the valid range" do
    for port <- [1, 443, 65_535] do
      url = "https://docs.example:#{port}/"
      assert {:ok, ^url} = ExternalURL.validate(url)
    end

    for url <- [
          "https://docs.example:0/",
          "https://docs.example:65536/",
          "https://docs.example:-1/",
          "https://docs.example:+443/",
          "https://docs.example:443junk/"
        ] do
      assert {:error, :invalid_url} = ExternalURL.validate(url)
    end
  end
end
