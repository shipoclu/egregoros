defmodule PleromaReduxWeb.RelationshipsLiveTest do
  use PleromaReduxWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PleromaRedux.Activities.Follow
  alias PleromaRedux.Pipeline
  alias PleromaRedux.Users

  setup do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    assert {:ok, _follow} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    %{alice: alice, bob: bob}
  end

  test "followers page lists followers", %{conn: conn, bob: bob} do
    assert {:ok, view, _html} = live(conn, "/@#{bob.nickname}/followers")

    assert has_element?(view, "[data-role='relationships-title']", "Followers")
    assert has_element?(view, "[data-role='relationship-item']", "@alice")
  end

  test "following page lists followed accounts", %{conn: conn, alice: alice} do
    assert {:ok, view, _html} = live(conn, "/@#{alice.nickname}/following")

    assert has_element?(view, "[data-role='relationships-title']", "Following")
    assert has_element?(view, "[data-role='relationship-item']", "@bob")
  end
end

