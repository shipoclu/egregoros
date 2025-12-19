defmodule PleromaRedux.Activities.EmojiReact do
  alias PleromaRedux.Objects

  def type, do: "EmojiReact"

  def normalize(%{"type" => "EmojiReact"} = activity) do
    trim_content(activity)
  end

  def normalize(_), do: nil

  def validate(
        %{
          "id" => id,
          "type" => "EmojiReact",
          "actor" => actor,
          "object" => object,
          "content" => content
        } = activity
      )
      when is_binary(id) and is_binary(actor) and is_binary(object) and is_binary(content) and
             content != "" do
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

  defp trim_content(%{"content" => content} = activity) when is_binary(content) do
    Map.put(activity, "content", String.trim(content))
  end

  defp trim_content(activity), do: activity

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
end
