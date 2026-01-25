defmodule EgregorosWeb.MastodonAPI.MediaURLsTest do
  use ExUnit.Case, async: true

  alias EgregorosWeb.MastodonAPI.MediaURLs

  test "preview_url/1 extracts href from icon url list" do
    assert MediaURLs.preview_url(%{
             "icon" => %{"url" => [%{"href" => "https://example.com/p.png"}]}
           }) ==
             "https://example.com/p.png"
  end

  test "preview_url/2 falls back to the provided fallback map" do
    assert MediaURLs.preview_url(%{}, %{"icon" => %{"url" => "https://example.com/f.png"}}) ==
             "https://example.com/f.png"
  end

  test "preview_url/1 returns nil when no preview url is present" do
    assert MediaURLs.preview_url(%{"url" => "https://example.com/x"}) == nil
  end

  test "preview_url/1 returns nil for unsafe urls" do
    assert MediaURLs.preview_url(%{"icon" => %{"url" => "javascript:alert(1)"}}) == nil
  end
end
