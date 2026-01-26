defmodule Egregoros.ScheduledStatusesTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.Repo
  alias Egregoros.ScheduledStatus
  alias Egregoros.ScheduledStatuses
  alias Egregoros.Users

  test "create/2 rejects empty text without attachments" do
    {:ok, user} = Users.create_local_user("sched_empty")

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)

    assert {:error, :empty} ==
             ScheduledStatuses.create(user, %{
               scheduled_at: scheduled_at,
               params: %{"text" => "  ", "media_ids" => []}
             })
  end

  test "create/2 rejects invalid media_ids" do
    {:ok, user} = Users.create_local_user("sched_invalid_media")

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)

    assert {:error, :invalid_media_id} ==
             ScheduledStatuses.create(user, %{
               scheduled_at: scheduled_at,
               params: %{"text" => "Hello", "media_ids" => ["not-an-int"]}
             })
  end

  test "list_pending_for_user/2 supports max_id and since_id" do
    {:ok, user} = Users.create_local_user("sched_filters")

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)

    {:ok, first} =
      ScheduledStatuses.create(user, %{
        scheduled_at: scheduled_at,
        params: %{"text" => "First"}
      })

    {:ok, second} =
      ScheduledStatuses.create(user, %{
        scheduled_at: scheduled_at,
        params: %{"text" => "Second"}
      })

    assert [^second] =
             ScheduledStatuses.list_pending_for_user(user, since_id: first.id, limit: 40)

    assert [^first] = ScheduledStatuses.list_pending_for_user(user, max_id: second.id, limit: 40)
  end

  test "create/2 accepts non-map attrs" do
    {:ok, user} = Users.create_local_user("sched_attrs_list")

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)

    assert {:ok, %ScheduledStatus{}} =
             ScheduledStatuses.create(user,
               scheduled_at: scheduled_at,
               params: %{"text" => "Hello"}
             )
  end

  test "list_pending_for_user/2 supports default opts and normalizes limit" do
    {:ok, user} = Users.create_local_user("sched_list_defaults")

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)

    {:ok, %ScheduledStatus{id: scheduled_status_id}} =
      ScheduledStatuses.create(user, %{scheduled_at: scheduled_at, params: %{"text" => "Hello"}})

    assert [%ScheduledStatus{id: ^scheduled_status_id}] =
             ScheduledStatuses.list_pending_for_user(user)

    assert length(ScheduledStatuses.list_pending_for_user(user, limit: "1")) == 1
    assert length(ScheduledStatuses.list_pending_for_user(user, limit: "nope")) == 1
    assert length(ScheduledStatuses.list_pending_for_user(user, limit: nil)) == 1
  end

  test "list_pending_for_user/2 ignores non-integer max_id and since_id" do
    {:ok, user} = Users.create_local_user("sched_list_ignores")

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)

    {:ok, %ScheduledStatus{id: scheduled_status_id}} =
      ScheduledStatuses.create(user, %{scheduled_at: scheduled_at, params: %{"text" => "Hello"}})

    assert [%ScheduledStatus{id: ^scheduled_status_id}] =
             ScheduledStatuses.list_pending_for_user(user, max_id: "nope", since_id: "nope")
  end

  test "get_pending_for_user/2 returns nil for invalid ids" do
    {:ok, user} = Users.create_local_user("sched_get_invalid")
    assert ScheduledStatuses.get_pending_for_user(user, "nope") == nil
  end

  test "get_pending_for_user/2 returns nil for unsupported id types" do
    {:ok, user} = Users.create_local_user("sched_get_weird")
    assert ScheduledStatuses.get_pending_for_user(user, %{}) == nil
  end

  test "update_scheduled_at/3 returns not_found when missing" do
    {:ok, user} = Users.create_local_user("sched_update_missing")

    assert {:error, :not_found} ==
             ScheduledStatuses.update_scheduled_at(user, 123_456_789, %{
               "scheduled_at" => DateTime.utc_now() |> DateTime.add(10 * 60, :second)
             })
  end

  test "update_scheduled_at/3 returns an error when validations fail" do
    {:ok, user} = Users.create_local_user("sched_update_invalid")

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)

    {:ok, %ScheduledStatus{id: scheduled_status_id}} =
      ScheduledStatuses.create(user, %{scheduled_at: scheduled_at, params: %{"text" => "Hello"}})

    assert {:error, %Ecto.Changeset{}} =
             ScheduledStatuses.update_scheduled_at(user, scheduled_status_id, %{
               "scheduled_at" => DateTime.utc_now() |> DateTime.add(60, :second)
             })
  end

  test "delete/2 cancels nil job ids" do
    {:ok, user} = Users.create_local_user("sched_delete_nil_job")

    scheduled_status =
      %ScheduledStatus{user_id: user.id}
      |> ScheduledStatus.changeset(%{
        scheduled_at: DateTime.utc_now() |> DateTime.add(10 * 60, :second),
        params: %{"text" => "Hello"}
      })
      |> Repo.insert!()

    scheduled_status_id = scheduled_status.id

    assert {:ok, %ScheduledStatus{id: ^scheduled_status_id}} =
             ScheduledStatuses.delete(user, scheduled_status_id)
  end

  test "update_scheduled_at/3 does not require an oban job id" do
    {:ok, user} = Users.create_local_user("sched_update_nil_job")

    scheduled_status =
      %ScheduledStatus{user_id: user.id, oban_job_id: nil}
      |> ScheduledStatus.changeset(%{
        scheduled_at: DateTime.utc_now() |> DateTime.add(10 * 60, :second),
        params: %{"text" => "Hello"}
      })
      |> Repo.insert!()

    new_scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(11 * 60, :second)

    assert {:ok, %ScheduledStatus{scheduled_at: ^new_scheduled_at}} =
             ScheduledStatuses.update_scheduled_at(user, scheduled_status.id, %{
               "scheduled_at" => new_scheduled_at
             })
  end

  test "delete/2 returns not_found when missing" do
    {:ok, user} = Users.create_local_user("sched_delete_missing")
    assert {:error, :not_found} = ScheduledStatuses.delete(user, 123_456_789)
  end

  test "publish/1 is a no-op for unknown or already published records" do
    assert ScheduledStatuses.publish("nope") == :ok
    assert ScheduledStatuses.publish(123_456_789) == :ok
    assert ScheduledStatuses.publish(%{}) == :ok

    {:ok, user} = Users.create_local_user("sched_published")

    scheduled_status =
      %ScheduledStatus{user_id: user.id}
      |> ScheduledStatus.changeset(%{
        scheduled_at: DateTime.utc_now() |> DateTime.add(10 * 60, :second),
        params: %{"text" => "Hello"},
        published_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert ScheduledStatuses.publish(scheduled_status.id) == :ok
  end

  test "create/2 validates in_reply_to_id values" do
    {:ok, user} = Users.create_local_user("sched_reply_to")

    {:ok, create_object} =
      Publish.post_note(user, "Parent", visibility: "public")

    parent = Objects.get_by_ap_id(create_object.object)
    assert is_map(parent)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)

    assert {:ok, %ScheduledStatus{}} =
             ScheduledStatuses.create(user, %{
               scheduled_at: scheduled_at,
               params: %{
                 "text" => "Reply by id as string",
                 "in_reply_to_id" => to_string(parent.id)
               }
             })

    assert {:ok, %ScheduledStatus{}} =
             ScheduledStatuses.create(user, %{
               scheduled_at: scheduled_at,
               params: %{"text" => "Reply by id", "in_reply_to_id" => parent.id}
             })

    assert {:ok, %ScheduledStatus{}} =
             ScheduledStatuses.create(user, %{
               scheduled_at: scheduled_at,
               params: %{"text" => "Reply empty", "in_reply_to_id" => ""}
             })

    assert {:error, :not_found} =
             ScheduledStatuses.create(user, %{
               scheduled_at: scheduled_at,
               params: %{"text" => "Reply missing", "in_reply_to_id" => "999999999"}
             })

    assert {:error, :not_found} =
             ScheduledStatuses.create(user, %{
               scheduled_at: scheduled_at,
               params: %{"text" => "Reply missing int", "in_reply_to_id" => 123_456_789}
             })

    assert {:error, :not_found} =
             ScheduledStatuses.create(user, %{
               scheduled_at: scheduled_at,
               params: %{"text" => "Reply weird", "in_reply_to_id" => %{}}
             })
  end
end
