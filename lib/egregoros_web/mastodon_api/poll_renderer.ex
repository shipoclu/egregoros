defmodule EgregorosWeb.MastodonAPI.PollRenderer do
  @moduledoc """
  Renders poll (Question) objects for the Mastodon API.

  The Poll entity format follows the Mastodon API specification:
  https://docs.joinmastodon.org/entities/Poll/
  """

  alias Egregoros.Object
  alias Egregoros.User

  @doc """
  Renders a Question object as a Mastodon Poll entity.

  ## Parameters
  - `object` - The Question object to render
  - `current_user` - The current user (or nil for anonymous)

  ## Returns
  A map conforming to the Mastodon Poll entity specification.
  """
  def render(%Object{type: "Question", data: data} = object, current_user) when is_map(data) do
    one_of = Map.get(data, "oneOf") |> List.wrap()
    any_of = Map.get(data, "anyOf") |> List.wrap()
    voters = Map.get(data, "voters") || []

    {options, multiple} =
      cond do
        any_of != [] -> {any_of, true}
        one_of != [] -> {one_of, false}
        true -> {[], false}
      end

    rendered_options = Enum.with_index(options, &render_option/2)
    votes_count = Enum.reduce(rendered_options, 0, fn opt, acc -> acc + opt["votes_count"] end)
    expires_at = parse_expiry(data)
    expired = expired?(expires_at)

    own_votes = own_votes(options, current_user, object.actor)
    voted = voted?(voters, current_user)

    %{
      "id" => Integer.to_string(object.id),
      "expires_at" => format_datetime(expires_at),
      "expired" => expired,
      "multiple" => multiple,
      "votes_count" => votes_count,
      "voters_count" => length(voters),
      "options" => rendered_options,
      "emojis" => [],
      "voted" => voted,
      "own_votes" => own_votes
    }
  end

  def render(_object, _current_user), do: nil

  defp render_option(option, index) when is_map(option) do
    name = Map.get(option, "name", "")

    votes_count =
      option
      |> Map.get("replies", %{})
      |> Map.get("totalItems", 0)

    votes_count = if is_integer(votes_count), do: votes_count, else: 0

    %{
      "title" => name,
      "votes_count" => votes_count,
      "index" => index
    }
  end

  defp render_option(_option, index) do
    %{
      "title" => "",
      "votes_count" => 0,
      "index" => index
    }
  end

  defp parse_expiry(%{"closed" => closed}) when is_binary(closed) do
    case DateTime.from_iso8601(closed) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_expiry(%{"endTime" => end_time}) when is_binary(end_time) do
    case DateTime.from_iso8601(end_time) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_expiry(_data), do: nil

  defp expired?(nil), do: false

  defp expired?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp voted?(_voters, nil), do: false

  defp voted?(voters, %User{ap_id: user_ap_id}) when is_list(voters) and is_binary(user_ap_id) do
    user_ap_id in voters
  end

  defp voted?(_voters, _current_user), do: false

  defp own_votes(_options, nil, _poll_actor), do: []

  defp own_votes(_options, %User{ap_id: user_ap_id}, poll_actor)
       when user_ap_id == poll_actor do
    # Poll owner doesn't vote on their own poll
    []
  end

  defp own_votes(_options, _current_user, _poll_actor) do
    # TODO: Track which specific options the user voted for
    # For now, we don't store this information, so return empty
    []
  end
end
