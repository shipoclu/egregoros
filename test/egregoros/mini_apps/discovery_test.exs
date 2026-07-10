defmodule Egregoros.MiniApps.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.Discovery
  alias Egregoros.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "extracts strict HTTPS links from a fully public note in source order" do
    note =
      public_note("""
      <p>First <a href="https://one.example/path?view=full">one</a>.</p>
      <p>Then https://two.example/document and
      <a href="https://three.example/last">three</a>.</p>
      """)

    assert Discovery.candidate_urls(note) == [
             "https://one.example/path?view=full",
             "https://two.example/document",
             "https://three.example/last"
           ]
  end

  test "requires a listed public Note" do
    content = ~s(<a href="https://app.example/page">app</a>)

    unlisted = %Object{
      type: "Note",
      data: %{"content" => content, "to" => [], "cc" => [@public]}
    }

    private = %Object{type: "Note", data: %{"content" => content, "to" => []}}
    activity = %Object{type: "Create", data: %{"content" => content, "to" => [@public]}}

    assert Discovery.candidate_urls(unlisted) == []
    assert Discovery.candidate_urls(private) == []
    assert Discovery.candidate_urls(activity) == []
    assert Discovery.candidate_urls(%Object{type: "Note", data: nil}) == []
  end

  test "rejects unsafe and ineligible URLs without normalizing valid linked URLs" do
    note =
      public_note("""
      <a href="http://cleartext.example/">http</a>
      <a href="https://127.0.0.1/admin">ip</a>
      <a href="https://user:pass@app.example/">userinfo</a>
      <a href="https://app.example/page#section">fragment</a>
      <a href="https://App.Example:443/Exact?A=One&amp;B=Two">valid</a>
      """)

    assert Discovery.candidate_urls(note) == [
             "https://App.Example:443/Exact?A=One&B=Two"
           ]
  end

  test "does not discover URLs hidden in executable or non-content markup" do
    note =
      public_note("""
      <script>https://script.example/</script>
      <style>.x { background: url(https://style.example/) }</style>
      <template><a href="https://template.example/">hidden</a></template>
      <p><a href="https://visible.example/">visible</a></p>
      """)

    assert Discovery.candidate_urls(note) == ["https://visible.example/"]
  end

  test "does not include surrounding prose punctuation in a plain-text URL" do
    note = public_note("Read (https://app.example/chapter?mode=full), then continue.")

    assert Discovery.candidate_urls(note) == ["https://app.example/chapter?mode=full"]
  end

  test "does not treat mention or hashtag anchors as shared app links" do
    note =
      public_note("""
      <a class="u-url mention" href="https://social.example/users/alice">@alice</a>
      <a class="hashtag" href="https://social.example/tags/apps">#apps</a>
      <a href="https://app.example/reader">reader</a>
      """)

    assert Discovery.candidate_urls(note) == ["https://app.example/reader"]
  end

  test "deduplicates URLs and bounds extraction work" do
    links =
      ["https://one.example/", "https://one.example/"] ++
        Enum.map(2..20, &"https://#{&1}.example/")

    content = Enum.map_join(links, " ", &~s(<a href="#{&1}">link</a>))
    candidates = content |> public_note() |> Discovery.candidate_urls()

    assert length(candidates) == 10
    assert candidates == Enum.take(Enum.uniq(links), 10)
  end

  test "fails closed for oversized or malformed content" do
    oversized = public_note(String.duplicate("x", 100_001) <> " https://app.example/")

    assert Discovery.candidate_urls(oversized) == []
    assert Discovery.candidate_urls(public_note(<<255>>)) == []
    assert Discovery.candidate_urls(public_note(nil)) == []
    assert Discovery.candidate_urls(nil) == []
  end

  defp public_note(content) do
    %Object{type: "Note", data: %{"content" => content, "to" => [@public]}}
  end
end
