defmodule PleromaRedux.Auth.DefaultTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Auth.Default
  alias PleromaRedux.Users

  test "current_user returns a local user" do
    assert {:ok, user} = Default.current_user(%{})
    assert user.local
    assert user.nickname == "local"

    assert Users.get_by_nickname("local").id == user.id
  end
end
