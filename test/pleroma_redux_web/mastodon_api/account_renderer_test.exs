defmodule PleromaReduxWeb.MastodonAPI.AccountRendererTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Users
  alias PleromaReduxWeb.MastodonAPI.AccountRenderer

  test "escapes local bios as text" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, user} = Users.update_profile(user, %{bio: "<script>alert(1)</script>"})

    rendered = AccountRenderer.render_account(user)

    assert rendered["note"] =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute rendered["note"] =~ "<script"
  end

  test "sanitizes remote bios as html" do
    {:ok, user} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false,
        bio: "<p>ok</p><script>alert(1)</script>"
      })

    rendered = AccountRenderer.render_account(user)

    assert rendered["note"] =~ "<p>ok</p>"
    refute rendered["note"] =~ "<script"
  end
end

