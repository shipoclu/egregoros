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

    json(conn, %{"accounts" => accounts, "statuses" => statuses, "hashtags" => []})
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
