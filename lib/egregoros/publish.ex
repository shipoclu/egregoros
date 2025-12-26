defmodule Egregoros.Publish do
  alias Egregoros.Activities.Create
  alias Egregoros.Activities.Note
  alias Egregoros.Federation.Actor
  alias Egregoros.Federation.WebFinger
  alias Egregoros.Mentions
  alias Egregoros.Pipeline
  alias Egregoros.User
  alias Egregoros.Users

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @max_note_chars 5000

  def post_note(%User{} = user, content) when is_binary(content) do
    post_note(user, content, [])
  end

  def post_note(%User{} = user, content, opts) when is_binary(content) and is_list(opts) do
    content = String.trim(content)
    attachments = Keyword.get(opts, :attachments, [])
    in_reply_to = Keyword.get(opts, :in_reply_to)
    visibility = Keyword.get(opts, :visibility, "public")
    spoiler_text = Keyword.get(opts, :spoiler_text)
    sensitive = Keyword.get(opts, :sensitive)
    language = Keyword.get(opts, :language)

    cond do
      content == "" and attachments == [] ->
        {:error, :empty}

      String.length(content) > @max_note_chars ->
        {:error, :too_long}

      true ->
        mentions = resolve_mentions(content, user.ap_id)
        mention_recipient_ids = Enum.map(mentions, & &1.ap_id)
        mention_tags = Enum.map(mentions, &mention_tag/1)

        note =
          user
          |> Note.build(content)
          |> maybe_put_attachments(attachments)
          |> maybe_put_in_reply_to(in_reply_to)
          |> maybe_put_visibility(visibility, user.ap_id, mention_recipient_ids)
          |> maybe_put_tags(mention_tags)
          |> maybe_put_summary(spoiler_text)
          |> maybe_put_sensitive(sensitive)
          |> maybe_put_language(language)

        create = Create.build(user, note)

        Pipeline.ingest(create, local: true)
    end
  end

  defp maybe_put_attachments(note, attachments) when is_map(note) and is_list(attachments) do
    if attachments == [] do
      note
    else
      Map.put(note, "attachment", attachments)
    end
  end

  defp maybe_put_attachments(note, _attachments), do: note

  defp maybe_put_in_reply_to(note, nil), do: note

  defp maybe_put_in_reply_to(note, in_reply_to) when is_map(note) and is_binary(in_reply_to) do
    Map.put(note, "inReplyTo", in_reply_to)
  end

  defp maybe_put_in_reply_to(note, _in_reply_to), do: note

  defp maybe_put_visibility(note, visibility, actor, mention_recipients)
       when is_map(note) and is_binary(visibility) and is_binary(actor) do
    followers = actor <> "/followers"

    mention_recipients =
      mention_recipients
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == actor))
      |> Enum.uniq()

    {to, cc} =
      case visibility do
        "public" -> {[@as_public], Enum.uniq([followers] ++ mention_recipients)}
        "unlisted" -> {[followers], Enum.uniq([@as_public] ++ mention_recipients)}
        "private" -> {[followers], mention_recipients}
        "direct" -> {mention_recipients, []}
        _ -> {[@as_public], Enum.uniq([followers] ++ mention_recipients)}
      end

    note
    |> Map.put("to", to)
    |> Map.put("cc", cc)
  end

  defp maybe_put_visibility(note, _visibility, _actor, _direct_recipients), do: note

  defp maybe_put_tags(note, tags) when is_map(note) and is_list(tags) do
    tags =
      tags
      |> Enum.filter(&is_map/1)
      |> Enum.uniq_by(fn tag ->
        Map.get(tag, "href") || Map.get(tag, "id") || Map.get(tag, "name") || tag
      end)

    if tags == [] do
      note
    else
      existing =
        note
        |> Map.get("tag", [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)

      Map.put(note, "tag", Enum.uniq_by(existing ++ tags, &(Map.get(&1, "href") || &1)))
    end
  end

  defp maybe_put_tags(note, _tags), do: note

  defp maybe_put_summary(note, value) when is_map(note) and is_binary(value) do
    summary = String.trim(value)

    if summary == "" do
      note
    else
      Map.put(note, "summary", summary)
    end
  end

  defp maybe_put_summary(note, _value), do: note

  defp maybe_put_sensitive(note, value) when is_map(note) do
    case value do
      true -> Map.put(note, "sensitive", true)
      "true" -> Map.put(note, "sensitive", true)
      _ -> note
    end
  end

  defp maybe_put_sensitive(note, _value), do: note

  defp maybe_put_language(note, value) when is_map(note) and is_binary(value) do
    language = String.trim(value)

    if language == "" do
      note
    else
      Map.put(note, "language", language)
    end
  end

  defp maybe_put_language(note, _value), do: note

  defp resolve_mentions(content, actor_ap_id)
       when is_binary(content) and is_binary(actor_ap_id) do
    local_domains = local_domains(actor_ap_id)

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
  end

  defp resolve_mentions(_content, _actor_ap_id), do: []

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
