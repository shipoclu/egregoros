defmodule Egregoros.Objects.Polls do
  @moduledoc """
  Poll (Question) specific object operations.

  Handles vote counting and poll-specific queries for ActivityPub Question objects.
  """

  import Ecto.Query

  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Repo
  alias Egregoros.User

  @doc """
  Increases the vote count for a poll option on a Question object.

  Finds the Question by `ap_id`, increments the `replies.totalItems` count
  for the matching option name, and records voter metadata in the object's internal state.

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

  @doc """
  Returns the poll option list (Question's `oneOf` or `anyOf`).
  """
  def options(%Object{type: "Question", data: %{} = data}) do
    case poll_choice_key(data) do
      "anyOf" -> Map.get(data, "anyOf") |> List.wrap()
      "oneOf" -> Map.get(data, "oneOf") |> List.wrap()
      _ -> []
    end
  end

  def options(_object), do: []

  @doc """
  Returns the poll closing time (parsed DateTime) if present.

  Accepts both `closed` and `endTime` fields.
  """
  def closed_at(%Object{type: "Question", data: %{} = data}) do
    data
    |> Map.get("closed")
    |> case do
      value when is_binary(value) -> value
      _ -> Map.get(data, "endTime")
    end
    |> parse_datetime()
  end

  def closed_at(_object), do: nil

  @doc """
  Returns true if the given user has already voted on the poll.
  """
  def voted?(%Object{type: "Question", ap_id: ap_id}, %User{ap_id: voter_ap_id})
      when is_binary(ap_id) and is_binary(voter_ap_id) do
    Objects.get_by_type_actor_object("Answer", voter_ap_id, ap_id) != nil
  end

  def voted?(_poll, _user), do: false

  @doc """
  Returns Answer objects for the given poll and user.
  """
  def list_votes(%Object{type: "Question", ap_id: ap_id}, %User{ap_id: voter_ap_id})
      when is_binary(ap_id) and is_binary(voter_ap_id) do
    from(o in Object,
      where: o.type == "Answer" and o.actor == ^voter_ap_id and o.object == ^ap_id,
      order_by: [asc: o.inserted_at, asc: o.id]
    )
    |> Repo.all()
  end

  def list_votes(_poll, _user), do: []

  @doc """
  Updates poll option counts from a remote Question object.

  Only updates counts when the incoming poll options match the existing options
  (ignoring reply counts). Preserves internal state and other fields.
  """
  def update_from_remote(%Object{type: "Question", data: data} = object, %{} = incoming)
      when is_map(data) do
    key = poll_choice_key(data)
    incoming_key = poll_choice_key(incoming)

    with key when is_binary(key) <- key,
         ^key <- incoming_key,
         existing_options when is_list(existing_options) <- Map.get(data, key),
         incoming_options when is_list(incoming_options) <- Map.get(incoming, key),
         true <- options_match?(existing_options, incoming_options) do
      updated_options = merge_option_counts(existing_options, incoming_options)

      updated_data =
        data
        |> Map.put(key, updated_options)
        |> maybe_put_voters_count(incoming)

      object
      |> Object.changeset(%{data: updated_data})
      |> Repo.update()
    else
      _ -> :noop
    end
  end

  def update_from_remote(_object, _incoming), do: :noop

  # Private

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp poll_choice_key(%{"anyOf" => any_of}) when is_list(any_of) and any_of != [], do: "anyOf"
  defp poll_choice_key(%{"oneOf" => one_of}) when is_list(one_of) and one_of != [], do: "oneOf"
  defp poll_choice_key(_data), do: nil

  defp maybe_put_voters_count(%{} = data, %{} = incoming) do
    case Map.get(incoming, "votersCount") do
      count when is_integer(count) and count >= 0 -> Map.put(data, "votersCount", count)
      _ -> data
    end
  end

  defp maybe_put_voters_count(data, _incoming), do: data

  defp options_match?(existing_options, incoming_options)
       when is_list(existing_options) and is_list(incoming_options) do
    normalize_option = fn
      %{} = option ->
        Map.drop(option, ["replies", "egregoros:voters"])

      _ ->
        :invalid
    end

    Enum.map(existing_options, normalize_option) ==
      Enum.map(incoming_options, normalize_option)
  end

  defp options_match?(_existing_options, _incoming_options), do: false

  defp merge_option_counts(existing_options, incoming_options) do
    Enum.zip(existing_options, incoming_options)
    |> Enum.map(fn {existing, incoming} -> update_option_count(existing, incoming) end)
  end

  defp update_option_count(%{} = existing, %{} = incoming) do
    existing = Map.delete(existing, "egregoros:voters")

    incoming_total =
      incoming
      |> Map.get("replies", %{})
      |> Map.get("totalItems")

    if is_integer(incoming_total) do
      replies = Map.get(existing, "replies", %{})
      updated_replies = Map.put(replies, "totalItems", incoming_total)
      Map.put(existing, "replies", updated_replies)
    else
      existing
    end
  end

  defp update_option_count(existing, _incoming), do: existing

  defp do_increase_vote_count(object, key, options, option_name, voter_ap_id) do
    poll_internal = poll_internal(object)
    existing_voters = Map.get(poll_internal, "voters", [])

    option_voters_by_name = Map.get(poll_internal, "option_voters", %{})

    # For single-choice polls (oneOf), don't count duplicate votes from same voter.
    # For multiple-choice polls (anyOf), allow voting on multiple options but prevent
    # voting on the same option twice.
    already_voted_on_poll? = voter_ap_id in existing_voters
    is_single_choice? = key == "oneOf"

    if is_single_choice? and already_voted_on_poll? do
      # Voter already voted on this single-choice poll - skip
      :noop
    else
      updated_options =
        Enum.map(options, fn
          %{"name" => ^option_name} = option ->
            option = Map.delete(option, "egregoros:voters")

            existing_option_voters =
              option_voters_by_name
              |> Map.get(option_name, [])
              |> List.wrap()

            if key == "anyOf" and voter_ap_id in existing_option_voters do
              option
            else
              current_count =
                option
                |> Map.get("replies", %{})
                |> Map.get("totalItems", 0)

              replies = Map.get(option, "replies", %{})
              updated_replies = Map.put(replies, "totalItems", current_count + 1)

              Map.put(option, "replies", updated_replies)
            end

          option ->
            Map.delete(option, "egregoros:voters")
        end)

      if updated_options == options do
        :noop
      else
        voters = Enum.uniq([voter_ap_id | existing_voters])

        option_voters_by_name =
          case key do
            "anyOf" ->
              existing =
                option_voters_by_name
                |> Map.get(option_name, [])
                |> List.wrap()

              Map.put(option_voters_by_name, option_name, Enum.uniq([voter_ap_id | existing]))

            _ ->
              option_voters_by_name
          end

        updated_internal =
          object
          |> Map.get(:internal, %{})
          |> ensure_map()
          |> Map.put("poll", %{
            "voters" => voters,
            "option_voters" => option_voters_by_name
          })

        updated_data =
          object.data
          |> Map.put(key, updated_options)

        object
        |> Object.changeset(%{data: updated_data, internal: updated_internal})
        |> Repo.update()
      end
    end
  end

  def voters_count(%Object{type: "Question", local: false, data: %{} = data} = object) do
    case Map.get(data, "votersCount") do
      count when is_integer(count) and count >= 0 ->
        count

      _ ->
        voters_count_from_internal(object)
    end
  end

  def voters_count(%Object{type: "Question"} = object) do
    voters_count_from_internal(object)
  end

  def voters_count(_object), do: 0

  defp voters_count_from_internal(%Object{} = object) do
    poll_internal = poll_internal(object)
    voters = Map.get(poll_internal, "voters", []) |> List.wrap()
    length(voters)
  end

  defp poll_internal(%Object{} = object) do
    object
    |> Map.get(:internal, %{})
    |> ensure_map()
    |> Map.get("poll", %{})
    |> ensure_map()
  end

  defp ensure_map(%{} = value), do: value
  defp ensure_map(_value), do: %{}
end
