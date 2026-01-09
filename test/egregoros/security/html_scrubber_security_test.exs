defmodule Egregoros.Security.HTMLScrubberSecurityTest do
  use ExUnit.Case, async: true

  alias Egregoros.HTML

  @moduletag :security

  describe "HTML.sanitize/1 (security hardening)" do
    test "strips user-controlled utility classes (Tailwind/UI redress risk)" do
      html = "<span class=\"fixed inset-0 z-50 bg-white\">phish</span>"

      scrubbed = HTML.sanitize(html)

      refute scrubbed =~ "fixed"
      refute scrubbed =~ "inset-0"
      refute scrubbed =~ "z-50"
      assert scrubbed =~ "phish"
    end

    test "keeps emoji images but strips non-emoji classes" do
      html =
        "<img src=\"https://cdn.example/emoji.png\" alt=\":blob:\" class=\"emoji fixed\" width=\"20\" height=\"20\">"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<img"
      assert scrubbed =~ "src=\"https://cdn.example/emoji.png\""
      assert scrubbed =~ "class=\"emoji"
      refute scrubbed =~ "fixed"
    end

    test "drops non-emoji inline images (tracking pixel risk)" do
      html = "<p>ok</p><img src=\"https://tracker.example/pixel.png\" alt=\"tracker\">"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<p>ok</p>"
      refute scrubbed =~ "<img"
      refute scrubbed =~ "tracker.example"
    end
  end
end
