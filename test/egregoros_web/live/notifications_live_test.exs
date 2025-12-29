defmodule EgregorosWeb.NotificationsLiveTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Follow
  alias Egregoros.Notifications
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  setup do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, actor} = Users.create_local_user("bob")

    %{user: user, actor: actor}
  end

  test "renders notifications for a signed-in user", %{conn: conn, user: user, actor: actor} do
    assert {:ok, _} = Pipeline.ingest(Follow.build(actor, user), local: true)
    [notification] = Notifications.list_for_user(user, limit: 1)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/notifications")

    assert has_element?(view, "#notification-#{notification.id}")
    assert has_element?(view, "[data-role='notification'][data-type='Follow']")
  end

  test "notifications can load more items", %{conn: conn, user: user, actor: actor} do
    for idx <- 1..25 do
      assert {:ok, _} =
               Pipeline.ingest(
                 %{
                   "id" => "http://localhost:4000/activities/follow/#{idx}",
                   "type" => "Follow",
                   "actor" => actor.ap_id,
                   "object" => user.ap_id
                 },
                 local: true
               )
    end

    notifications = Notifications.list_for_user(user, limit: 25)
    oldest = List.last(notifications)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/notifications")

    refute has_element?(view, "#notification-#{oldest.id}")

    view
    |> element("button[data-role='notifications-load-more']")
    |> render_click()

    assert has_element?(view, "#notification-#{oldest.id}")
  end

  test "streams new notifications into the list", %{conn: conn, user: user, actor: actor} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/notifications")

    assert {:ok, activity} = Pipeline.ingest(Follow.build(actor, user), local: true)

    send(view.pid, {:notification_created, activity})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#notification-#{activity.id}")
  end

  test "notifications can be filtered without losing the list", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/notifications")

    assert has_element?(view, "#notifications-list[data-filter='all']")

    view
    |> element("button[data-role='notifications-filter'][data-filter='follows']")
    |> render_click()

    assert has_element?(view, "#notifications-list[data-filter='follows']")
  end

  test "follow requests can be accepted from the notifications screen", %{
    conn: conn,
    user: user,
    actor: actor
  } do
    {:ok, user} = Users.update_profile(user, %{locked: true})

    assert {:ok, follow_object} = Pipeline.ingest(Follow.build(actor, user), local: true)

    assert %{id: relationship_id, activity_ap_id: activity_ap_id} =
             Relationships.get_by_type_actor_object("FollowRequest", actor.ap_id, user.ap_id)

    assert activity_ap_id == follow_object.ap_id

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/notifications")

    view
    |> element("button[data-role='notifications-filter'][data-filter='requests']")
    |> render_click()

    assert has_element?(view, "#follow-request-#{relationship_id}")

    view
    |> element("button[data-role='follow-request-accept'][phx-value-id='#{relationship_id}']")
    |> render_click()

    assert Relationships.get_by_type_actor_object("FollowRequest", actor.ap_id, user.ap_id) == nil
    assert Relationships.get_by_type_actor_object("Follow", actor.ap_id, user.ap_id)
  end
end
