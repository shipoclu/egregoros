defmodule Egregoros.Federation.ActorDiscovery do
  @moduledoc false

  alias Egregoros.Users
  alias Egregoros.RateLimiter
  alias Egregoros.Workers.FetchActor

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @recipient_keys ~w(to cc bto bcc audience)
  @max_actor_ids 50
  @domain_limit 60
  @domain_interval_ms 60_000

  def enqueue(activity, opts \\ [])

  def enqueue(%{} = activity, opts) when is_list(opts) do
    if Keyword.get(opts, :local, true) do
      :ok
    else
      actor_ids = actor_ids(activity)

      with :ok <- validate_fan_out(actor_ids),
           :ok <- reserve_domain_budgets(actor_ids) do
        Enum.each(actor_ids, &enqueue_actor/1)
        :ok
      end
    end
  end

  def enqueue(_activity, _opts), do: :ok

  def actor_ids(%{} = activity) do
    activity
    |> collect_actor_ids()
    |> Enum.uniq()
  end

  def actor_ids(_activity), do: []

  defp collect_actor_ids(%{} = activity) do
    []
    |> collect_id(activity["actor"])
    |> collect_id(activity["attributedTo"])
    |> collect_id(activity["issuer"])
    |> collect_recipients(activity)
    |> collect_tags(activity["tag"])
  end

  defp collect_id(ids, value) when is_list(value) do
    Enum.reduce(value, ids, &collect_id(&2, &1))
  end

  defp collect_id(ids, %{"id" => id}) when is_binary(id), do: [id | ids]
  defp collect_id(ids, %{"href" => href}) when is_binary(href), do: [href | ids]
  defp collect_id(ids, id) when is_binary(id), do: [id | ids]
  defp collect_id(ids, _value), do: ids

  defp collect_recipients(ids, %{} = activity) do
    Enum.reduce(@recipient_keys, ids, fn key, acc ->
      activity
      |> Map.get(key)
      |> List.wrap()
      |> Enum.reduce(acc, fn recipient, acc ->
        case recipient_id(recipient) do
          nil -> acc
          ap_id -> [ap_id | acc]
        end
      end)
    end)
  end

  defp collect_recipients(ids, _activity), do: ids

  defp recipient_id(%{"id" => id}) when is_binary(id), do: recipient_id(id)
  defp recipient_id(%{"href" => href}) when is_binary(href), do: recipient_id(href)

  defp recipient_id(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" -> nil
      id == @as_public -> nil
      String.ends_with?(id, "/followers") -> nil
      true -> id
    end
  end

  defp recipient_id(_), do: nil

  defp collect_tags(ids, tags) do
    tags
    |> List.wrap()
    |> Enum.reduce(ids, fn
      %{"type" => "Mention", "href" => href}, acc when is_binary(href) ->
        [href | acc]

      %{"type" => "Mention", "id" => id}, acc when is_binary(id) ->
        [id | acc]

      _tag, acc ->
        acc
    end)
  end

  defp enqueue_actor(ap_id) when is_binary(ap_id) do
    ap_id = String.trim(ap_id)

    cond do
      ap_id == "" ->
        :ok

      not String.starts_with?(ap_id, ["http://", "https://"]) ->
        :ok

      Users.get_by_ap_id(ap_id) ->
        :ok

      true ->
        _ = Oban.insert(FetchActor.new(%{"ap_id" => ap_id}))
        :ok
    end
  end

  defp enqueue_actor(_), do: :ok

  defp validate_fan_out(actor_ids) when length(actor_ids) <= @max_actor_ids, do: :ok
  defp validate_fan_out(_actor_ids), do: {:error, :actor_discovery_limit}

  defp reserve_domain_budgets(actor_ids) do
    actor_ids
    |> Enum.flat_map(fn actor_id ->
      case URI.parse(actor_id) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          [String.downcase(host)]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn domain, :ok ->
      case RateLimiter.allow?(
             :actor_discovery_domain,
             domain,
             @domain_limit,
             @domain_interval_ms
           ) do
        :ok -> {:cont, :ok}
        {:error, :rate_limited} = error -> {:halt, error}
      end
    end)
  end
end
