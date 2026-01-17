defmodule Egregoros.Workers.RefreshRemoteFollowingGraph do
  use Oban.Worker,
    queue: :federation_incoming,
    max_attempts: 3,
    unique: [period: 60 * 60, keys: [:ap_id]]

  import Ecto.Query, only: [from: 2]

  alias Egregoros.Federation.SignedFetch
  alias Egregoros.Relationship
  alias Egregoros.Repo
  alias Egregoros.SafeURL
  alias Egregoros.Workers.FetchActor

  @accept "application/activity+json, application/ld+json"
  @relationship_type "GraphFollow"
  @default_max_pages 2
  @default_max_items 200
  @max_pages_limit 10
  @max_items_limit 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ap_id" => ap_id} = args}) when is_binary(ap_id) do
    max_pages =
      args
      |> Map.get("max_pages", @default_max_pages)
      |> normalize_max_pages()

    max_items =
      args
      |> Map.get("max_items", @default_max_items)
      |> normalize_max_items()

    ap_id = ap_id |> to_string() |> String.trim()

    with true <- ap_id != "",
         :ok <- SafeURL.validate_http_url(ap_id),
         {:ok, actor} <- fetch_json(ap_id),
         following_url when is_binary(following_url) <- following_url(actor, ap_id),
         following_url <- String.trim(following_url),
         true <- following_url != "" do
      actor_ids =
        following_url
        |> fetch_actor_ids(max_pages, max_items)
        |> Enum.filter(&safe_http_url?/1)

      _ = refresh_graph_relationships(ap_id, actor_ids)
      _ = enqueue_actor_fetches(actor_ids)

      :ok
    else
      false ->
        :ok

      {:error, {:http_status, status}} when status in [401, 403, 404, 410] ->
        :ok

      {:error, :unsafe_url} ->
        :ok

      {:error, :invalid_json} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      _ ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  defp enqueue_actor_fetches(ap_ids) when is_list(ap_ids) do
    Enum.each(ap_ids, fn ap_id ->
      _ = Oban.insert(FetchActor.new(%{"ap_id" => ap_id}))
    end)

    :ok
  end

  defp enqueue_actor_fetches(_ap_ids), do: :ok

  defp refresh_graph_relationships(actor_ap_id, actor_ids)
       when is_binary(actor_ap_id) and is_list(actor_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    actor_ids =
      actor_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Repo.transaction(fn ->
      from(r in Relationship,
        where: r.type == ^@relationship_type and r.actor == ^actor_ap_id
      )
      |> Repo.delete_all()

      if actor_ids != [] do
        rows =
          Enum.map(actor_ids, fn object_ap_id ->
            %{
              type: @relationship_type,
              actor: actor_ap_id,
              object: object_ap_id,
              inserted_at: now,
              updated_at: now
            }
          end)

        _ = Repo.insert_all(Relationship, rows, on_conflict: :nothing)
      end
    end)

    :ok
  end

  defp refresh_graph_relationships(_actor_ap_id, _actor_ids), do: :ok

  defp fetch_actor_ids(url, max_pages, max_items)
       when is_binary(url) and is_integer(max_pages) and max_pages > 0 and is_integer(max_items) and
              max_items > 0 do
    url = String.trim(url)

    if url == "" do
      []
    else
      url
      |> fetch_pages(max_pages, max_items, MapSet.new(), [])
      |> Enum.uniq()
    end
  end

  defp fetch_actor_ids(_url, _max_pages, _max_items), do: []

  defp fetch_pages(url, pages_left, items_left, visited, acc)
       when is_binary(url) and is_integer(pages_left) and pages_left > 0 and
              is_integer(items_left) and
              items_left > 0 and is_map(visited) and is_list(acc) do
    url = String.trim(url)

    cond do
      url == "" ->
        acc

      MapSet.member?(visited, url) ->
        acc

      true ->
        visited = MapSet.put(visited, url)

        case fetch_json(url) do
          {:ok, %{} = json} ->
            {items, next_url} = collection_items_and_next(json)
            {items, remaining} = take_items(items, items_left)

            acc =
              items
              |> Enum.map(&extract_actor_id/1)
              |> Enum.filter(&is_binary/1)
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))
              |> Kernel.++(acc)

            next_url = normalize_binary(next_url)

            if next_url == "" or remaining <= 0 do
              acc
            else
              fetch_pages(next_url, pages_left - 1, remaining, visited, acc)
            end

          {:error, {:http_status, status}} when status in [401, 403, 404, 410] ->
            acc

          {:error, :unsafe_url} ->
            acc

          {:error, :invalid_json} ->
            acc

          _ ->
            acc
        end
    end
  end

  defp fetch_pages(_url, _pages_left, _items_left, _visited, acc), do: acc

  defp fetch_json(url) when is_binary(url) do
    case SignedFetch.get(url, accept: @accept) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_json(body)

      {:ok, %{status: status}} when is_integer(status) ->
        {:error, {:http_status, status}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :fetch_failed}
    end
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_json(_body), do: {:error, :invalid_json}

  defp collection_items_and_next(%{} = json) do
    items =
      json
      |> Map.get("orderedItems") ||
        Map.get(json, "items") ||
        []
        |> List.wrap()

    next =
      json
      |> Map.get("next")
      |> extract_link()

    first =
      json
      |> Map.get("first")
      |> extract_link()

    cond do
      items != [] ->
        {items, next}

      is_binary(first) ->
        {[], first}

      true ->
        {[], nil}
    end
  end

  defp extract_link(value) when is_binary(value), do: value
  defp extract_link(%{"id" => id}) when is_binary(id), do: id
  defp extract_link(%{"href" => href}) when is_binary(href), do: href
  defp extract_link(%{id: id}) when is_binary(id), do: id
  defp extract_link(%{href: href}) when is_binary(href), do: href
  defp extract_link(_), do: nil

  defp take_items(items, limit) when is_list(items) and is_integer(limit) and limit > 0 do
    {Enum.take(items, limit), limit - min(length(items), limit)}
  end

  defp take_items(_items, _limit), do: {[], 0}

  defp extract_actor_id(value) when is_binary(value), do: value
  defp extract_actor_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_actor_id(%{"href" => href}) when is_binary(href), do: href
  defp extract_actor_id(%{"url" => url}), do: extract_actor_id(url)
  defp extract_actor_id(%{id: id}) when is_binary(id), do: id
  defp extract_actor_id(%{href: href}) when is_binary(href), do: href
  defp extract_actor_id(%{url: url}), do: extract_actor_id(url)
  defp extract_actor_id(_value), do: nil

  defp normalize_binary(nil), do: ""

  defp normalize_binary(value) when is_binary(value) do
    value
    |> String.trim()
  end

  defp normalize_binary(_value), do: ""

  defp following_url(%{} = actor, base_url) when is_binary(base_url) do
    actor
    |> Map.get("following")
    |> extract_link()
    |> resolve_url(base_url)
  end

  defp following_url(_actor, _base_url), do: nil

  defp resolve_url(nil, _base), do: nil

  defp resolve_url(url, base) when is_binary(url) and is_binary(base) do
    url = String.trim(url)

    cond do
      url == "" ->
        nil

      String.starts_with?(url, ["http://", "https://"]) ->
        url

      true ->
        case URI.parse(base) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            base
            |> URI.merge(url)
            |> URI.to_string()

          _ ->
            nil
        end
    end
  end

  defp resolve_url(_url, _base), do: nil

  defp safe_http_url?(url) when is_binary(url) do
    case SafeURL.validate_http_url(url) do
      :ok -> true
      _ -> false
    end
  end

  defp safe_http_url?(_url), do: false

  defp normalize_max_pages(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_pages_limit)
  end

  defp normalize_max_pages(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> normalize_max_pages(int)
      _ -> @default_max_pages
    end
  end

  defp normalize_max_pages(_value), do: @default_max_pages

  defp normalize_max_items(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_items_limit)
  end

  defp normalize_max_items(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> normalize_max_items(int)
      _ -> @default_max_items
    end
  end

  defp normalize_max_items(_value), do: @default_max_items
end
