defmodule EgregorosWeb.MastodonAPI.ScheduledStatusesControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Repo
  alias Egregoros.ScheduledStatus
  alias Egregoros.Users
  alias Egregoros.Workers.PublishScheduledStatus

  test "POST /api/v1/statuses with scheduled_at creates a scheduled status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("scheduler")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Hello future",
        "scheduled_at" => scheduled_at
      })

    response = json_response(conn, 200)
    assert is_binary(response["id"])
    assert response["scheduled_at"] == scheduled_at
    assert response["params"]["text"] == "Hello future"

    assert Objects.list_notes() == []

    scheduled_status_id = response["id"]

    assert_enqueued(
      worker: PublishScheduledStatus,
      queue: "federation_outgoing",
      args: %{"scheduled_status_id" => scheduled_status_id}
    )
  end

  test "GET /api/v1/scheduled_statuses lists pending scheduled statuses", %{conn: conn} do
    {:ok, user} = Users.create_local_user("scheduler_list")

    Egregoros.Auth.Mock
    |> expect(:current_user, 2, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn = post(conn, "/api/v1/statuses", %{"status" => "Hello", "scheduled_at" => scheduled_at})
    created = json_response(conn, 200)

    list_conn = get(conn, "/api/v1/scheduled_statuses")
    response = json_response(list_conn, 200)

    assert [%{"id" => id, "scheduled_at" => ^scheduled_at}] = response
    assert id == created["id"]
  end

  test "scheduled status publishing creates the note and removes it from the list", %{conn: conn} do
    {:ok, user} = Users.create_local_user("scheduler_publish")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn =
      post(conn, "/api/v1/statuses", %{"status" => "Hello future", "scheduled_at" => scheduled_at})

    created = json_response(conn, 200)
    scheduled_status_id = created["id"]

    assert :ok =
             perform_job(PublishScheduledStatus, %{
               "scheduled_status_id" => scheduled_status_id
             })

    [note] = Objects.list_notes()
    assert note.data["content"] == "<p>Hello future</p>"

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    list_conn = get(build_conn(), "/api/v1/scheduled_statuses")
    assert json_response(list_conn, 200) == []
  end

  test "scheduled statuses include media_attachments when media_ids are present", %{conn: conn} do
    {:ok, user} = Users.create_local_user("scheduler_media")

    {:ok, media_object} =
      Objects.create_object(%{
        ap_id: "https://example.com/objects/scheduled-media-1",
        type: "Image",
        actor: user.ap_id,
        local: true,
        published: DateTime.utc_now(),
        data: %{
          "id" => "https://example.com/objects/scheduled-media-1",
          "type" => "Image",
          "mediaType" => "image/png",
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => "image/png",
              "href" => "https://example.com/uploads/scheduled-media-1.png"
            }
          ],
          "name" => "description"
        }
      })

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Hello with media",
        "scheduled_at" => scheduled_at,
        "media_ids" => [media_object.id]
      })

    response = json_response(conn, 200)
    assert response["params"]["media_ids"] == [media_object.id]

    assert [
             %{
               "id" => attachment_id,
               "type" => "image",
               "url" => "https://example.com/uploads/scheduled-media-1.png",
               "preview_url" => "https://example.com/uploads/scheduled-media-1.png",
               "description" => "description"
             }
           ] = response["media_attachments"]

    assert attachment_id == media_object.id
  end

  test "scheduled statuses render icon preview_url and normalize sensitive", %{conn: conn} do
    {:ok, user} = Users.create_local_user("scheduler_media_preview")

    {:ok, media_object} =
      Objects.create_object(%{
        ap_id: "https://example.com/objects/scheduled-media-preview-1",
        type: "Image",
        actor: user.ap_id,
        local: true,
        published: DateTime.utc_now(),
        data: %{
          "id" => "https://example.com/objects/scheduled-media-preview-1",
          "type" => "Image",
          "mediaType" => "image/png",
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => "image/png",
              "href" => "https://example.com/uploads/scheduled-media-preview-1.png"
            }
          ],
          "icon" => %{
            "url" => [
              %{
                "href" => "https://example.com/uploads/scheduled-media-preview-1-thumb.png"
              }
            ]
          },
          "meta" => %{"original" => %{"width" => 1, "height" => 1}},
          "blurhash" => "hash",
          "name" => "description"
        }
      })

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Hello with preview",
        "scheduled_at" => scheduled_at,
        "media_ids" => [media_object.id],
        "sensitive" => "true"
      })

    response = json_response(conn, 200)
    assert response["params"]["sensitive"] == true
    assert response["params"]["media_ids"] == [media_object.id]

    assert [%{"preview_url" => "https://example.com/uploads/scheduled-media-preview-1-thumb.png"}] =
             response["media_attachments"]
  end

  test "scheduled statuses render video attachments when mediaType is on the url entry", %{
    conn: conn
  } do
    {:ok, user} = Users.create_local_user("scheduler_video")

    {:ok, media_object} =
      Objects.create_object(%{
        ap_id: "https://example.com/objects/scheduled-video-1",
        type: "Document",
        actor: user.ap_id,
        local: true,
        published: DateTime.utc_now(),
        data: %{
          "id" => "https://example.com/objects/scheduled-video-1",
          "type" => "Document",
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => "video/mp4",
              "href" => "https://example.com/uploads/scheduled-video-1.mp4"
            }
          ]
        }
      })

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Hello video",
        "scheduled_at" => scheduled_at,
        "media_ids" => [media_object.id]
      })

    response = json_response(conn, 200)

    assert [%{"type" => "video", "url" => "https://example.com/uploads/scheduled-video-1.mp4"}] =
             response["media_attachments"]
  end

  test "PUT /api/v1/scheduled_statuses/:id updates scheduled_at", %{conn: conn} do
    {:ok, user} = Users.create_local_user("scheduler_update")

    Egregoros.Auth.Mock
    |> expect(:current_user, 2, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn = post(conn, "/api/v1/statuses", %{"status" => "Hello", "scheduled_at" => scheduled_at})
    created = json_response(conn, 200)
    scheduled_status_id = created["id"]

    new_scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(15 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn =
      put(conn, "/api/v1/scheduled_statuses/#{scheduled_status_id}", %{
        "scheduled_at" => new_scheduled_at
      })

    updated = json_response(conn, 200)
    assert updated["scheduled_at"] == new_scheduled_at

    %ScheduledStatus{oban_job_id: job_id} = Repo.get!(ScheduledStatus, scheduled_status_id)
    oban_job = Repo.get!(Oban.Job, job_id)

    assert DateTime.to_iso8601(DateTime.truncate(oban_job.scheduled_at, :second)) ==
             new_scheduled_at
  end

  test "DELETE /api/v1/scheduled_statuses/:id cancels the scheduled status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("scheduler_delete")

    Egregoros.Auth.Mock
    |> expect(:current_user, 3, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(10 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn = post(conn, "/api/v1/statuses", %{"status" => "Hello", "scheduled_at" => scheduled_at})
    created = json_response(conn, 200)
    scheduled_status_id = created["id"]

    conn = delete(conn, "/api/v1/scheduled_statuses/#{scheduled_status_id}")
    assert json_response(conn, 200)["id"] == scheduled_status_id

    list_conn = get(conn, "/api/v1/scheduled_statuses")
    assert json_response(list_conn, 200) == []
  end

  test "POST /api/v1/statuses rejects scheduled_at that is too soon", %{conn: conn} do
    {:ok, user} = Users.create_local_user("scheduler_too_soon")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conn = post(conn, "/api/v1/statuses", %{"status" => "Hello", "scheduled_at" => scheduled_at})
    assert response(conn, 422)
  end
end
