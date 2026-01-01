defmodule Egregoros.Workers.ResolveMentions do
  use Oban.Worker,
    queue: :federation_outgoing,
    max_attempts: 3,
    unique: [period: 60 * 5, keys: [:create_ap_id]]

  alias Egregoros.Activities.Create
  alias Egregoros.Federation.Actor
  alias Egregoros.Federation.WebFinger
  alias Egregoros.HTML
  alias Egregoros.Mentions
  alias Egregoros.Objects
  alias Egregoros.Timeline
  alias Egregoros.User
  alias Egregoros.Users

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"create_ap_id" => create_ap_id}}) when is_binary(create_ap_id) do
    with %Egregoros.Object{} = create_object <- Objects.get_by_ap_id(create_ap_id),
         note_ap_id when is_binary(note_ap_id) <- create_object.object,
         %Egregoros.Object{} = note_object <- Objects.get_by_ap_id(note_ap_id),
         {:ok, {create_object, _note_object}} <- resolve_and_patch(create_object, note_object) do
      _ = Create.side_effects(create_object, local: true, deliver: true)
      :ok
    else
      nil -> {:discard, :unknown_object}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :resolution_failed}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  defp resolve_and_patch(%Egregoros.Object{} = create_object, %Egregoros.Object{} = note_object) do
    with actor_ap_id when is_binary(actor_ap_id) <- note_object.actor,
         %{} = note_data <- note_object.data,
         content when is_binary(content) <- get_in(note_data, ["source", "content"]),
         {mentions, _mention_recipient_ids} <- resolve_mentions(content, actor_ap_id),
         %{} = updated_note_data <- patch_note(note_data, content, actor_ap_id, mentions),
         :ok <- fetch_missing_recipients(updated_note_data),
         {:ok, note_object} <- Objects.update_object(note_object, %{data: updated_note_data}),
         :ok <- Timeline.broadcast_post_updated(note_object),
         %{} = updated_create_data <- patch_create(create_object.data, updated_note_data),
         {:ok, create_object} <- Objects.update_object(create_object, %{data: updated_create_data}) do
      {:ok, {create_object, note_object}}
    else
      _ -> {:error, :invalid_note}
    end
  end

  defp patch_note(%{} = note_data, content, actor_ap_id, mentions)
       when is_binary(content) and is_binary(actor_ap_id) and is_list(mentions) do
    local_domains = local_domains(actor_ap_id)

    mention_hrefs =
      mentions
      |> Enum.reduce(%{}, fn
        %{nickname: nickname, host: host, ap_id: ap_id}, acc
        when is_binary(nickname) and is_binary(host) and is_binary(ap_id) ->
          Map.put(acc, {nickname, host}, ap_id)

        _other, acc ->
          acc
      end)

    mention_tags =
      mentions
      |> Enum.map(&mention_tag/1)
      |> Enum.filter(&is_map/1)

    mention_recipient_ids =
      mentions
      |> Enum.map(&Map.get(&1, :ap_id))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == actor_ap_id))
      |> Enum.uniq()

    content_html = HTML.to_safe_html(content, format: :text, mention_hrefs: mention_hrefs)

    existing_tags =
      note_data
      |> Map.get("tag", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    tags =
      (existing_tags ++ mention_tags)
      |> Enum.uniq_by(fn tag ->
        Map.get(tag, "href") || Map.get(tag, "id") || Map.get(tag, "name") || tag
      end)

    {to, cc} = merge_addressing(note_data, actor_ap_id, mention_recipient_ids, local_domains)

    note_data
    |> Map.put("content", content_html)
    |> Map.put("to", to)
    |> Map.put("cc", cc)
    |> Map.put("tag", tags)
  end

  defp patch_note(note_data, _content, _actor_ap_id, _mentions), do: note_data

  defp patch_create(%{} = create_data, %{} = note_data) do
    to = note_data |> Map.get("to", []) |> List.wrap()
    cc = note_data |> Map.get("cc", []) |> List.wrap()

    create_data
    |> Map.put("to", to)
    |> Map.put("cc", cc)
    |> Map.put("object", note_data)
  end

  defp patch_create(create_data, _note_data), do: create_data

  defp fetch_missing_recipients(%{} = note_data) do
    note_data
    |> recipient_actor_ids()
    |> Enum.each(fn ap_id ->
      case Users.get_by_ap_id(ap_id) do
        %User{} ->
          :ok

        nil ->
          _ = Actor.fetch_and_store(ap_id)
          :ok
      end
    end)

    :ok
  end

  defp fetch_missing_recipients(_note_data), do: :ok

  defp resolve_mentions(content, actor_ap_id) when is_binary(content) and is_binary(actor_ap_id) do
    local_domains = local_domains(actor_ap_id)

    mentions =
      content
      |> Mentions.extract()
      |> Enum.reduce([], fn {nickname, host}, acc ->
        host_normalized = normalize_host(host)
        name = mention_name(nickname, host_normalized, local_domains)

        case resolve_mention_recipient(nickname, host_normalized, local_domains) do
          ap_id when is_binary(ap_id) and ap_id != "" ->
            [%{nickname: nickname, host: host_normalized, ap_id: ap_id, name: name} | acc]

          _ ->
            acc
        end
      end)
      |> Enum.uniq_by(& &1.ap_id)

    {mentions, Enum.map(mentions, & &1.ap_id)}
  end

  defp resolve_mentions(_content, _actor_ap_id), do: {[], []}

  defp resolve_mention_recipient(nickname, nil, _local_domains) when is_binary(nickname) do
    case Users.get_by_nickname(nickname) do
      %User{ap_id: ap_id} when is_binary(ap_id) -> ap_id
      _ -> nil
    end
  end

  defp resolve_mention_recipient(nickname, host, local_domains)
       when is_binary(nickname) and is_binary(host) and is_list(local_domains) do
    host = host |> String.trim() |> String.downcase()

    if host in local_domains do
      resolve_mention_recipient(nickname, nil, local_domains)
    else
      handle = nickname <> "@" <> host

      case Users.get_by_handle(handle) do
        %User{ap_id: ap_id} when is_binary(ap_id) ->
          ap_id

        _ ->
          with {:ok, actor_url} <- WebFinger.lookup(handle),
               {:ok, %User{ap_id: ap_id}} <- Actor.fetch_and_store(actor_url) do
            ap_id
          else
            _ -> nil
          end
      end
    end
  end

  defp resolve_mention_recipient(_nickname, _host, _local_domains), do: nil

  defp normalize_host(nil), do: nil

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_host(_host), do: nil

  defp mention_name(nickname, nil, _local_domains) when is_binary(nickname) do
    "@" <> nickname
  end

  defp mention_name(nickname, host, local_domains)
       when is_binary(nickname) and is_binary(host) and is_list(local_domains) do
    if host in local_domains do
      "@" <> nickname
    else
      "@" <> nickname <> "@" <> host
    end
  end

  defp mention_name(nickname, _host, _local_domains) when is_binary(nickname) do
    "@" <> nickname
  end

  defp mention_tag(%{ap_id: ap_id, name: name}) when is_binary(ap_id) and is_binary(name) do
    %{"type" => "Mention", "href" => ap_id, "name" => name}
  end

  defp mention_tag(_mention), do: nil

  defp merge_addressing(%{} = note_data, actor_ap_id, mention_recipient_ids, local_domains)
       when is_binary(actor_ap_id) and is_list(mention_recipient_ids) and is_list(local_domains) do
    followers = actor_ap_id <> "/followers"
    to = note_data |> Map.get("to", []) |> List.wrap()
    cc = note_data |> Map.get("cc", []) |> List.wrap()

    mention_recipient_ids =
      mention_recipient_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == actor_ap_id))
      |> Enum.uniq()

    direct? =
      cc == [] and @as_public not in to and @as_public not in cc and
        followers not in to and followers not in cc

    cond do
      direct? ->
        {Enum.uniq(to ++ mention_recipient_ids), []}

      @as_public in to ->
        {to, Enum.uniq(cc ++ mention_recipient_ids)}

      @as_public in cc ->
        {to, Enum.uniq(cc ++ mention_recipient_ids)}

      followers in to or followers in cc ->
        {to, Enum.uniq(cc ++ mention_recipient_ids)}

      true ->
        {to, Enum.uniq(cc ++ mention_recipient_ids)}
    end
  end

  defp merge_addressing(note_data, _actor_ap_id, _mention_recipient_ids, _local_domains) do
    to = note_data |> Map.get("to", []) |> List.wrap()
    cc = note_data |> Map.get("cc", []) |> List.wrap()
    {to, cc}
  end

  @recipient_fields ~w(to cc bto bcc audience)

  defp recipient_actor_ids(%{} = data) do
    @recipient_fields
    |> Enum.flat_map(fn field ->
      data
      |> Map.get(field, [])
      |> List.wrap()
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 == @as_public or String.ends_with?(&1, "/followers")))
    |> Enum.uniq()
  end

  defp recipient_actor_ids(_data), do: []

  defp local_domains(actor_ap_id) when is_binary(actor_ap_id) do
    case URI.parse(String.trim(actor_ap_id)) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host = String.downcase(host)

        port =
          case URI.parse(String.trim(actor_ap_id)) do
            %URI{port: port} when is_integer(port) and port > 0 -> port
            _ -> nil
          end

        domains =
          [host, if(is_integer(port), do: host <> ":" <> Integer.to_string(port), else: nil)]
          |> Enum.filter(&is_binary/1)

        Enum.uniq(domains)

      _ ->
        []
    end
  end

  defp local_domains(_actor_ap_id), do: []
end
