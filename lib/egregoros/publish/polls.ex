defmodule Egregoros.Publish.Polls do
  @moduledoc """
  Poll (Question) specific publish operations.

  Handles voting and poll-specific actions for ActivityPub Question objects.
  """

  alias Egregoros.Activities.Answer
  alias Egregoros.Activities.Create
  alias Egregoros.HTML
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Objects.Polls
  alias Egregoros.Pipeline
  alias Egregoros.Publish.PostBuilder
  alias Egregoros.User
  alias Egregoros.Workers.ResolveMentions
  alias EgregorosWeb.URL

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
          {mentions, unresolved_remote_mentions} =
            PostBuilder.resolve_mentions(content, user.ap_id)

          reply_mentions = PostBuilder.resolve_reply_mentions(in_reply_to, user.ap_id)

          mentions =
            (mentions ++ reply_mentions)
            |> Enum.filter(&is_map/1)
            |> Enum.uniq_by(& &1.ap_id)

          mention_recipient_ids = Enum.map(mentions, & &1.ap_id)
          mention_tags = Enum.map(mentions, &PostBuilder.mention_tag/1)
          hashtag_tags = PostBuilder.hashtag_tags(content)
          mention_hrefs = PostBuilder.mention_hrefs(mentions)

          content_html = HTML.to_safe_html(content, format: :text, mention_hrefs: mention_hrefs)

          question =
            build_question(user, content, content_html)
            |> Map.merge(poll_data)
            |> PostBuilder.put_attachments(attachments)
            |> PostBuilder.put_in_reply_to(in_reply_to)
            |> PostBuilder.put_visibility(visibility, user.ap_id, mention_recipient_ids)
            |> PostBuilder.put_tags(mention_tags ++ hashtag_tags)
            |> PostBuilder.put_summary(spoiler_text)
            |> PostBuilder.put_sensitive(sensitive)
            |> PostBuilder.put_language(language)

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

  defp validate_poll_not_expired(%Object{} = question) do
    case Polls.closed_at(question) do
      %DateTime{} = closed_dt ->
        if DateTime.compare(closed_dt, DateTime.utc_now()) == :lt do
          {:error, :poll_expired}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp get_poll_options(%Object{} = question) do
    options = Polls.options(question)

    if options == [] do
      {:error, :no_options}
    else
      {:ok, options, Polls.multiple?(question)}
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
      "to" => [question.actor],
      "cc" => [],
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
end
