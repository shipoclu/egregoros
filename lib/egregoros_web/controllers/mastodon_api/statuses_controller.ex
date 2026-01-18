defmodule EgregorosWeb.MastodonAPI.StatusesController do
  use EgregorosWeb, :controller

  alias Egregoros.Activities.Announce
  alias Egregoros.Activities.Delete
  alias Egregoros.Activities.Like
  alias Egregoros.Activities.Update
  alias Egregoros.Activities.Undo
  alias Egregoros.HTML
  alias Egregoros.Mentions
  alias Egregoros.Media
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Relationships
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.AccountRenderer
  alias EgregorosWeb.MastodonAPI.Fallback
  alias EgregorosWeb.MastodonAPI.StatusRenderer

  def create(conn, %{"status" => status} = params) do
    status = String.trim(status || "")
    media_ids = Map.get(params, "media_ids", [])
    in_reply_to_id = Map.get(params, "in_reply_to_id")
    visibility = Map.get(params, "visibility", "public")
    spoiler_text = Map.get(params, "spoiler_text")
    sensitive = Map.get(params, "sensitive")
    language = Map.get(params, "language")

    user = conn.assigns.current_user

    with {:ok, attachments} <- Media.attachments_from_ids(user, media_ids),
         {:ok, in_reply_to} <- resolve_in_reply_to(in_reply_to_id, user),
         {:ok, create_object} <-
           Publish.post_note(user, status,
             attachments: attachments,
             in_reply_to: in_reply_to,
             visibility: visibility,
             spoiler_text: spoiler_text,
             sensitive: sensitive,
             language: language
           ),
         %{} = object <- Objects.get_by_ap_id(create_object.object) do
      json(conn, StatusRenderer.render_status(object, user))
    else
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def create(conn, _params) do
    send_resp(conn, 422, "Unprocessable Entity")
  end

  def update(conn, %{"id" => id} = params) do
    status = params |> Map.get("status", "") |> to_string() |> String.trim()
    spoiler_text = Map.get(params, "spoiler_text")
    sensitive = Map.get(params, "sensitive")
    language = Map.get(params, "language")
    user = conn.assigns.current_user

    cond do
      status == "" ->
        send_resp(conn, 422, "Unprocessable Entity")

      true ->
        with %{} = object <- Objects.get(id),
             true <-
               object.type == "Note" and object.actor == user.ap_id and object.local == true,
             %{} = note <-
               build_updated_note(object, user, status, spoiler_text, sensitive, language),
             update <- Update.build(user, note),
             {:ok, _} <- Pipeline.ingest(update, local: true),
             %{} = object <- Objects.get(id) do
          json(conn, StatusRenderer.render_status(object, user))
        else
          nil -> send_resp(conn, 404, "Not Found")
          false -> send_resp(conn, 403, "Forbidden")
          {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
          _ -> send_resp(conn, 422, "Unprocessable Entity")
        end
    end
  end

  def update(conn, _params) do
    send_resp(conn, 422, "Unprocessable Entity")
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

  defp resolve_in_reply_to(in_reply_to_id, user)
       when is_integer(in_reply_to_id) and is_map(user) do
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

  defp build_updated_note(
         %{data: %{} = data, ap_id: ap_id},
         user,
         status,
         spoiler_text,
         sensitive,
         language
       )
       when is_map(user) and is_binary(ap_id) and is_binary(status) do
    tags = Map.get(data, "tag", [])
    mention_hrefs = mention_hrefs_from_tags(tags)

    content_html =
      HTML.to_safe_html(status,
        format: :text,
        mention_hrefs: mention_hrefs
      )

    data
    |> Map.put("id", ap_id)
    |> Map.put("type", "Note")
    |> Map.put("attributedTo", user.ap_id)
    |> Map.put("content", content_html)
    |> Map.put("source", %{"content" => status, "mediaType" => "text/plain"})
    |> Map.put("updated", DateTime.utc_now() |> DateTime.to_iso8601())
    |> maybe_put_summary(spoiler_text)
    |> maybe_put_sensitive(sensitive)
    |> maybe_put_language(language)
  end

  defp build_updated_note(_object, _user, _status, _spoiler_text, _sensitive, _language), do: nil

  defp mention_hrefs_from_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn
      %{"type" => "Mention", "href" => href, "name" => name}, acc
      when is_binary(href) and href != "" and is_binary(name) and name != "" ->
        handle =
          name
          |> String.trim()
          |> String.trim_leading("@")

        case Mentions.parse(handle) do
          {:ok, nickname, host} -> Map.put(acc, {nickname, host}, href)
          :error -> acc
        end

      _other, acc ->
        acc
    end)
  end

  defp maybe_put_summary(%{} = note, value) when is_binary(value) do
    summary = String.trim(value)
    if summary == "", do: note, else: Map.put(note, "summary", summary)
  end

  defp maybe_put_summary(note, _value), do: note

  defp maybe_put_sensitive(%{} = note, value) do
    case value do
      true -> Map.put(note, "sensitive", true)
      "true" -> Map.put(note, "sensitive", true)
      false -> Map.put(note, "sensitive", false)
      "false" -> Map.put(note, "sensitive", false)
      _ -> note
    end
  end

  defp maybe_put_sensitive(note, _value), do: note

  defp maybe_put_language(%{} = note, value) when is_binary(value) do
    language = String.trim(value)
    if language == "", do: note, else: Map.put(note, "language", language)
  end

  defp maybe_put_language(note, _value), do: note

  def show(conn, %{"id" => id}) do
    current_user = conn.assigns[:current_user]

    case Objects.get(id) do
      nil ->
        send_resp(conn, 404, "Not Found")

      object ->
        if Objects.visible_to?(object, current_user) do
          json(conn, StatusRenderer.render_status(object, current_user))
        else
          send_resp(conn, 404, "Not Found")
        end
    end
  end

  def source(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Objects.get(id) do
      %{} = object ->
        if object.type == "Note" and object.local == true and object.actor == current_user.ap_id do
          json(conn, %{
            "id" => Integer.to_string(object.id),
            "text" => source_text(object),
            "spoiler_text" => source_spoiler_text(object)
          })
        else
          send_resp(conn, 404, "Not Found")
        end

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  def context(conn, %{"id" => id}) do
    current_user = conn.assigns[:current_user]

    case Objects.get(id) do
      nil ->
        send_resp(conn, 404, "Not Found")

      object ->
        if Objects.visible_to?(object, current_user) do
          ancestors =
            object
            |> Objects.thread_ancestors()
            |> Enum.filter(&Objects.visible_to?(&1, current_user))

          descendants =
            object
            |> Objects.thread_descendants()
            |> Enum.filter(&Objects.visible_to?(&1, current_user))

          json(conn, %{
            "ancestors" => StatusRenderer.render_statuses(ancestors, current_user),
            "descendants" => StatusRenderer.render_statuses(descendants, current_user)
          })
        else
          send_resp(conn, 404, "Not Found")
        end
    end
  end

  defp source_text(%{data: %{"source" => %{"content" => content}}}) when is_binary(content),
    do: content

  defp source_text(%{data: %{"content" => content}}) when is_binary(content), do: content

  defp source_text(_object), do: ""

  defp source_spoiler_text(%{data: %{"summary" => summary}}) when is_binary(summary), do: summary
  defp source_spoiler_text(_object), do: ""

  def favourited_by(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Objects.get(id) do
      nil ->
        send_resp(conn, 404, "Not Found")

      object ->
        if Objects.visible_to?(object, current_user) do
          Relationships.list_by_type_object("Like", object.ap_id)
          |> Enum.map(& &1.actor)
          |> render_accounts_by_ap_ids()
          |> then(&json(conn, &1))
        else
          send_resp(conn, 404, "Not Found")
        end
    end
  end

  def reblogged_by(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Objects.get(id) do
      nil ->
        send_resp(conn, 404, "Not Found")

      object ->
        if Objects.visible_to?(object, current_user) do
          Relationships.list_by_type_object("Announce", object.ap_id)
          |> Enum.map(& &1.actor)
          |> render_accounts_by_ap_ids()
          |> then(&json(conn, &1))
        else
          send_resp(conn, 404, "Not Found")
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = user <- conn.assigns.current_user,
         true <- object.type == "Note" and object.actor == user.ap_id,
         {:ok, _delete} <- Pipeline.ingest(Delete.build(user, object), local: true) do
      json(conn, StatusRenderer.render_status(object, user))
    else
      nil -> send_resp(conn, 404, "Not Found")
      false -> send_resp(conn, 403, "Forbidden")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def favourite(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = user <- conn.assigns.current_user,
         true <- Objects.visible_to?(object, user) do
      case Relationships.get_by_type_actor_object("Like", user.ap_id, object.ap_id) do
        %{} ->
          json(conn, StatusRenderer.render_status(object, user))

        nil ->
          with {:ok, _liked} <- Pipeline.ingest(Like.build(user, object), local: true) do
            json(conn, StatusRenderer.render_status(object, user))
          else
            {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
          end
      end
    else
      nil -> send_resp(conn, 404, "Not Found")
      false -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def unfavourite(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = user <- conn.assigns.current_user,
         true <- Objects.visible_to?(object, user),
         %{} =
           relationship <-
           Relationships.get_by_type_actor_object(
             "Like",
             user.ap_id,
             object.ap_id
           ),
         {:ok, _undo} <-
           Pipeline.ingest(Undo.build(user, relationship.activity_ap_id),
             local: true
           ) do
      json(conn, StatusRenderer.render_status(object, user))
    else
      nil -> send_resp(conn, 404, "Not Found")
      false -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def bookmark(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = user <- conn.assigns.current_user,
         true <- Objects.visible_to?(object, user) do
      case Relationships.upsert_relationship(%{
             type: "Bookmark",
             actor: user.ap_id,
             object: object.ap_id
           }) do
        {:ok, _} -> json(conn, StatusRenderer.render_status(object, user))
        {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
      end
    else
      nil -> send_resp(conn, 404, "Not Found")
      false -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def unbookmark(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = user <- conn.assigns.current_user,
         true <- Objects.visible_to?(object, user) do
      _ = Relationships.delete_by_type_actor_object("Bookmark", user.ap_id, object.ap_id)
      json(conn, StatusRenderer.render_status(object, user))
    else
      nil -> send_resp(conn, 404, "Not Found")
      false -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def reblog(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = user <- conn.assigns.current_user,
         true <- Objects.visible_to?(object, user) do
      case Relationships.get_by_type_actor_object("Announce", user.ap_id, object.ap_id) do
        %{} = relationship ->
          relationship.activity_ap_id
          |> Objects.get_by_ap_id()
          |> case do
            %{} = announce -> json(conn, StatusRenderer.render_status(announce, user))
            _ -> json(conn, StatusRenderer.render_status(object, user))
          end

        nil ->
          with {:ok, announce} <- Pipeline.ingest(Announce.build(user, object), local: true) do
            json(conn, StatusRenderer.render_status(announce, user))
          else
            {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
          end
      end
    else
      nil -> send_resp(conn, 404, "Not Found")
      false -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def unreblog(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = user <- conn.assigns.current_user,
         true <- Objects.visible_to?(object, user),
         %{} =
           relationship <-
           Relationships.get_by_type_actor_object(
             "Announce",
             user.ap_id,
             object.ap_id
           ),
         {:ok, _undo} <-
           Pipeline.ingest(Undo.build(user, relationship.activity_ap_id),
             local: true
           ) do
      json(conn, StatusRenderer.render_status(object, user))
    else
      nil -> send_resp(conn, 404, "Not Found")
      false -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  defp render_accounts_by_ap_ids(ap_ids) when is_list(ap_ids) do
    ap_ids =
      ap_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    ap_ids_uniq = Enum.uniq(ap_ids)

    users_by_ap_id =
      ap_ids_uniq
      |> Users.list_by_ap_ids()
      |> Map.new(&{&1.ap_id, &1})

    followers_counts = Relationships.count_by_type_objects("Follow", ap_ids_uniq)
    following_counts = Relationships.count_by_type_actors("Follow", ap_ids_uniq)
    statuses_counts = Objects.count_notes_by_actors(ap_ids_uniq)

    Enum.map(ap_ids, fn ap_id ->
      case Map.get(users_by_ap_id, ap_id) do
        %User{} = user ->
          AccountRenderer.render_account(user,
            followers_count: Map.get(followers_counts, ap_id, 0),
            following_count: Map.get(following_counts, ap_id, 0),
            statuses_count: Map.get(statuses_counts, ap_id, 0)
          )

        _ ->
          AccountRenderer.render_account(%{
            ap_id: ap_id,
            nickname: Fallback.fallback_username(ap_id)
          })
      end
    end)
  end

  defp render_accounts_by_ap_ids(_ap_ids), do: []
end
