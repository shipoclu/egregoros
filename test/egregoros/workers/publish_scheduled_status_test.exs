defmodule Egregoros.Workers.PublishScheduledStatusTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Repo
  alias Egregoros.ScheduledStatus
  alias Egregoros.Users
  alias Egregoros.Workers.PublishScheduledStatus

  test "perform/1 publishes when scheduled_status_id is an integer" do
    assert :ok =
             PublishScheduledStatus.perform(%Oban.Job{
               args: %{"scheduled_status_id" => 123_456_789}
             })
  end

  test "perform/1 returns :ok when the scheduled status is published" do
    {:ok, user} = Users.create_local_user("scheduler_worker_ok")

    scheduled_status =
      %ScheduledStatus{user_id: user.id}
      |> ScheduledStatus.changeset(%{
        scheduled_at: DateTime.utc_now() |> DateTime.add(10 * 60, :second),
        params: %{"text" => "Hello worker"}
      })
      |> Repo.insert!()

    assert :ok =
             PublishScheduledStatus.perform(%Oban.Job{
               args: %{"scheduled_status_id" => scheduled_status.id}
             })
  end

  test "perform/1 discards invalid args" do
    assert {:discard, :invalid_args} =
             PublishScheduledStatus.perform(%Oban.Job{
               args: %{"nope" => 1}
             })
  end

  test "perform/1 returns an error when publishing fails" do
    {:ok, user} = Users.create_local_user("scheduler_worker_error")

    scheduled_status =
      %ScheduledStatus{user_id: user.id}
      |> ScheduledStatus.changeset(%{
        scheduled_at: DateTime.utc_now() |> DateTime.add(10 * 60, :second),
        params: %{"text" => "Hello", "media_ids" => ["not-an-int"]}
      })
      |> Repo.insert!()

    assert {:error, :invalid_media_id} =
             PublishScheduledStatus.perform(%Oban.Job{
               args: %{"scheduled_status_id" => scheduled_status.id}
             })
  end

  test "perform/1 accepts scheduled_status_id as a string" do
    assert :ok =
             PublishScheduledStatus.perform(%Oban.Job{
               args: %{"scheduled_status_id" => "999999999"}
             })
  end

  test "perform/1 returns an error when publishing fails for string id" do
    {:ok, user} = Users.create_local_user("scheduler_worker_error_binary")

    scheduled_status =
      %ScheduledStatus{user_id: user.id}
      |> ScheduledStatus.changeset(%{
        scheduled_at: DateTime.utc_now() |> DateTime.add(10 * 60, :second),
        params: %{"text" => "Hello", "media_ids" => ["not-an-int"]}
      })
      |> Repo.insert!()

    assert {:error, :invalid_media_id} =
             PublishScheduledStatus.perform(%Oban.Job{
               args: %{"scheduled_status_id" => Integer.to_string(scheduled_status.id)}
             })
  end
end
