defmodule EgregorosWeb.MastodonAPI.FollowedTagsController do
  use EgregorosWeb, :controller

  alias Egregoros.Relationships
  alias Egregoros.User
  alias EgregorosWeb.URL

  @default_limit 20
  @max_limit 80
  @relationship_type "FollowTag"

  def index(conn, params) do
    %User{ap_id: actor_ap_id} = conn.assigns.current_user
    limit = params |> Map.get("limit") |> parse_limit()

    tags =
      Relationships.list_by_type_actor(@relationship_type, actor_ap_id, limit: limit)
      |> Enum.map(&normalize_hashtag(&1.object))
      |> uniq()
      |> Enum.filter(&valid_hashtag?/1)
      |> Enum.map(&render_tag/1)

    json(conn, tags)
  end

  defp render_tag(name) when is_binary(name) do
    %{
      "id" => name,
      "name" => name,
      "url" => URL.absolute("/tags/" <> name),
      "history" => [
        %{
          "day" => today_unix_day(),
          "accounts" => "0",
          "uses" => "0"
        }
      ],
      "following" => true,
      "featuring" => false
    }
  end

  defp uniq(entries) when is_list(entries) do
    {list, _seen} =
      Enum.reduce(entries, {[], MapSet.new()}, fn entry, {acc, seen} ->
        if MapSet.member?(seen, entry) do
          {acc, seen}
        else
          {[entry | acc], MapSet.put(seen, entry)}
        end
      end)

    Enum.reverse(list)
  end

  defp uniq(_entries), do: []

  defp normalize_hashtag(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
  end

  defp normalize_hashtag(_name), do: ""

  defp valid_hashtag?(tag) when is_binary(tag) do
    Regex.match?(~r/^[\p{L}\p{N}_][\p{L}\p{N}_-]{0,63}$/u, tag)
  end

  defp valid_hashtag?(_tag), do: false

  defp today_unix_day do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
    |> Integer.to_string()
  end

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_limit)
  end

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> parse_limit(int)
      _ -> @default_limit
    end
  end

  defp parse_limit(_value), do: @default_limit
end
