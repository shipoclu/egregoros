defmodule PleromaReduxWeb.MastodonAPI.StatusRendererTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Objects
  alias PleromaRedux.Pipeline
  alias PleromaRedux.TestSupport.PleromaOldFixtures
  alias PleromaReduxWeb.MastodonAPI.StatusRenderer

  test "sanitizes remote html content" do
    {:ok, object} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/1",
        type: "Note",
        actor: "https://remote.example/users/alice",
        local: false,
        data: %{
          "id" => "https://remote.example/objects/1",
          "type" => "Note",
          "actor" => "https://remote.example/users/alice",
          "content" => "<p>ok</p><script>alert(1)</script>"
        }
      })

    rendered = StatusRenderer.render_status(object)

    assert rendered["content"] =~ "<p>ok</p>"
    refute rendered["content"] =~ "<script"
  end

  test "escapes local content as text" do
    {:ok, object} =
      Objects.create_object(%{
        ap_id: "https://local.example/objects/2",
        type: "Note",
        actor: "https://local.example/users/alice",
        local: true,
        data: %{
          "id" => "https://local.example/objects/2",
          "type" => "Note",
          "actor" => "https://local.example/users/alice",
          "content" => "<script>alert(1)</script>"
        }
      })

    rendered = StatusRenderer.render_status(object)

    assert rendered["content"] =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute rendered["content"] =~ "<script"
  end

  test "renders mentions and hashtags from ActivityPub tag data" do
    activity = PleromaOldFixtures.json!("mastodon-post-activity-hashtag.json")

    assert {:ok, create} = Pipeline.ingest(activity, local: false)
    note = Objects.get_by_ap_id(create.object)

    rendered = StatusRenderer.render_status(note)

    assert [%{"url" => "http://localtesting.pleroma.lol/users/lain"} = mention] = rendered["mentions"]
    assert mention["username"] == "lain"
    assert mention["acct"] == "lain@localtesting.pleroma.lol"

    assert [%{"name" => "moo", "url" => "http://mastodon.example.org/tags/moo"}] =
             rendered["tags"]
  end

  test "renders custom emojis from ActivityPub tag data" do
    activity = PleromaOldFixtures.json!("kroeg-array-less-emoji.json")

    assert {:ok, create} = Pipeline.ingest(activity, local: false)
    note = Objects.get_by_ap_id(create.object)

    rendered = StatusRenderer.render_status(note)

    assert [
             %{
               "shortcode" => "icon_e_smile",
               "url" => "https://puckipedia.com/forum/images/smilies/icon_e_smile.png",
               "static_url" => "https://puckipedia.com/forum/images/smilies/icon_e_smile.png",
               "visible_in_picker" => true
             }
           ] = rendered["emojis"]
  end
end
