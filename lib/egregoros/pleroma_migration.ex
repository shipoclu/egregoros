defmodule Egregoros.PleromaMigration do
  @moduledoc false

  alias Egregoros.Activities.Helpers
  alias Egregoros.Object
  alias Egregoros.PleromaMigration.Source
  alias Egregoros.Repo
  alias Egregoros.User

  @insert_all_batch_size 1_000

  def run(opts \\ []) when is_list(opts) do
    with {:ok, users} <- Source.list_users(opts),
         {:ok, statuses} <- Source.list_statuses(opts) do
      %{
        users: import_users(users),
        statuses: import_statuses(statuses)
      }
    end
  end

  def import_users(rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(rows, fn row ->
        row
        |> Map.put_new(:id, FlakeId.get())
        |> Map.put_new(:inserted_at, now)
        |> Map.put_new(:updated_at, now)
      end)

    inserted = insert_all_batched(User, rows, on_conflict: :nothing, conflict_target: [:ap_id])

    %{inserted: inserted, attempted: length(rows)}
  end

  def import_users(_rows), do: %{inserted: 0, attempted: 0}

  def import_statuses(rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {status_rows, activity_rows} =
      Enum.reduce(rows, {[], []}, fn row, {status_rows, activity_rows} ->
        activity = Map.get(row, :activity) || Map.get(row, "activity")
        activity_id = Map.get(row, :activity_id) || Map.get(row, "activity_id")
        inserted_at = row |> Map.get(:inserted_at, now) |> force_utc_datetime_usec()
        updated_at = row |> Map.get(:updated_at, inserted_at) |> force_utc_datetime_usec()
        local = Map.get(row, :local, true) == true

        case activity do
          %{"type" => "Create"} ->
            object = Map.get(row, :object) || Map.get(row, "object")

            case build_create_status_rows(
                   activity_id,
                   activity,
                   object,
                   inserted_at,
                   updated_at,
                   local
                 ) do
              {:ok, status_row, create_row} ->
                activity_rows =
                  case create_row do
                    %{} = create_row -> [create_row | activity_rows]
                    _ -> activity_rows
                  end

                {[status_row | status_rows], activity_rows}

              _ ->
                {status_rows, activity_rows}
            end

          %{"type" => "Announce"} ->
            case build_announce_status_row(activity_id, activity, inserted_at, updated_at, local) do
              {:ok, status_row} ->
                {[status_row | status_rows], activity_rows}

              _ ->
                {status_rows, activity_rows}
            end

          _ ->
            {status_rows, activity_rows}
        end
      end)

    inserted_statuses = insert_objects(now, status_rows)
    inserted_activities = insert_objects(now, activity_rows)

    %{inserted: inserted_statuses + inserted_activities, attempted: length(rows)}
  end

  def import_statuses(_rows), do: %{inserted: 0, attempted: 0}

  defp insert_objects(now, rows) when is_list(rows) do
    rows =
      Enum.map(rows, fn row ->
        row
        |> Map.put_new(:id, FlakeId.get())
        |> Map.put_new(:inserted_at, now)
        |> Map.put_new(:updated_at, now)
      end)

    insert_all_batched(Object, rows, on_conflict: :nothing, conflict_target: [:ap_id])
  end

  defp insert_all_batched(schema, rows, opts) when is_list(rows) and is_list(opts) do
    rows
    |> Enum.chunk_every(@insert_all_batch_size)
    |> Enum.reduce(0, fn batch, inserted ->
      {count, _} = Repo.insert_all(schema, batch, opts)
      inserted + count
    end)
  end

  defp build_create_status_rows(activity_id, activity, object, inserted_at, updated_at, local)
       when is_map(activity) and is_map(object) do
    with status_id when is_binary(status_id) and status_id != "" <-
           normalize_flake_id(activity_id),
         ap_id when is_binary(ap_id) and ap_id != "" <- Map.get(object, "id"),
         object_type when is_binary(object_type) and object_type != "" <- Map.get(object, "type") do
      actor =
        case object do
          %{"actor" => actor} when is_binary(actor) and actor != "" -> actor
          %{"attributedTo" => actor} when is_binary(actor) and actor != "" -> actor
          _ -> Map.get(activity, "actor")
        end

      published =
        (Map.get(object, "published") || Map.get(activity, "published"))
        |> Helpers.parse_datetime()
        |> force_utc_datetime_usec()

      status_row = %{
        id: status_id,
        ap_id: ap_id,
        type: object_type,
        actor: actor,
        object: nil,
        data: object,
        internal: %{},
        published: published,
        local: local,
        in_reply_to_ap_id: in_reply_to_ap_id(object_type, object),
        has_media: has_media?(object_type, object),
        inserted_at: inserted_at,
        updated_at: updated_at
      }

      create_row =
        case Map.get(activity, "id") do
          create_ap_id when is_binary(create_ap_id) and create_ap_id != "" ->
            %{
              id: FlakeId.get(),
              ap_id: create_ap_id,
              type: "Create",
              actor: Map.get(activity, "actor"),
              object: ap_id,
              data: activity,
              internal: %{},
              published:
                activity
                |> Map.get("published")
                |> Helpers.parse_datetime()
                |> force_utc_datetime_usec(),
              local: local,
              inserted_at: inserted_at,
              updated_at: updated_at
            }

          _ ->
            nil
        end

      {:ok, status_row, create_row}
    else
      _ -> :error
    end
  end

  defp build_create_status_rows(
         _activity_id,
         _activity,
         _object,
         _inserted_at,
         _updated_at,
         _local
       ),
       do: :error

  defp build_announce_status_row(activity_id, activity, inserted_at, updated_at, local)
       when is_map(activity) do
    with status_id when is_binary(status_id) and status_id != "" <-
           normalize_flake_id(activity_id),
         ap_id when is_binary(ap_id) and ap_id != "" <- Map.get(activity, "id"),
         actor when is_binary(actor) and actor != "" <- Map.get(activity, "actor"),
         object when is_binary(object) and object != "" <- Map.get(activity, "object") do
      status_row = %{
        id: status_id,
        ap_id: ap_id,
        type: "Announce",
        actor: actor,
        object: object,
        data: activity,
        internal: %{},
        published:
          activity
          |> Map.get("published")
          |> Helpers.parse_datetime()
          |> force_utc_datetime_usec(),
        local: local,
        inserted_at: inserted_at,
        updated_at: updated_at
      }

      {:ok, status_row}
    else
      _ -> :error
    end
  end

  defp build_announce_status_row(_activity_id, _activity, _inserted_at, _updated_at, _local),
    do: :error

  defp normalize_flake_id(<<_::binary-size(16)>> = id), do: FlakeId.to_string(id)
  defp normalize_flake_id(id) when is_binary(id), do: String.trim(id)
  defp normalize_flake_id(_id), do: nil

  defp force_utc_datetime_usec(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> force_utc_datetime_usec()
  end

  defp force_utc_datetime_usec(%DateTime{microsecond: {value, _precision}} = datetime) do
    %{datetime | microsecond: {value, 6}}
  end

  defp force_utc_datetime_usec(nil), do: nil

  defp in_reply_to_ap_id("Note", %{} = object) do
    case Map.get(object, "inReplyTo") do
      in_reply_to when is_binary(in_reply_to) and in_reply_to != "" -> in_reply_to
      %{"id" => in_reply_to} when is_binary(in_reply_to) and in_reply_to != "" -> in_reply_to
      _ -> nil
    end
  end

  defp in_reply_to_ap_id(_type, _object), do: nil

  defp has_media?("Note", %{} = object) do
    case Map.get(object, "attachment") do
      attachments when is_list(attachments) -> Enum.any?(attachments, &is_map/1)
      _ -> false
    end
  end

  defp has_media?(_type, _object), do: false
end
