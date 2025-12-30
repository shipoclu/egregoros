defmodule EgregorosWeb.MastodonAPI.TagsController do
  use EgregorosWeb, :controller

  import Ecto.Query

  alias Egregoros.Object
  alias Egregoros.Repo
  alias EgregorosWeb.URL

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @history_days 7

  def show(conn, %{"name" => name}) do
    name =
      name
      |> to_string()
      |> normalize_hashtag()

    if valid_hashtag?(name) do
      tag =
        %{
          "id" => name,
          "name" => name,
          "url" => URL.absolute("/tags/" <> name),
          "history" => tag_history(name)
        }
        |> maybe_add_relationship_fields(conn)

      json(conn, tag)
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  defp maybe_add_relationship_fields(tag, %{assigns: %{current_user: nil}}), do: tag

  defp maybe_add_relationship_fields(tag, _conn) do
    Map.merge(tag, %{"following" => false, "featuring" => false})
  end

  defp tag_history(name) when is_binary(name) do
    tag_name = "#" <> name
    match = [%{"type" => "Hashtag", "name" => tag_name}]

    today = Date.utc_today()
    start_date = Date.add(today, -(@history_days - 1))
    start_dt = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")

    rows =
      from(o in Object,
        where: o.type == "Note",
        where: fragment("? @> ?", o.data, ^%{"to" => [@as_public]}),
        where: fragment("coalesce(?->'tag', '[]'::jsonb) @> ?", o.data, ^match),
        where: fragment("coalesce(?, ?) >= ?", o.published, o.inserted_at, ^start_dt),
        group_by: fragment("date_trunc('day', coalesce(?, ?))", o.published, o.inserted_at),
        select: {
          fragment("date_trunc('day', coalesce(?, ?))", o.published, o.inserted_at),
          count(o.id),
          count(o.actor, :distinct)
        }
      )
      |> Repo.all()

    counts_by_date =
      Enum.reduce(rows, %{}, fn {day, uses, accounts}, acc ->
        case date_from_db(day) do
          %Date{} = date -> Map.put(acc, date, %{uses: uses, accounts: accounts})
          _ -> acc
        end
      end)

    start_date
    |> Date.range(today)
    |> Enum.map(fn date ->
      counts = Map.get(counts_by_date, date, %{uses: 0, accounts: 0})

      %{
        "day" => unix_day(date),
        "accounts" => counts.accounts |> Integer.to_string(),
        "uses" => counts.uses |> Integer.to_string()
      }
    end)
  end

  defp tag_history(_name), do: []

  defp unix_day(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
    |> Integer.to_string()
  end

  defp unix_day(_date), do: "0"

  defp date_from_db(%NaiveDateTime{} = naive), do: NaiveDateTime.to_date(naive)
  defp date_from_db(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp date_from_db(%Date{} = date), do: date
  defp date_from_db(_value), do: nil

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
end
