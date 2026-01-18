defmodule Egregoros.Objects.Polls do
  @moduledoc """
  Poll (Question) specific object operations.

  Handles vote counting and poll-specific queries for ActivityPub Question objects.
  """

  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Repo

  @doc """
  Increases the vote count for a poll option on a Question object.

  Finds the Question by `ap_id`, increments the `replies.totalItems` count
  for the matching option name, and adds the voter to the `voters` array.

  Returns `{:ok, object}` on success, `:noop` if the Question doesn't exist
  or if the option name doesn't match any option.
  """
  def increase_vote_count(question_ap_id, option_name, voter_ap_id)
      when is_binary(question_ap_id) and is_binary(option_name) and is_binary(voter_ap_id) do
    case Objects.get_by_ap_id(question_ap_id) do
      %Object{type: "Question", data: data} = object when is_map(data) ->
        key = if multiple?(object), do: "anyOf", else: "oneOf"

        case Map.get(data, key) do
          options when is_list(options) and options != [] ->
            do_increase_vote_count(object, key, options, option_name, voter_ap_id)

          _ ->
            :noop
        end

      _ ->
        :noop
    end
  end

  def increase_vote_count(_question_ap_id, _option_name, _voter_ap_id), do: :noop

  @doc """
  Returns true if the poll allows multiple choices (anyOf), false for single choice (oneOf).
  """
  def multiple?(%Object{data: %{"anyOf" => any_of}})
      when is_list(any_of) and any_of != [] do
    true
  end

  def multiple?(_object), do: false

  # Private

  defp do_increase_vote_count(object, key, options, option_name, voter_ap_id) do
    existing_voters = Map.get(object.data, "voters") || []

    # For single-choice polls (oneOf), don't count duplicate votes from same voter
    # For multiple-choice polls (anyOf), we allow voting on multiple options
    # but still prevent voting on the same option twice
    already_voted_on_poll? = voter_ap_id in existing_voters
    is_single_choice? = key == "oneOf"

    if is_single_choice? and already_voted_on_poll? do
      # Voter already voted on this single-choice poll - skip
      :noop
    else
      updated_options =
        Enum.map(options, fn
          %{"name" => ^option_name} = option ->
            current_count =
              option
              |> Map.get("replies", %{})
              |> Map.get("totalItems", 0)

            replies = Map.get(option, "replies", %{})
            updated_replies = Map.put(replies, "totalItems", current_count + 1)
            Map.put(option, "replies", updated_replies)

          option ->
            option
        end)

      if updated_options == options do
        :noop
      else
        voters = Enum.uniq([voter_ap_id | existing_voters])

        updated_data =
          object.data
          |> Map.put(key, updated_options)
          |> Map.put("voters", voters)

        object
        |> Object.changeset(%{data: updated_data})
        |> Repo.update()
      end
    end
  end
end
