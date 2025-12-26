defmodule Egregoros.Markers do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.Marker
  alias Egregoros.Repo
  alias Egregoros.User

  def list_for_user(%User{} = user, timelines) when is_list(timelines) do
    timelines =
      timelines
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if timelines == [] do
      []
    else
      from(m in Marker,
        where: m.user_id == ^user.id and m.timeline in ^timelines
      )
      |> Repo.all()
    end
  end

  def list_for_user(_user, _timelines), do: []

  def upsert_many(%User{} = user, updates) when is_list(updates) do
    updates
    |> Enum.reduce_while({:ok, []}, fn {timeline, last_read_id}, {:ok, acc} ->
      case upsert(user, timeline, last_read_id) do
        {:ok, %Marker{} = marker} -> {:cont, {:ok, [marker | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, markers} -> {:ok, Enum.reverse(markers)}
      {:error, _} = error -> error
    end
  end

  def upsert_many(_user, _updates), do: {:ok, []}

  def upsert(%User{} = user, timeline, last_read_id)
      when is_binary(timeline) and is_binary(last_read_id) do
    attrs = %{user_id: user.id, timeline: timeline, last_read_id: last_read_id, version: 1}

    %Marker{}
    |> Marker.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:last_read_id, :updated_at]},
      conflict_target: [:user_id, :timeline]
    )
  end

  def upsert(_user, _timeline, _last_read_id), do: {:error, :invalid}
end
