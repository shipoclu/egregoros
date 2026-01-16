defmodule EgregorosWeb.MastodonAPI.SearchController do
  use EgregorosWeb, :controller

  alias Egregoros.Domain
  alias Egregoros.Federation.Actor
  alias Egregoros.Federation.WebFinger
  alias Egregoros.Handles
  alias Egregoros.Objects
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint
  alias EgregorosWeb.MastodonAPI.AccountRenderer
  alias EgregorosWeb.MastodonAPI.StatusRenderer
  alias EgregorosWeb.URL

  def index(conn, params) do
    q = params |> Map.get("q", "") |> to_string() |> String.trim()
    resolve? = Map.get(params, "resolve") in [true, "true"]
    limit = params |> Map.get("limit") |> parse_limit()

    current_user = conn.assigns[:current_user]

    accounts =
      q
      |> search_accounts(resolve?, limit, current_user)
      |> Enum.map(&AccountRenderer.render_account/1)

    statuses =
      q
      |> Objects.search_visible_notes(current_user, limit: limit)
      |> StatusRenderer.render_statuses(current_user)

    hashtags = search_hashtags(q, limit)

    json(conn, %{"accounts" => accounts, "statuses" => statuses, "hashtags" => hashtags})
  end

  @hashtag_sample_size 200

  defp search_hashtags(q, limit) when is_binary(q) and is_integer(limit) do
    tag_query =
      q
      |> to_string()
      |> String.trim()
      |> normalize_hashtag()

    cond do
      tag_query == "" ->
        []

      String.contains?(q, "@") ->
        []

      String.contains?(q, " ") ->
        []

      not valid_hashtag?(tag_query) ->
        []

      true ->
        Objects.list_public_notes(limit: @hashtag_sample_size)
        |> Enum.reduce(%{}, &count_hashtags/2)
        |> Enum.filter(fn {name, _info} -> String.starts_with?(name, tag_query) end)
        |> Enum.map(fn {name, info} ->
          %{
            "name" => name,
            "url" => URL.absolute("/tags/" <> name),
            "history" => [
              %{
                "day" => today_unix_day(),
                "accounts" => Integer.to_string(info.accounts |> MapSet.size()),
                "uses" => Integer.to_string(info.uses)
              }
            ]
          }
        end)
        |> Enum.sort_by(fn tag ->
          {-String.to_integer(tag["history"] |> hd() |> Map.get("uses")), tag["name"]}
        end)
        |> Enum.take(limit)
    end
  end

  defp search_hashtags(_q, _limit), do: []

  defp count_hashtags(object, acc) do
    actor = Map.get(object, :actor)

    hashtags = hashtags_from_activity_tags(object)

    Enum.reduce(hashtags, acc, fn hashtag, counts ->
      Map.update(
        counts,
        hashtag,
        %{uses: 1, accounts: MapSet.new(List.wrap(actor))},
        fn existing ->
          %{
            uses: existing.uses + 1,
            accounts: MapSet.union(existing.accounts, MapSet.new(List.wrap(actor)))
          }
        end
      )
    end)
  end

  defp hashtags_from_activity_tags(%{data: %{} = data}) do
    data
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(Map.get(&1, "type") == "Hashtag"))
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_hashtag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp hashtags_from_activity_tags(_object), do: []

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

  defp search_accounts("", _resolve?, _limit, _current_user), do: []

  defp search_accounts(q, resolve?, limit, current_user) do
    local_matches = Users.search_mentions(q, limit: limit, current_user: current_user)

    matches =
      if resolve? and String.contains?(q, "@") do
        case resolve_account(q) do
          {:ok, user} -> [user | local_matches]
          _ -> local_matches
        end
      else
        local_matches
      end

    matches
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
  end

  defp resolve_account(q) do
    q =
      q
      |> String.trim()
      |> String.trim_leading("@")

    case Handles.parse_acct(q) do
      {:ok, %{nickname: nickname, domain: nil}} ->
        case Users.get_by_nickname(nickname) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end

      {:ok, %{nickname: nickname, domain: domain}} ->
        if local_domain?(domain) do
          case Users.get_by_nickname(nickname) do
            nil -> {:error, :not_found}
            user -> {:ok, user}
          end
        else
          handle = nickname <> "@" <> domain

          with {:ok, actor_url} <- WebFinger.lookup(handle),
               {:ok, user} <- Actor.fetch_and_store(actor_url) do
            {:ok, user}
          end
        end

      :error ->
        {:error, :invalid_handle}
    end
  end

  defp local_domain?(domain) when is_binary(domain) do
    domain = domain |> String.trim() |> String.downcase()

    local_domains =
      Endpoint.url()
      |> URI.parse()
      |> Domain.aliases_from_uri()

    domain in local_domains
  end

  defp local_domain?(_domain), do: false

  defp parse_limit(nil), do: 20

  defp parse_limit(value) when is_integer(value) do
    value
    |> max(1)
    |> min(40)
  end

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> parse_limit(int)
      _ -> 20
    end
  end

  defp parse_limit(_), do: 20
end
