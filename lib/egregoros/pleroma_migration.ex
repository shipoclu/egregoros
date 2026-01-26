defmodule Egregoros.PleromaMigration do
  @moduledoc false

  alias Egregoros.Repo
  alias Egregoros.User

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
end
