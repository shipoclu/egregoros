defmodule Egregoros.Publish.Polls do
  @moduledoc """
  Poll (Question) specific publish operations.

  Handles voting and poll-specific actions for ActivityPub Question objects.
  """

  alias Egregoros.Activities.Answer
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Objects.Polls
  alias Egregoros.Pipeline
  alias Egregoros.User
  alias EgregorosWeb.URL

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

  # Private functions

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
      "to" => [question.actor],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Pipeline.ingest(answer, local: true)
  end
end
