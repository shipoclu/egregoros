defmodule PleromaReduxWeb.MastodonAPI.StatusRendererTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Objects
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
end

