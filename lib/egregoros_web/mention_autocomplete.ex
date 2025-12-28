defmodule EgregorosWeb.MentionAutocomplete do
  @moduledoc false

  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.URL
  alias EgregorosWeb.ViewModels.Actor, as: ActorVM

  def suggestions(query, opts \\ [])

  def suggestions(query, opts) when is_binary(query) and is_list(opts) do
    query =
      query
      |> String.trim()
      |> String.trim_leading("@")

    limit = opts |> Keyword.get(:limit, 8) |> normalize_limit()

    if query == "" do
      []
    else
      query
      |> Users.search_mentions(limit: limit)
      |> Enum.map(&to_suggestion/1)
    end
  end

  def suggestions(_query, _opts), do: []

  def to_suggestion(%User{} = user) do
    %{
      id: user.id,
      ap_id: user.ap_id,
      nickname: user.nickname,
      display_name: user.name || user.nickname || user.ap_id,
      handle: ActorVM.handle(user, user.ap_id),
      avatar_url: URL.absolute(user.avatar_url, user.ap_id),
      emojis: Map.get(user, :emojis, []),
      local?: user.local
    }
  end

  defp normalize_limit(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(20)
  end

  defp normalize_limit(_limit), do: 8
end
