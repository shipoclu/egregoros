defmodule Egregoros.PleromaMigration do
  @moduledoc false

  alias Egregoros.Activities.Helpers
  alias Egregoros.Object
  alias Egregoros.PleromaMigration.Source
  alias Egregoros.Repo
  alias Egregoros.User

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

    inserted =
      case rows do
        [] ->
          0

        rows ->
          {count, _} =
            Repo.insert_all(User, rows, on_conflict: :nothing, conflict_target: [:ap_id])

          count
      end

    %{inserted: inserted, attempted: length(rows)}
  end

  def import_users(_rows), do: %{inserted: 0, attempted: 0}

  def import_statuses(rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {status_rows, activity_rows} =
      Enum.reduce(rows, {[], []}, fn row, {status_rows, activity_rows} ->
        activity = Map.get(row, :activity) || Map.get(row, "activity")
        activity_id = Map.get(row, :activity_id) || Map.get(row, "activity_id")
        inserted_at = Map.get(row, :inserted_at, now)
        updated_at = Map.get(row, :updated_at, inserted_at)
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
                {[status_row | status_rows], [create_row | activity_rows]}

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

    case rows do
      [] ->
        0

      rows ->
        {count, _} =
          Repo.insert_all(Object, rows, on_conflict: :nothing, conflict_target: [:ap_id])

        count
    end
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
        Helpers.parse_datetime(Map.get(object, "published") || Map.get(activity, "published"))

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

      create_row = %{
        id: FlakeId.get(),
        ap_id: Map.get(activity, "id"),
        type: "Create",
        actor: Map.get(activity, "actor"),
        object: ap_id,
        data: activity,
        internal: %{},
        published: Helpers.parse_datetime(Map.get(activity, "published")),
        local: local,
        inserted_at: inserted_at,
        updated_at: updated_at
      }

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
        published: Helpers.parse_datetime(Map.get(activity, "published")),
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
