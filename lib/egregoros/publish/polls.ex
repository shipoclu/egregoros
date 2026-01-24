defmodule Egregoros.Publish.Polls do
  @moduledoc """
  Poll (Question) specific publish operations.

  Handles voting and poll-specific actions for ActivityPub Question objects.
  """

  alias Egregoros.Activities.Answer
  alias Egregoros.Activities.Create
  alias Egregoros.Domain
  alias Egregoros.HTML
  alias Egregoros.Mentions
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Objects.Polls
  alias Egregoros.Pipeline
  alias Egregoros.User
  alias Egregoros.Users
  alias Egregoros.Workers.ResolveMentions
  alias EgregorosWeb.URL

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @max_note_chars 5000
  @max_poll_options 4
  @max_poll_option_chars 50
  @min_poll_expiration 300
  @max_poll_expiration 2_592_000

  @doc """
  Vote on a poll (Question object).

  ## Parameters
  - `user` - The user casting the vote
  - `question` - The Question object to vote on
  - `choices` - List of 0-indexed option indices

  ## Returns
  - `{:ok, updated_question}` on success
  - `{:error, reason}` on failure

  ## Error reasons
  - `:already_voted` - User has already voted on this poll
  - `:poll_expired` - The poll has ended
  - `:invalid_choice` - One or more choice indices are invalid
  - `:own_poll` - User cannot vote on their own poll
  - `:multiple_choices_not_allowed` - Multiple choices submitted for single-choice poll
  """
  def vote_on_poll(%User{} = user, %Object{type: "Question"} = question, choices)
      when is_list(choices) do
    with :ok <- validate_not_own_poll(user, question),
         :ok <- validate_not_already_voted(user, question),
         :ok <- validate_poll_not_expired(question),
         {:ok, options, multiple?} <- get_poll_options(question),
         :ok <- validate_choices(choices, options, multiple?),
         {:ok, _answers} <- create_vote_answers(user, question, options, choices) do
      {:ok, Objects.get_by_ap_id(question.ap_id)}
    end
  end

  def vote_on_poll(_user, _question, _choices), do: {:error, :invalid_poll}

  @doc """
  Post a poll with default options.

  ## Parameters
  - `user` - The user posting the poll
  - `content` - The text content of the poll
  - `poll_params` - Map containing poll options and configuration

  ## Returns
  - `{:ok, create_activity}` on success
  - `{:error, reason}` on failure
  """
  def post_poll(%User{} = user, content, poll_params)
      when is_binary(content) and is_map(poll_params) do
    post_poll(user, content, poll_params, [])
  end

  @doc """
  Post a poll with options.

  ## Parameters
  - `user` - The user posting the poll
  - `content` - The text content of the poll
  - `poll_params` - Map containing poll options and configuration
  - `opts` - Keyword list of options:
    - `:attachments` - List of media attachments
    - `:in_reply_to` - AP ID of the parent object
    - `:visibility` - One of "public", "unlisted", "private", "direct"
    - `:spoiler_text` - Content warning text
    - `:sensitive` - Whether the post contains sensitive content
    - `:language` - Language code for the post

  ## Returns
  - `{:ok, create_activity}` on success
  - `{:error, reason}` on failure

  ## Error reasons
  - `:empty` - Content is empty and no attachments provided
  - `:too_long` - Content exceeds maximum character limit
  - String - Validation message for invalid poll params
  """
  def post_poll(%User{} = user, content, poll_params, opts)
      when is_binary(content) and is_map(poll_params) and is_list(opts) do
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
        with {:ok, poll_data} <- build_poll_data(poll_params) do
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

          question =
            build_question(user, content, content_html)
            |> Map.merge(poll_data)
            |> maybe_put_attachments(attachments)
            |> maybe_put_in_reply_to(in_reply_to)
            |> maybe_put_visibility(visibility, user.ap_id, mention_recipient_ids)
            |> maybe_put_tags(mention_tags ++ hashtag_tags)
            |> maybe_put_summary(spoiler_text)
            |> maybe_put_sensitive(sensitive)
            |> maybe_put_language(language)

          create = Create.build(user, question)

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
                  ResolveMentions.new(%{
                    "create_ap_id" => create_object.ap_id,
                    "remote_mentions" => unresolved_remote_mentions
                  })
                )
            end

            {:ok, create_object}
          end
        end
    end
  end

  def post_poll(_user, _content, _poll_params, _opts), do: {:error, :invalid_poll}

  # Private functions

  defp build_question(%User{ap_id: actor_ap_id}, content, content_html)
       when is_binary(actor_ap_id) and is_binary(content_html) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "id" => URL.absolute("/objects/" <> Ecto.UUID.generate()),
      "type" => "Question",
      "actor" => actor_ap_id,
      "attributedTo" => actor_ap_id,
      "context" => URL.absolute("/contexts/" <> Ecto.UUID.generate()),
      "content" => content_html,
      "source" => %{"content" => content, "mediaType" => "text/plain"},
      "published" => now
    }
  end

  defp build_question(_user, _content, _content_html), do: %{}

  defp build_poll_data(poll_params) when is_map(poll_params) do
    options = poll_param(poll_params, "options") |> List.wrap()
    expires_in = poll_param(poll_params, "expires_in")
    multiple? = truthy_param?(poll_param(poll_params, "multiple"))

    with {:ok, options} <- validate_poll_options(options),
         {:ok, expires_in} <- validate_poll_expiration(expires_in) do
      option_notes = Enum.map(options, &poll_option_note/1)

      end_time =
        DateTime.utc_now()
        |> DateTime.add(expires_in, :second)
        |> DateTime.to_iso8601()

      key = if multiple?, do: "anyOf", else: "oneOf"
      poll = %{"type" => "Question", key => option_notes, "closed" => end_time}

      {:ok, poll}
    end
  end

  defp build_poll_data(_poll_params), do: {:error, "Invalid poll"}

  defp poll_param(params, "options") when is_map(params) do
    Map.get(params, "options") || Map.get(params, :options)
  end

  defp poll_param(params, "expires_in") when is_map(params) do
    Map.get(params, "expires_in") || Map.get(params, :expires_in)
  end

  defp poll_param(params, "multiple") when is_map(params) do
    Map.get(params, "multiple") || Map.get(params, :multiple)
  end

  defp poll_param(_params, _key), do: nil

  defp poll_option_note(option) when is_binary(option) do
    %{
      "name" => option,
      "type" => "Note",
      "replies" => %{"type" => "Collection", "totalItems" => 0}
    }
  end

  defp poll_option_note(option) do
    option = option |> to_string() |> String.trim()
    poll_option_note(option)
  end

  defp validate_poll_options(options) when is_list(options) do
    options =
      options
      |> Enum.map(fn option -> option |> to_string() |> String.trim() end)

    cond do
      Enum.any?(options, &(&1 == "")) ->
        {:error, "Poll options cannot be blank."}

      Enum.uniq(options) != options ->
        {:error, "Poll options must be unique."}

      length(options) < 2 ->
        {:error, "Poll must contain at least 2 options"}

      length(options) > @max_poll_options ->
        {:error, "Poll can't contain more than #{@max_poll_options} options"}

      Enum.any?(options, &(String.length(&1) > @max_poll_option_chars)) ->
        {:error, "Poll options cannot be longer than #{@max_poll_option_chars} characters each"}

      true ->
        {:ok, options}
    end
  end

  defp validate_poll_options(_options), do: {:error, "Invalid poll"}

  defp validate_poll_expiration(expires_in) do
    expires_in = normalize_expires_in(expires_in)

    cond do
      is_nil(expires_in) ->
        {:error, "Invalid poll"}

      expires_in > @max_poll_expiration ->
        {:error, "Expiration date is too far in the future"}

      expires_in < @min_poll_expiration ->
        {:error, "Expiration date is too soon"}

      true ->
        {:ok, expires_in}
    end
  end

  defp normalize_expires_in(value) when is_integer(value), do: value

  defp normalize_expires_in(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_expires_in(_value), do: nil

  defp truthy_param?(value) do
    case value do
      true -> true
      1 -> true
      "1" -> true
      "true" -> true
      _ -> false
    end
  end

  defp validate_not_own_poll(%User{ap_id: user_ap_id}, %Object{actor: actor_ap_id})
       when user_ap_id == actor_ap_id do
    {:error, :own_poll}
  end

  defp validate_not_own_poll(_user, _question), do: :ok

  defp validate_not_already_voted(%User{} = user, %Object{} = question) do
    if Polls.voted?(question, user) do
      {:error, :already_voted}
    else
      :ok
    end
  end

  defp validate_poll_not_expired(%Object{data: data}) do
    closed = Map.get(data, "closed") || Map.get(data, "endTime")

    case closed do
      nil ->
        :ok

      closed when is_binary(closed) ->
        case DateTime.from_iso8601(closed) do
          {:ok, closed_dt, _} ->
            if DateTime.compare(closed_dt, DateTime.utc_now()) == :lt do
              {:error, :poll_expired}
            else
              :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp get_poll_options(%Object{data: data}) do
    one_of = Map.get(data, "oneOf") |> List.wrap()
    any_of = Map.get(data, "anyOf") |> List.wrap()

    cond do
      any_of != [] -> {:ok, any_of, true}
      one_of != [] -> {:ok, one_of, false}
      true -> {:error, :no_options}
    end
  end

  defp validate_choices(choices, options, multiple?) do
    choices =
      choices
      |> Enum.map(&to_integer/1)
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    cond do
      choices == [] ->
        {:error, :invalid_choice}

      not multiple? and length(choices) > 1 ->
        {:error, :multiple_choices_not_allowed}

      Enum.any?(choices, fn idx -> idx < 0 or idx >= length(options) end) ->
        {:error, :invalid_choice}

      true ->
        :ok
    end
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_integer(_value), do: nil

  defp create_vote_answers(user, question, options, choices) do
    choices =
      choices
      |> Enum.map(&to_integer/1)
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    results =
      Enum.map(choices, fn idx ->
        option = Enum.at(options, idx)
        option_name = Map.get(option, "name", "")
        create_single_vote(user, question, option_name)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, answer} -> answer end)}
    else
      List.first(errors)
    end
  end

  defp create_single_vote(%User{} = user, %Object{} = question, option_name)
       when is_binary(option_name) do
    answer_id = URL.absolute("/objects/" <> Ecto.UUID.generate())

    answer = %{
      "id" => answer_id,
      "type" => Answer.type(),
      "actor" => user.ap_id,
      "attributedTo" => user.ap_id,
      "name" => option_name,
      "inReplyTo" => question.ap_id,
      "to" => [],
      "cc" => [question.actor],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    answer =
      case Map.get(question.data, "context") do
        context when is_binary(context) and context != "" -> Map.put(answer, "context", context)
        _ -> answer
      end

    create = Create.build(user, answer)

    Pipeline.ingest(create, local: true)
  end

  defp maybe_put_attachments(question, attachments)
       when is_map(question) and is_list(attachments) do
    if attachments == [] do
      question
    else
      Map.put(question, "attachment", attachments)
    end
  end

  defp maybe_put_attachments(question, _attachments), do: question

  defp maybe_put_in_reply_to(question, nil), do: question

  defp maybe_put_in_reply_to(question, in_reply_to)
       when is_map(question) and is_binary(in_reply_to) do
    Map.put(question, "inReplyTo", in_reply_to)
  end

  defp maybe_put_in_reply_to(question, _in_reply_to), do: question

  defp maybe_put_visibility(question, visibility, actor, mention_recipients)
       when is_map(question) and is_binary(visibility) and is_binary(actor) do
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

    question
    |> Map.put("to", to)
    |> Map.put("cc", cc)
  end

  defp maybe_put_visibility(question, _visibility, _actor, _direct_recipients), do: question

  defp maybe_put_tags(question, tags) when is_map(question) and is_list(tags) do
    tags =
      tags
      |> Enum.filter(&is_map/1)
      |> Enum.uniq_by(fn tag ->
        Map.get(tag, "href") || Map.get(tag, "id") || Map.get(tag, "name") || tag
      end)

    if tags == [] do
      question
    else
      existing =
        question
        |> Map.get("tag", [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)

      Map.put(question, "tag", Enum.uniq_by(existing ++ tags, &(Map.get(&1, "href") || &1)))
    end
  end

  defp maybe_put_tags(question, _tags), do: question

  defp maybe_put_summary(question, value) when is_map(question) and is_binary(value) do
    summary = String.trim(value)

    if summary == "" do
      question
    else
      Map.put(question, "summary", summary)
    end
  end

  defp maybe_put_summary(question, _value), do: question

  defp maybe_put_sensitive(question, value) when is_map(question) do
    case value do
      true -> Map.put(question, "sensitive", true)
      "true" -> Map.put(question, "sensitive", true)
      _ -> question
    end
  end

  defp maybe_put_sensitive(question, _value), do: question

  defp maybe_put_language(question, value) when is_map(question) and is_binary(value) do
    language = String.trim(value)

    if language == "" do
      question
    else
      Map.put(question, "language", language)
    end
  end

  defp maybe_put_language(question, _value), do: question

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
