defmodule Egregoros.HTMLTest do
  use ExUnit.Case, async: true

  import Mox

  alias Egregoros.HTML

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "sanitize/1" do
    test "returns an empty string for nil and non-binary input" do
      assert HTML.sanitize(nil) == ""
      assert HTML.sanitize(123) == ""
    end

    test "removes script tags" do
      html = "<p>ok</p><script>alert(1)</script>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "ok"
      refute scrubbed =~ "<script"
    end

    test "removes event handler attributes" do
      html = "<p onclick=\"alert(1)\">ok</p>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "ok"
      refute scrubbed =~ "onclick="
      refute scrubbed =~ "alert(1)"
    end

    test "rejects javascript: hrefs" do
      html = "<a href=\"javascript:alert(1)\">x</a>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ ">x<"
      refute scrubbed =~ "javascript:"
    end

    test "does not turn encoded colons in href attributes into javascript: schemes" do
      html = "<a href=\"javascript&amp;#x3A;alert(1)\">x</a>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ ">x<"
      refute scrubbed =~ "javascript:"
      refute scrubbed =~ "javascript&#x3A;"
      refute scrubbed =~ "javascript&#58;"
    end

    test "adds safe rel attributes to links" do
      html = "<a href=\"https://example.com\">x</a>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "nofollow"
      assert scrubbed =~ "noopener"
      assert scrubbed =~ "noreferrer"
    end

    test "preserves existing rel values while adding required ones" do
      html = "<a href=\"https://example.com\" rel=\"me\">x</a>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "rel="
      assert scrubbed =~ "me"
      assert scrubbed =~ "nofollow"
      assert scrubbed =~ "noopener"
      assert scrubbed =~ "noreferrer"
    end

    test "does not duplicate required rel values (case-insensitive)" do
      html = "<a href=\"https://example.com\" rel=\"NOFOLLOW noopener\">x</a>"

      scrubbed = HTML.sanitize(html)

      assert [_, rel] = Regex.run(~r/rel="([^"]+)"/, scrubbed)

      tokens =
        rel
        |> String.split(~r/\s+/, trim: true)
        |> Enum.map(&String.downcase/1)

      assert Enum.uniq(tokens) == tokens
      assert "nofollow" in tokens
      assert "noopener" in tokens
      assert "noreferrer" in tokens
    end

    test "preserves allowed attributes on links" do
      html = "<a href=\"https://example.com\" class=\"mention\" title=\"hello\">x</a>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ ~s(class="mention")
      assert scrubbed =~ ~s(title="hello")
    end

    test "only allows safe target values on links" do
      html = "<a href=\"https://example.com\" target=\"_blank\">x</a>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ ~s(target="_blank")

      scrubbed = HTML.sanitize("<a href=\"https://example.com\" target=\"evil\">x</a>")
      refute scrubbed =~ ~s(target="evil")
    end

    test "removes disallowed tags like iframe" do
      html = "<p>ok</p><iframe src=\"https://evil.example/\"></iframe>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "ok"
      refute scrubbed =~ "<iframe"
    end

    test "removes html comments" do
      html = "<p>ok</p><!-- secret --><p>more</p>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<p>ok</p>"
      assert scrubbed =~ "<p>more</p>"
      refute scrubbed =~ "<!--"
      refute scrubbed =~ "secret"
    end

    test "allows basic formatting tags" do
      html = "<p>hello <strong>bold</strong> <em>em</em> <u>u</u> <s>s</s></p>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<strong>bold</strong>"
      assert scrubbed =~ "<em>em</em>"
      assert scrubbed =~ "<u>u</u>"
      assert scrubbed =~ "<s>s</s>"
    end

    test "allows code blocks and strips classes" do
      html =
        "<pre class=\"highlight\"><code class=\"language-elixir\">IO.puts(1)</code></pre>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<pre>"
      assert scrubbed =~ "<code>"
      assert scrubbed =~ "IO.puts"
      refute scrubbed =~ "highlight"
      refute scrubbed =~ "language-elixir"
    end

    test "allows lists and strips classes" do
      html = "<ul class=\"list\"><li class=\"item\">one</li><li>two</li></ul>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<ul"
      assert scrubbed =~ "<li"
      assert scrubbed =~ ">one<"
      assert scrubbed =~ ">two<"
      refute scrubbed =~ "class="
    end

    test "allows span and blockquote and strips classes and event handlers" do
      html =
        "<blockquote class=\"quote\"><span class=\"mention\" onclick=\"alert(1)\">@alice</span></blockquote>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<blockquote"
      assert scrubbed =~ "<span"
      assert scrubbed =~ "@alice"
      refute scrubbed =~ "onclick="
      refute scrubbed =~ "alert(1)"
      refute scrubbed =~ "class="
    end

    test "allows img tags with http(s) src" do
      html = "<p>ok</p><img src=\"https://cdn.example/emoji.png\" alt=\":blob:\" class=\"emoji\">"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<img"
      assert scrubbed =~ "src=\"https://cdn.example/emoji.png\""
    end

    test "preserves allowed img dimension attributes" do
      html = "<img src=\"https://cdn.example/x.png\" alt=\":x:\" width=\"100\" height=\"50\">"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "<img"
      assert scrubbed =~ ~s(width="100")
      assert scrubbed =~ ~s(height="50")
    end

    test "removes event handler attributes from img tags" do
      html =
        "<img src=\"https://cdn.example/x.png\" onerror=\"alert(1)\" alt=\"x\" class=\"emoji\">"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ "src=\"https://cdn.example/x.png\""
      refute scrubbed =~ "onerror="
      refute scrubbed =~ "alert(1)"
    end

    test "rejects javascript: src on img tags" do
      html = "<img src=\"javascript:alert(1)\" alt=\"x\" class=\"emoji\">"

      scrubbed = HTML.sanitize(html)

      refute scrubbed =~ "javascript:"
      refute scrubbed =~ "alert(1)"
    end

    test "falls back to escaping when scrub fails" do
      Egregoros.HTML.Sanitizer.Mock
      |> expect(:scrub, fn _html, _scrubber -> {:error, :boom} end)

      scrubbed =
        HTML.sanitize("<p>ok</p><script>alert(1)</script>", Egregoros.HTML.Sanitizer.Mock)

      assert scrubbed =~ "&lt;p&gt;ok&lt;/p&gt;"
      refute scrubbed =~ "<script"
    end

    test "falls back to escaping when scrub raises" do
      Egregoros.HTML.Sanitizer.Mock
      |> expect(:scrub, fn _html, _scrubber -> raise "boom" end)

      scrubbed = HTML.sanitize("<p>ok</p>", Egregoros.HTML.Sanitizer.Mock)

      assert scrubbed =~ "&lt;p&gt;ok&lt;/p&gt;"
    end

    test "returns an empty string for invalid sanitize/2 inputs" do
      assert HTML.sanitize(:not_a_binary, FastSanitize.Sanitizer) == ""
      assert HTML.sanitize("<p>ok</p>", "not_a_module") == ""
    end

    test "falls back to escaping when scrub throws or exits" do
      Egregoros.HTML.Sanitizer.Mock
      |> expect(:scrub, fn _html, _scrubber -> throw(:boom) end)

      assert HTML.sanitize("<p>ok</p>", Egregoros.HTML.Sanitizer.Mock) =~ "&lt;p&gt;ok&lt;/p&gt;"

      Egregoros.HTML.Sanitizer.Mock
      |> expect(:scrub, fn _html, _scrubber -> exit(:boom) end)

      assert HTML.sanitize("<p>ok</p>", Egregoros.HTML.Sanitizer.Mock) =~ "&lt;p&gt;ok&lt;/p&gt;"
    end

    test "unescapes ampersands in text nodes but preserves them in attributes" do
      html = "<a href='https://example.com/?a=1&amp;b=2'>AT&amp;T</a>"

      scrubbed = HTML.sanitize(html)

      assert scrubbed =~ ~s(href="https://example.com/?a=1&amp;b=2")
      assert scrubbed =~ ">AT&T</a>"
    end

    test "unescapes ampersands for sanitizer output using single-quoted attributes" do
      Egregoros.HTML.Sanitizer.Mock
      |> expect(:scrub, fn _html, _scrubber ->
        {:ok, "<a href='https://example.com/?a=1&amp;b=2'>AT&amp;T</a>"}
      end)

      scrubbed = HTML.sanitize("<p>ignored</p>", Egregoros.HTML.Sanitizer.Mock)

      assert scrubbed =~ "href='https://example.com/?a=1&amp;b=2'"
      assert scrubbed =~ ">AT&T</a>"
    end
  end

  describe "to_safe_html/2" do
    test "supports default options and returns safe html" do
      assert HTML.to_safe_html("hello") =~ "<p>hello</p>"
    end

    test "returns an empty string for nil, blank, or non-binary content" do
      assert HTML.to_safe_html(nil) == ""
      assert HTML.to_safe_html("   \n") == ""
      assert HTML.to_safe_html(123, format: :text) == ""
    end

    test "renders plain text as escaped html" do
      assert HTML.to_safe_html("<script>alert(1)</script>", format: :text) =~
               "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "wraps plain text in a paragraph" do
      assert HTML.to_safe_html("hello", format: :text) =~ "<p>hello</p>"
    end

    test "converts newlines to br" do
      assert HTML.to_safe_html("hello\nworld", format: :text) =~ "<br"
    end

    test "sanitizes html input" do
      safe = HTML.to_safe_html("<p>ok</p><script>alert(1)</script>", format: :html)
      assert safe =~ "<p>ok</p>"
      refute safe =~ "<script"
    end

    test "treats :html content without html tags as plain text" do
      assert HTML.to_safe_html("hello", format: :html) =~ "<p>hello</p>"
    end

    test "doesn't double-escape existing entities when converting to html" do
      safe = HTML.to_safe_html("there&#39;s", format: :html)
      assert safe =~ "there&#39;s"
      refute safe =~ "there&amp;#39;s"

      safe = HTML.to_safe_html("there&apos;s", format: :html)
      assert safe =~ "there&#39;s"
      refute safe =~ "there&amp;apos;"
    end

    test "unescapes double-escaped entities in html input" do
      safe = HTML.to_safe_html("<p>there&amp;#39;s</p>", format: :html)
      assert safe =~ ~r/there(&#39;|&apos;|')s/
      refute safe =~ "there&amp;#39;s"

      safe = HTML.to_safe_html("<p>there&amp;apos;s</p>", format: :html)
      assert safe =~ ~r/there(&#39;|&apos;|')s/
      refute safe =~ "there&amp;apos;"
    end

    test "preserves text like <3 when entities are present" do
      safe = HTML.to_safe_html("I&#39;m <3", format: :html)
      assert safe =~ "I&#39;m"
      assert safe =~ "&lt;3"
    end

    test "linkifies local @mentions in plain text" do
      safe = HTML.to_safe_html("hi @alice", format: :text)
      href = "#{EgregorosWeb.Endpoint.url()}/@alice"

      assert safe =~
               ~r/<a[^>]*href="#{Regex.escape(href)}"[^>]*class="[^"]*u-url[^"]*mention[^"]*mention-link[^"]*"[^>]*>@<span>alice<\/span><\/a>/
    end

    test "linkifies remote @mentions in plain text" do
      safe = HTML.to_safe_html("hi @bob@example.com", format: :text)
      href = "#{EgregorosWeb.Endpoint.url()}/@bob@example.com"

      assert safe =~
               ~r/<a[^>]*href="#{Regex.escape(href)}"[^>]*class="[^"]*u-url[^"]*mention[^"]*mention-link[^"]*"[^>]*>@<span>bob@example\.com<\/span><\/a>/
    end

    test "rewrites mention links in ActivityPub html when tag href differs from content href" do
      html =
        "<span class=\"h-card\">" <>
          "<a class=\"u-url mention\" href=\"https://toot.cat/@Aaron_Davis\" rel=\"ugc\">" <>
          "@<span>Aaron_Davis</span></a>" <>
          "</span>"

      tags = [
        %{
          "type" => "Mention",
          "href" => "https://toot.cat/users/Aaron_Davis",
          "name" => "@Aaron_Davis@toot.cat"
        }
      ]

      safe = HTML.to_safe_html(html, format: :html, ap_tags: tags)
      expected_href = "#{EgregorosWeb.Endpoint.url()}/@Aaron_Davis@toot.cat"

      href = Regex.escape(expected_href)

      assert safe =~
               ~r/<a[^>]*(?:href="#{href}"[^>]*class="[^"]*mention-link[^"]*"|class="[^"]*mention-link[^"]*"[^>]*href="#{href}")/
    end

    test "does not linkify email addresses" do
      safe = HTML.to_safe_html("contact alice@example.com", format: :text)
      refute safe =~ "<a "
    end

    test "keeps trailing punctuation outside mention links" do
      safe = HTML.to_safe_html("hi @alice,", format: :text)
      assert safe =~ "</a></span>,"
    end

    test "linkifies @mentions inside surrounding punctuation" do
      safe = HTML.to_safe_html("hi (@alice)", format: :text)

      assert safe =~ "(<span"
      assert safe =~ ~s(href="#{EgregorosWeb.Endpoint.url()}/@alice")
      assert safe =~ "@<span>alice</span></a></span>)"
    end

    test "linkifies multiple @mentions inside the same token" do
      safe = HTML.to_safe_html("hi (@alice,@bob@example.com)", format: :text)

      alice_href = "#{EgregorosWeb.Endpoint.url()}/@alice"
      bob_href = "#{EgregorosWeb.Endpoint.url()}/@bob@example.com"

      assert safe =~ "(<span"

      assert safe =~
               ~r/<a[^>]*href="#{Regex.escape(alice_href)}"[^>]*class="[^"]*u-url[^"]*mention[^"]*mention-link[^"]*"[^>]*>@<span>alice<\/span><\/a>/

      assert safe =~ "</a></span>,<span"

      assert safe =~
               ~r/<a[^>]*href="#{Regex.escape(bob_href)}"[^>]*class="[^"]*u-url[^"]*mention[^"]*mention-link[^"]*"[^>]*>@<span>bob@example\.com<\/span><\/a>/

      assert safe =~ "@<span>bob@example.com</span></a></span>)"
    end

    test "linkifies hashtags in plain text" do
      safe = HTML.to_safe_html("hi #elixir", format: :text)
      assert safe =~ ~s(href="#{EgregorosWeb.Endpoint.url()}/tags/elixir")
      assert safe =~ ">#elixir</a>"
    end

    test "keeps trailing punctuation outside hashtag links" do
      safe = HTML.to_safe_html("hi #elixir,", format: :text)
      assert safe =~ ">#elixir</a>,"
    end

    test "linkifies http(s) urls in plain text" do
      safe = HTML.to_safe_html("see https://example.com/path", format: :text)
      assert safe =~ ~s(href="https://example.com/path")
      assert safe =~ ">https://example.com/path</a>"
    end

    test "keeps trailing punctuation outside url links" do
      safe = HTML.to_safe_html("see https://example.com).", format: :text)
      assert safe =~ ~s(href="https://example.com")
      assert safe =~ ">https://example.com</a>)."
    end

    test "falls back to auto-building mention hrefs when mention_hrefs is not a map" do
      safe = HTML.to_safe_html("hi @alice", format: :text, mention_hrefs: "nope")
      href = "#{EgregorosWeb.Endpoint.url()}/@alice"

      assert safe =~
               ~r/<a[^>]*href="#{Regex.escape(href)}"[^>]*class="[^"]*mention-link[^"]*"[^>]*>@<span>alice<\/span><\/a>/
    end

    test "treats @mentions for the local domain as local profiles" do
      endpoint = EgregorosWeb.Endpoint.url()
      %URI{host: host, port: port} = URI.parse(endpoint)

      domain =
        case port do
          nil -> host
          80 -> host
          443 -> host
          port when is_integer(port) -> host <> ":" <> Integer.to_string(port)
        end

      safe = HTML.to_safe_html("hi @alice@#{domain}", format: :text)

      assert safe =~ ~s(href="#{endpoint}/@alice")
    end

    test "linkifies urls inside surrounding punctuation" do
      safe = HTML.to_safe_html("see (https://example.com)", format: :text)
      assert safe =~ "(<a "
      assert safe =~ ~s(href="https://example.com")
      assert safe =~ ">https://example.com</a>)"
    end

    test "does not linkify non-http urls in plain text" do
      safe = HTML.to_safe_html("see javascript:alert(1)", format: :text)
      refute safe =~ "<a "
      assert safe =~ "javascript:alert(1)"
    end

    test "replaces custom emoji shortcodes in plain text when tags are provided" do
      safe =
        HTML.to_safe_html("hi :shrug:",
          format: :text,
          emojis: [%{shortcode: "shrug", url: "https://cdn.example/shrug.png"}]
        )

      assert safe =~ "<img"
      assert safe =~ "src=\"https://cdn.example/shrug.png\""
      assert safe =~ "alt=\":shrug:\""
    end

    test "replaces custom emoji shortcodes in html input when tags are provided" do
      safe =
        HTML.to_safe_html("<p>hi :shrug:</p>",
          format: :html,
          emojis: [%{shortcode: "shrug", url: "https://cdn.example/shrug.png"}]
        )

      assert safe =~ "<p>hi"
      assert safe =~ "<img"
      assert safe =~ "src=\"https://cdn.example/shrug.png\""
    end

    test "does not render custom emojis with unsafe urls" do
      safe =
        HTML.to_safe_html("hi :shrug:",
          format: :text,
          emojis: [%{shortcode: "shrug", url: "javascript:alert(1)"}]
        )

      refute safe =~ "<img"
      assert safe =~ ":shrug:"
    end

    test "does not render custom emojis with localhost or private ip urls" do
      safe =
        HTML.to_safe_html("hi :shrug:",
          format: :text,
          emojis: [%{shortcode: "shrug", url: "http://localhost/emoji.png"}]
        )

      refute safe =~ "<img"
      assert safe =~ ":shrug:"

      safe =
        HTML.to_safe_html("hi :shrug:",
          format: :text,
          emojis: [%{shortcode: "shrug", url: "http://127.0.0.1/emoji.png"}]
        )

      refute safe =~ "<img"
      assert safe =~ ":shrug:"
    end

    test "keeps unknown shortcodes intact in html input when emojis are provided" do
      safe =
        HTML.to_safe_html("<p>hi :shrug:</p>",
          format: :html,
          emojis: [%{shortcode: "other", url: "https://cdn.example/other.png"}]
        )

      assert safe =~ ":shrug:"
      refute safe =~ "<img"
    end

    test "keeps unknown shortcodes intact in plain text when an emoji map exists" do
      safe =
        HTML.to_safe_html("hi :shrug:",
          format: :text,
          emojis: [%{shortcode: "other", url: "https://cdn.example/other.png"}]
        )

      assert safe =~ ":shrug:"
      refute safe =~ "<img"
    end

    test "accepts emojis as a precomputed shortcode->url map" do
      safe =
        HTML.to_safe_html("hi :shrug:",
          format: :text,
          emojis: %{"shrug" => "https://cdn.example/shrug.png"}
        )

      assert safe =~ "<img"
      assert safe =~ "src=\"https://cdn.example/shrug.png\""
    end

    test "does not linkify invalid http urls" do
      safe = HTML.to_safe_html("see https://)", format: :text)

      assert safe =~ "https://)"
      refute safe =~ "<a "
    end

    test "handles lines that start with whitespace while linkifying" do
      safe = HTML.to_safe_html("hi\n @alice", format: :text)
      assert safe =~ "<br"
      assert safe =~ ~s(href="#{EgregorosWeb.Endpoint.url()}/@alice")
    end

    test "styles mention links in html input when mention tags are provided" do
      safe =
        HTML.to_safe_html("<p>hi <a href=\"https://remote.example/users/bob\">@bob</a></p>",
          format: :html,
          ap_tags: [
            %{
              "type" => "Mention",
              "href" => "https://remote.example/users/bob",
              "name" => "@bob@remote.example"
            }
          ]
        )

      href = "#{EgregorosWeb.Endpoint.url()}/@bob@remote.example"

      assert safe =~
               ~r/<a[^>]*href="#{Regex.escape(href)}"[^>]*class="mention-link"[^>]*>@bob<\/a>/
    end

    test "rewrites mention links based on href data when the mention name is not parseable" do
      safe =
        HTML.to_safe_html("<p>hi <a href='https://remote.example/users/bob'>@</a></p>",
          format: :html,
          ap_tags: [
            %{
              "type" => "Mention",
              "href" => "https://remote.example/users/bob",
              "name" => "@"
            }
          ]
        )

      href = "#{EgregorosWeb.Endpoint.url()}/@bob@remote.example"

      assert safe =~ ~s(href="#{href}")
      assert safe =~ "mention-link"
    end

    test "does not duplicate mention-link classes when the link already has them" do
      safe =
        HTML.to_safe_html(
          "<p>hi <a class='mention-link u-url mention' href='https://remote.example/users/bob'>@bob</a></p>",
          format: :html,
          ap_tags: [
            %{
              "type" => "Mention",
              "href" => "https://remote.example/users/bob",
              "name" => "@bob@remote.example"
            }
          ]
        )

      assert String.split(safe, "mention-link") |> length() == 2
      assert safe =~ ~s(href="#{EgregorosWeb.Endpoint.url()}/@bob@remote.example")
    end

    test "styles mention links in html input when mention tag is a map" do
      safe =
        HTML.to_safe_html("<p>hi <a href=\"https://remote.example/users/bob\">@bob</a></p>",
          format: :html,
          ap_tags: %{
            "type" => "Mention",
            "href" => "https://remote.example/users/bob",
            "name" => "@bob@remote.example"
          }
        )

      href = "#{EgregorosWeb.Endpoint.url()}/@bob@remote.example"

      assert safe =~
               ~r/<a[^>]*href="#{Regex.escape(href)}"[^>]*class="mention-link"[^>]*>@bob<\/a>/
    end

    test "rewrites mention links when tag name does not include the domain" do
      safe =
        HTML.to_safe_html("<p>hi <a href=\"https://remote.example/users/bob\">@bob</a></p>",
          format: :html,
          ap_tags: [
            %{
              "type" => "Mention",
              "href" => "https://remote.example/users/bob",
              "name" => "@bob"
            }
          ]
        )

      href = "#{EgregorosWeb.Endpoint.url()}/@bob@remote.example"

      assert safe =~
               ~r/<a[^>]*href="#{Regex.escape(href)}"[^>]*class="mention-link"[^>]*>@bob<\/a>/
    end
  end

  describe "to_safe_inline_html/2" do
    test "supports default options and escapes inline html" do
      assert HTML.to_safe_inline_html("<b>hi</b>") == "&lt;b&gt;hi&lt;/b&gt;"
    end

    test "returns an empty string for nil content or non-list opts" do
      assert HTML.to_safe_inline_html(nil) == ""
      assert HTML.to_safe_inline_html("hi", %{emojis: []}) == ""
    end

    test "decodes valid numeric entities and preserves invalid ones" do
      assert HTML.to_safe_inline_html("&#x1F525;") =~ "🔥"
      assert HTML.to_safe_inline_html("&#55296;") == "&amp;#55296;"
      assert HTML.to_safe_inline_html("&#xD800;") == "&amp;#xD800;"
    end

    test "renders emoji shortcodes as inline img tags" do
      safe =
        HTML.to_safe_inline_html(":shrug: hi",
          emojis: [%{shortcode: "shrug", url: "https://cdn.example/shrug.png"}]
        )

      assert safe =~ "<img"
      assert safe =~ "src=\"https://cdn.example/shrug.png\""
      assert safe =~ "alt=\":shrug:\""
      assert safe =~ "hi"
      refute safe =~ "<p>"
    end

    test "does not render custom emojis with unsafe urls" do
      safe =
        HTML.to_safe_inline_html(":shrug: hi",
          emojis: [%{shortcode: "shrug", url: "javascript:alert(1)"}]
        )

      refute safe =~ "<img"
      assert safe =~ ":shrug:"
    end
  end
end
