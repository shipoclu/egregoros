defmodule Egregoros.ScheduledStatuses do
  import Ecto.Query, only: [from: 2, where: 3, order_by: 3, limit: 2]

  alias Ecto.Multi
  alias Egregoros.Media
  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.Repo
  alias Egregoros.ScheduledStatus
  alias Egregoros.User
  alias Egregoros.Users
  alias Egregoros.Workers.PublishScheduledStatus

  @max_note_chars 5000

  def create(%User{} = user, attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_attrs(user, attrs) do
      Multi.new()
      |> Multi.insert(
        :scheduled_status,
        ScheduledStatus.changeset(%ScheduledStatus{user_id: user.id}, attrs)
      )
      |> Multi.run(:job, fn _repo, %{scheduled_status: scheduled_status} ->
        args = %{"scheduled_status_id" => scheduled_status.id}

        args
        |> PublishScheduledStatus.new(
          queue: :federation_outgoing,
          scheduled_at: scheduled_status.scheduled_at
        )
        |> Oban.insert()
      end)
      |> Multi.update(:scheduled_status_with_job, fn %{
                                                       scheduled_status: scheduled_status,
                                                       job: job
                                                     } ->
        Ecto.Changeset.change(scheduled_status, oban_job_id: job.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{scheduled_status_with_job: scheduled_status}} -> {:ok, scheduled_status}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def create(%User{} = user, attrs) do
    create(user, Map.new(attrs))
  end

  def list_pending_for_user(%User{} = user, opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 20) |> normalize_limit()
    max_id = Keyword.get(opts, :max_id)
    since_id = Keyword.get(opts, :since_id)

    ScheduledStatus
    |> where_user(user)
    |> where_pending()
    |> maybe_where_max_id(max_id)
    |> maybe_where_since_id(since_id)
    |> order_by([s], desc: s.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_pending_for_user(%User{} = user, id) when is_binary(id) do
    id = String.trim(id)

    if flake_id?(id) do
      ScheduledStatus
      |> where_user(user)
      |> where_pending()
      |> where([s], s.id == ^id)
      |> Repo.one()
    end
  end

  def get_pending_for_user(_user, _id), do: nil

  def update_scheduled_at(%User{} = user, id, attrs) when is_map(attrs) do
    with %ScheduledStatus{} = scheduled_status <- get_pending_for_user(user, id) do
      scheduled_status
      |> ScheduledStatus.update_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, %ScheduledStatus{} = updated} ->
          _ = maybe_update_job_scheduled_at(updated)
          {:ok, updated}

        {:error, _} = error ->
          error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def delete(%User{} = user, id) do
    with %ScheduledStatus{} = scheduled_status <- get_pending_for_user(user, id) do
      _ = maybe_cancel_job(scheduled_status.oban_job_id)
      Repo.delete(scheduled_status)
    else
      _ -> {:error, :not_found}
    end
  end

  def publish(id) when is_binary(id) do
    id = String.trim(id)

    case if(flake_id?(id), do: Repo.get(ScheduledStatus, id)) do
      %ScheduledStatus{published_at: %DateTime{}} ->
        :ok

      %ScheduledStatus{} = scheduled_status ->
        do_publish(scheduled_status)

      _ ->
        :ok
    end
  end

  def publish(_id), do: :ok

  defp do_publish(%ScheduledStatus{} = scheduled_status) do
    with %User{} = user <- Users.get(scheduled_status.user_id) do
      params = Map.get(scheduled_status, :params, %{})

      text =
        params
        |> Map.get("text", "")
        |> to_string()

      visibility =
        params
        |> Map.get("visibility", "public")
        |> to_string()

      spoiler_text =
        params
        |> Map.get("spoiler_text")
        |> then(fn
          nil -> nil
          value -> to_string(value)
        end)

      sensitive = Map.get(params, "sensitive")
      language = Map.get(params, "language")
      media_ids = Map.get(params, "media_ids", [])
      in_reply_to_id = Map.get(params, "in_reply_to_id")
      poll = Map.get(params, "poll")

      with {:ok, attachments} <- Media.attachments_from_ids(user, media_ids),
           {:ok, in_reply_to} <- resolve_in_reply_to(in_reply_to_id, user),
           {:ok, create_object} <-
             (if is_map(poll) do
                Publish.post_poll(user, text, poll,
                  attachments: attachments,
                  in_reply_to: in_reply_to,
                  visibility: visibility,
                  spoiler_text: spoiler_text,
                  sensitive: sensitive,
                  language: language
                )
              else
                Publish.post_note(user, text,
                  attachments: attachments,
                  in_reply_to: in_reply_to,
                  visibility: visibility,
                  spoiler_text: spoiler_text,
                  sensitive: sensitive,
                  language: language
                )
              end) do
        Repo.update(Ecto.Changeset.change(scheduled_status, published_at: DateTime.utc_now()))
        {:ok, create_object}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp resolve_in_reply_to(nil, _user), do: {:ok, nil}
  defp resolve_in_reply_to("", _user), do: {:ok, nil}

  defp resolve_in_reply_to(in_reply_to_id, user)
       when is_binary(in_reply_to_id) and is_map(user) do
    case Objects.get(in_reply_to_id) do
      %{} = object ->
        if Objects.visible_to?(object, user) do
          {:ok, object.ap_id}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp resolve_in_reply_to(_in_reply_to_id, _user), do: {:error, :not_found}

  defp normalize_attrs(%User{} = user, attrs) when is_map(attrs) do
    scheduled_at = Map.get(attrs, :scheduled_at) || Map.get(attrs, "scheduled_at")
    params = Map.get(attrs, :params) || Map.get(attrs, "params") || %{}

    params =
      params
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()

    text =
      params
      |> Map.get("text", "")
      |> to_string()
      |> String.trim()

    media_ids = params |> Map.get("media_ids", []) |> List.wrap()

    cond do
      text == "" and media_ids == [] ->
        {:error, :empty}

      String.length(text) > @max_note_chars ->
        {:error, :too_long}

      true ->
        with {:ok, _attachments} <- Media.attachments_from_ids(user, media_ids),
             {:ok, _in_reply_to} <- resolve_in_reply_to(Map.get(params, "in_reply_to_id"), user) do
          {:ok, %{scheduled_at: scheduled_at, params: Map.put(params, "text", text)}}
        end
    end
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(40)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, _} -> normalize_limit(int)
      _ -> 20
    end
  end

  defp normalize_limit(_limit), do: 20

  defp where_user(query, %User{id: id}), do: from(s in query, where: s.user_id == ^id)
  defp where_user(query, _user), do: from(s in query, where: false)

  defp where_pending(query), do: from(s in query, where: is_nil(s.published_at))

  defp maybe_where_max_id(query, nil), do: query

  defp maybe_where_max_id(query, max_id) when is_binary(max_id) do
    max_id = String.trim(max_id)

    if flake_id?(max_id) do
      from(s in query, where: s.id < ^max_id)
    else
      query
    end
  end

  defp maybe_where_max_id(query, _max_id), do: query

  defp maybe_where_since_id(query, nil), do: query

  defp maybe_where_since_id(query, since_id) when is_binary(since_id) do
    since_id = String.trim(since_id)

    if flake_id?(since_id) do
      from(s in query, where: s.id > ^since_id)
    else
      query
    end
  end

  defp maybe_where_since_id(query, _since_id), do: query

  defp maybe_cancel_job(nil), do: :ok

  defp maybe_cancel_job(job_id) when is_integer(job_id) do
    case Oban.cancel_job(job_id) do
      :ok -> :ok
      {:ok, _job} -> :ok
      {:error, _} -> :ok
    end
  end

  defp maybe_cancel_job(_job_id), do: :ok

  defp maybe_update_job_scheduled_at(%ScheduledStatus{oban_job_id: nil}), do: :ok

  defp maybe_update_job_scheduled_at(%ScheduledStatus{
         oban_job_id: job_id,
         scheduled_at: %DateTime{} = scheduled_at
       })
       when is_integer(job_id) do
    _ =
      from(j in Oban.Job, where: j.id == ^job_id)
      |> Repo.update_all(set: [scheduled_at: scheduled_at])

    :ok
  end

  defp maybe_update_job_scheduled_at(_scheduled_status), do: :ok

  defp flake_id?(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" ->
        false

      byte_size(id) < 18 ->
        false

      true ->
        try do
          match?(<<_::128>>, FlakeId.from_string(id))
        rescue
          _ -> false
        end
    end
  end

  defp flake_id?(_id), do: false
end
