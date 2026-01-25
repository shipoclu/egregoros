defmodule Egregoros.Publish.PostBuilder do
  @moduledoc false

  alias Egregoros.Domain
  alias Egregoros.Mentions
  alias Egregoros.Objects
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.URL

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  def put_attachments(post, attachments)
      when is_map(post) and is_list(attachments) do
    if attachments == [] do
      post
    else
      Map.put(post, "attachment", attachments)
    end
  end

  def put_attachments(post, _attachments), do: post

  def put_in_reply_to(post, nil), do: post

  def put_in_reply_to(post, in_reply_to)
      when is_map(post) and is_binary(in_reply_to) do
    Map.put(post, "inReplyTo", in_reply_to)
  end

  def put_in_reply_to(post, _in_reply_to), do: post

  def put_visibility(post, visibility, actor, mention_recipients)
      when is_map(post) and is_binary(visibility) and is_binary(actor) do
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

    post
    |> Map.put("to", to)
    |> Map.put("cc", cc)
  end

  def put_visibility(post, _visibility, _actor, _mention_recipients), do: post

  def put_tags(post, tags) when is_map(post) and is_list(tags) do
    tags =
      tags
      |> Enum.filter(&is_map/1)
      |> Enum.uniq_by(fn tag ->
        Map.get(tag, "href") || Map.get(tag, "id") || Map.get(tag, "name") || tag
      end)

    if tags == [] do
      post
    else
      existing =
        post
        |> Map.get("tag", [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)

      Map.put(post, "tag", Enum.uniq_by(existing ++ tags, &(Map.get(&1, "href") || &1)))
    end
  end

  def put_tags(post, _tags), do: post

  def put_summary(post, value) when is_map(post) and is_binary(value) do
    summary = String.trim(value)

    if summary == "" do
      post
    else
      Map.put(post, "summary", summary)
    end
  end

  def put_summary(post, _value), do: post

  def put_sensitive(post, value) when is_map(post) do
    case value do
      true -> Map.put(post, "sensitive", true)
      "true" -> Map.put(post, "sensitive", true)
      _ -> post
    end
  end

  def put_sensitive(post, _value), do: post

  def put_language(post, value) when is_map(post) and is_binary(value) do
    language = String.trim(value)

    if language == "" do
      post
    else
      Map.put(post, "language", language)
    end
  end

  def put_language(post, _value), do: post

  def mention_tag(%{ap_id: ap_id, name: name})
      when is_binary(ap_id) and is_binary(name) do
    %{"type" => "Mention", "href" => ap_id, "name" => name}
  end

  def mention_tag(_mention), do: nil

  def hashtag_tags(content) when is_binary(content) do
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

  def hashtag_tags(_content), do: []

  def mention_hrefs(mentions) when is_list(mentions) do
    Enum.reduce(mentions, %{}, fn
      %{nickname: nickname, host: host, ap_id: ap_id}, acc
      when is_binary(nickname) and is_binary(ap_id) ->
        Map.put(acc, {nickname, host}, ap_id)

      _other, acc ->
        acc
    end)
  end

  def mention_hrefs(_mentions), do: %{}

  def resolve_mentions(content, actor_ap_id)
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

  def resolve_mentions(_content, _actor_ap_id), do: {[], []}

  def resolve_reply_mentions(nil, _actor_ap_id), do: []

  def resolve_reply_mentions(in_reply_to, actor_ap_id)
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

  def resolve_reply_mentions(_in_reply_to, _actor_ap_id), do: []

  # Hashtag helpers

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

  # Mention resolution helpers

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
