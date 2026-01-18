defmodule Egregoros.Publish.Notes do
  @moduledoc """
  Note-specific publish operations.

  Handles posting notes and related operations for ActivityPub Note objects.
  """

  alias Egregoros.Activities.Create
  alias Egregoros.Activities.EncryptedMessage
  alias Egregoros.Activities.Note
  alias Egregoros.Domain
  alias Egregoros.HTML
  alias Egregoros.Mentions
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.URL

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @max_note_chars 5000

  @doc """
  Post a note with default options.

  ## Parameters
  - `user` - The user posting the note
  - `content` - The text content of the note

  ## Returns
  - `{:ok, create_activity}` on success
  - `{:error, reason}` on failure
  """
  def post_note(%User{} = user, content) when is_binary(content) do
    post_note(user, content, [])
  end

  @doc """
  Post a note with options.

  ## Parameters
  - `user` - The user posting the note
  - `content` - The text content of the note
  - `opts` - Keyword list of options:
    - `:attachments` - List of media attachments
    - `:in_reply_to` - AP ID of the parent object
    - `:visibility` - One of "public", "unlisted", "private", "direct"
    - `:spoiler_text` - Content warning text
    - `:sensitive` - Whether the post contains sensitive content
    - `:language` - Language code for the post
    - `:e2ee_dm` - E2EE payload for encrypted direct messages

  ## Returns
  - `{:ok, create_activity}` on success
  - `{:error, reason}` on failure

  ## Error reasons
  - `:empty` - Content is empty and no attachments provided
  - `:too_long` - Content exceeds maximum character limit
  """
  def post_note(%User{} = user, content, opts) when is_binary(content) and is_list(opts) do
    content = String.trim(content)
    attachments = Keyword.get(opts, :attachments, [])
    in_reply_to = Keyword.get(opts, :in_reply_to)
    visibility = Keyword.get(opts, :visibility, "public")
    spoiler_text = Keyword.get(opts, :spoiler_text)
    sensitive = Keyword.get(opts, :sensitive)
    language = Keyword.get(opts, :language)
    e2ee_dm = Keyword.get(opts, :e2ee_dm)

    cond do
      content == "" and attachments == [] ->
        {:error, :empty}

      String.length(content) > @max_note_chars ->
        {:error, :too_long}

      true ->
        {mentions, unresolved_remote_mentions} = resolve_mentions(content, user.ap_id)
        reply_mentions = resolve_reply_mentions(in_reply_to, user.ap_id)

        mentions =
          (mentions ++ reply_mentions)
          |> Enum.filter(&is_map/1)
          |> Enum.uniq_by(& &1.ap_id)

        mention_recipient_ids = Enum.map(mentions, & &1.ap_id)
        mention_tags = Enum.map(mentions, &mention_tag/1)
        hashtag_tags = hashtag_tags(content)

        mention_hrefs =
          mentions
          |> Enum.reduce(%{}, fn
            %{nickname: nickname, host: host, ap_id: ap_id}, acc
            when is_binary(nickname) and is_binary(ap_id) ->
              Map.put(acc, {nickname, host}, ap_id)

            _other, acc ->
              acc
          end)

        content_html = HTML.to_safe_html(content, format: :text, mention_hrefs: mention_hrefs)

        note =
          user
          |> Note.build(content_html)
          |> Map.put("source", %{"content" => content, "mediaType" => "text/plain"})
          |> maybe_put_attachments(attachments)
          |> maybe_put_in_reply_to(in_reply_to)
          |> maybe_put_visibility(visibility, user.ap_id, mention_recipient_ids)
          |> maybe_put_tags(mention_tags ++ hashtag_tags)
          |> maybe_put_summary(spoiler_text)
          |> maybe_put_sensitive(sensitive)
          |> maybe_put_language(language)
          |> maybe_put_e2ee_dm(e2ee_dm)

        create = Create.build(user, note)

        ingest_opts =
          if unresolved_remote_mentions == [] do
            [local: true]
          else
            [local: true, deliver: false]
          end

        with {:ok, create_object} <- Pipeline.ingest(create, ingest_opts) do
          if unresolved_remote_mentions != [] do
            _ =
              Oban.insert(
                Egregoros.Workers.ResolveMentions.new(%{
                  "create_ap_id" => create_object.ap_id,
                  "remote_mentions" => unresolved_remote_mentions
                })
              )
          end

          {:ok, create_object}
        end
    end
  end

  # Private helpers for building notes

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

  defp maybe_put_e2ee_dm(note, %{} = payload) when is_map(note) do
    if map_size(payload) == 0 do
      note
    else
      note
      |> Map.put("egregoros:e2ee_dm", payload)
      |> Map.put("type", EncryptedMessage.type())
    end
  end

  defp maybe_put_e2ee_dm(note, _payload), do: note

  # Mention resolution helpers

  defp resolve_mentions(content, actor_ap_id)
       when is_binary(content) and is_binary(actor_ap_id) do
    local_domains = local_domains(actor_ap_id)

    content
    |> Mentions.extract()
    |> Enum.reduce({[], []}, fn {nickname, host}, {mentions, unresolved} ->
      host_normalized = normalize_host(host)
      name = mention_name(nickname, host_normalized, local_domains)

      case resolve_mention_recipient(nickname, host_normalized, local_domains) do
        ap_id when is_binary(ap_id) and ap_id != "" ->
          {[%{nickname: nickname, host: host_normalized, ap_id: ap_id, name: name} | mentions],
           unresolved}

        {:unresolved, handle} when is_binary(handle) and handle != "" ->
          {mentions, [handle | unresolved]}

        _ ->
          {mentions, unresolved}
      end
    end)
    |> then(fn {mentions, unresolved} ->
      unresolved =
        unresolved
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      {Enum.uniq_by(mentions, & &1.ap_id), unresolved}
    end)
  end

  defp resolve_mentions(_content, _actor_ap_id), do: {[], []}

  defp resolve_reply_mentions(nil, _actor_ap_id), do: []

  defp resolve_reply_mentions(in_reply_to, actor_ap_id)
       when is_binary(in_reply_to) and is_binary(actor_ap_id) do
    in_reply_to = String.trim(in_reply_to)

    if in_reply_to == "" do
      []
    else
      local_domains = local_domains(actor_ap_id)

      with %{} = parent <- Objects.get_by_ap_id(in_reply_to),
           parent_actor when is_binary(parent_actor) and parent_actor != "" <- parent.actor,
           true <- parent_actor != actor_ap_id do
        name = mention_name_for_ap_id(parent_actor, local_domains)
        [%{nickname: nil, host: nil, ap_id: parent_actor, name: name}]
      else
        _ -> []
      end
    end
  end

  defp resolve_reply_mentions(_in_reply_to, _actor_ap_id), do: []

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
          {:unresolved, handle}
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

  # Hashtag helpers

  defp hashtag_tags(content) when is_binary(content) do
    content
    |> extract_hashtags()
    |> Enum.map(fn tag ->
      %{
        "type" => "Hashtag",
        "name" => "#" <> tag,
        "href" => URL.absolute("/tags/" <> tag)
      }
    end)
  end

  defp hashtag_tags(_content), do: []

  defp extract_hashtags(content) when is_binary(content) do
    Regex.scan(~r/(?:^|[^\p{L}\p{N}_])#([\p{L}\p{N}_][\p{L}\p{N}_-]{0,63})/u, content)
    |> Enum.map(fn
      [_full, tag] -> normalize_hashtag(tag)
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_hashtags(_content), do: []

  defp normalize_hashtag(tag) when is_binary(tag) do
    tag = tag |> String.trim() |> String.trim_leading("#") |> String.downcase()
    if valid_hashtag?(tag), do: tag, else: ""
  end

  defp normalize_hashtag(_tag), do: ""

  defp valid_hashtag?(tag) when is_binary(tag) do
    Regex.match?(~r/^[\p{L}\p{N}_][\p{L}\p{N}_-]{0,63}$/u, tag)
  end

  defp valid_hashtag?(_tag), do: false

  # Actor mention helpers

  defp mention_name_for_ap_id(actor_ap_id, local_domains)
       when is_binary(actor_ap_id) and is_list(local_domains) do
    case Users.get_by_ap_id(actor_ap_id) do
      %User{local: true, nickname: nickname} when is_binary(nickname) and nickname != "" ->
        "@" <> nickname

      %User{local: false, nickname: nickname, domain: domain}
      when is_binary(nickname) and nickname != "" and is_binary(domain) and domain != "" ->
        "@" <> nickname <> "@" <> domain

      %User{nickname: nickname} when is_binary(nickname) and nickname != "" ->
        "@" <> nickname

      _ ->
        case URI.parse(actor_ap_id) do
          %URI{} = uri ->
            domain = Domain.from_uri(uri)

            host =
              case domain do
                value when is_binary(value) and value != "" -> value
                _ -> uri.host
              end

            nickname =
              uri
              |> Map.get(:path)
              |> fallback_nickname()

            mention_name(nickname, host, local_domains)

          _ ->
            "@unknown"
        end
    end
  end

  defp mention_name_for_ap_id(_actor_ap_id, _local_domains), do: "@unknown"

  defp fallback_nickname(nil), do: "unknown"

  defp fallback_nickname(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> List.last()
    |> case do
      nil -> "unknown"
      value -> value
    end
  end

  defp fallback_nickname(_path), do: "unknown"

  # Domain helpers

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
