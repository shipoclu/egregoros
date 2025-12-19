defmodule PleromaRedux.Activities.Like do
  alias PleromaRedux.Objects

  def type, do: "Like"

  def normalize(%{"type" => "Like"} = activity), do: activity
  def normalize(_), do: nil

  def validate(%{"id" => id, "type" => "Like", "actor" => actor, "object" => object} = activity)
      when is_binary(id) and is_binary(actor) and is_binary(object) do
    {:ok, activity}
  end

  def validate(_), do: {:error, :invalid}

  def ingest(activity, opts) do
    activity
    |> to_object_attrs(opts)
    |> Objects.upsert_object()
  end

  def side_effects(_object, _opts), do: :ok

  defp to_object_attrs(activity, opts) do
    %{
      ap_id: activity["id"],
      type: activity["type"],
      actor: activity["actor"],
      object: activity["object"],
      data: activity,
      published: parse_datetime(activity["published"]),
      local: Keyword.get(opts, :local, true)
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
end
