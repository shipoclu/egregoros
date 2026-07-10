defmodule Egregoros.MiniApps.PageMetadataTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.PageMetadata

  test "extracts the single mini-app meta value" do
    html = """
    <!doctype html>
    <html><head>
      <meta charset="utf-8">
      <meta content='{&quot;version&quot;:&quot;1&quot;}' name="fediverse:miniapp">
    </head><body></body></html>
    """

    assert {:ok, ~s({"version":"1"})} = PageMetadata.extract(html)
  end

  test "reports no metadata when the element is absent" do
    assert {:ok, nil} = PageMetadata.extract("<html><head></head><body>reader</body></html>")
  end

  test "rejects duplicate tags, missing content, and oversized HTML" do
    duplicate =
      ~s(<meta name="fediverse:miniapp" content="{}"><meta name="fediverse:miniapp" content="{}">)

    assert {:error, :duplicate_card_metadata} = PageMetadata.extract(duplicate)

    assert {:error, :invalid_card_metadata} =
             PageMetadata.extract(~s(<meta name="fediverse:miniapp">))

    assert {:error, :page_too_large} = PageMetadata.extract(String.duplicate("x", 1_000_001))
  end

  test "ignores similarly named elements and content outside a meta attribute" do
    html = """
    <div name="fediverse:miniapp" content="evil"></div>
    <script>fediverse:miniapp</script>
    """

    assert {:ok, nil} = PageMetadata.extract(html)
  end

  test "fails closed for invalid input encodings and types" do
    assert {:error, :invalid_page} = PageMetadata.extract(<<255>>)
    assert {:error, :invalid_page} = PageMetadata.extract(nil)
  end
end
