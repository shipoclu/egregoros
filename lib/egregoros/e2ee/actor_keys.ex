defmodule Egregoros.E2EE.ActorKeys do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Egregoros.Config
  alias Egregoros.E2EE
  alias Egregoros.E2EE.ActorKey
  alias Egregoros.E2EE.Key
  alias Egregoros.Federation.SignedFetch
  alias Egregoros.Federation.WebFinger
  alias Egregoros.HTTP
  alias Egregoros.Repo
  alias Egregoros.SafeURL
  alias Egregoros.User
  alias Egregoros.Users

  @accept "application/activity+json, application/ld+json"
  @default_cache_ttl_seconds 86_400

  def supports_e2ee_dm?(actor_ap_id) when is_binary(actor_ap_id) do
    actor_ap_id = String.trim(actor_ap_id)

    cond do
      actor_ap_id == "" ->
        false

      true ->
        case get_actor_key(actor_ap_id, nil) do
          {:ok, _key} -> true
          _ -> false
        end
    end
  end

  def supports_e2ee_dm?(_actor_ap_id), do: false

  def list_actor_keys(actor_ap_id) when is_binary(actor_ap_id) do
    actor_ap_id = String.trim(actor_ap_id)

    if actor_ap_id == "" do
      {:error, :invalid_payload}
    else
      case Users.get_by_ap_id(actor_ap_id) do
        %User{local: true} = user ->
          keys =
            user
            |> E2EE.list_active_keys()
            |> Enum.map(&local_key_to_map/1)

          {:ok, keys}

        _ ->
          with :ok <- SafeURL.validate_http_url_federation(actor_ap_id) do
            keys = cached_actor_keys(actor_ap_id)

            cond do
              keys != [] and cache_fresh?(actor_ap_id) ->
                {:ok, keys}

              true ->
                with {:ok, :refreshed} <- refresh_actor_keys(actor_ap_id) do
                  {:ok, cached_actor_keys(actor_ap_id)}
                end
            end
          else
            _ -> {:error, :invalid_payload}
          end
      end
    end
  end

  def list_actor_keys(_actor_ap_id), do: {:error, :invalid_payload}

  def get_actor_key(actor_ap_id, kid) when is_binary(actor_ap_id) do
    actor_ap_id = String.trim(actor_ap_id)
    kid = normalize_optional_string(kid)

    if actor_ap_id == "" do
      {:error, :invalid_payload}
    else
      case Users.get_by_ap_id(actor_ap_id) do
        %User{local: true} = user ->
          local_actor_key(user, kid)

        _ ->
          with :ok <- SafeURL.validate_http_url_federation(actor_ap_id) do
            remote_actor_key(actor_ap_id, kid)
          else
            _ -> {:error, :invalid_payload}
          end
      end
    end
  end

  def get_actor_key(_actor_ap_id, _kid), do: {:error, :invalid_payload}

  def resolve_actor_ap_id(%{"actor_ap_id" => actor_ap_id}) when is_binary(actor_ap_id) do
    actor_ap_id = String.trim(actor_ap_id)

    if actor_ap_id == "" do
      {:error, :invalid_payload}
    else
      case Users.get_by_ap_id(actor_ap_id) do
        %User{local: true} ->
          {:ok, actor_ap_id}

        _ ->
          with :ok <- SafeURL.validate_http_url_federation(actor_ap_id) do
            {:ok, actor_ap_id}
          else
            _ -> {:error, :invalid_payload}
          end
      end
    end
  end

  def resolve_actor_ap_id(%{"handle" => handle}) when is_binary(handle) do
    handle = String.trim(handle)

    if handle == "" do
      {:error, :invalid_payload}
    else
      case WebFinger.lookup(handle) do
        {:ok, actor_ap_id} when is_binary(actor_ap_id) ->
          resolve_actor_ap_id(%{"actor_ap_id" => actor_ap_id})

        _ ->
          {:error, :invalid_payload}
      end
    end
  end

  def resolve_actor_ap_id(_params), do: {:error, :invalid_payload}

  def fetch_actor(actor_ap_id) when is_binary(actor_ap_id) do
    headers = [
      {"accept", @accept},
      {"user-agent", "egregoros"}
    ]

    case HTTP.get(actor_ap_id, headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_json(body)

      {:ok, %{status: status}} when status in [401, 403] ->
        fetch_actor_signed(actor_ap_id)

      _ ->
        {:error, :actor_fetch_failed}
    end
  end

  def fetch_actor(_actor_ap_id), do: {:error, :actor_fetch_failed}

  def extract_actor_key(%{} = actor, kid) do
    kid = normalize_optional_string(kid)
    keys = extract_actor_keys(actor)

    selected =
      cond do
        is_binary(kid) ->
          Enum.find(keys, fn entry -> entry["kid"] == kid end)

        true ->
          List.first(keys)
      end

    if is_map(selected), do: {:ok, selected}, else: {:error, :no_e2ee_keys}
  end

  def extract_actor_key(_actor, _kid), do: {:error, :no_e2ee_keys}

  def extract_actor_keys(%{} = actor) do
    actor
    |> get_in(["egregoros:e2ee", "keys"])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.reduce([], fn entry, acc ->
      case entry do
        %{"kid" => kid, "kty" => kty, "crv" => crv, "x" => x, "y" => y} when is_binary(kid) ->
          [
            %{
              "kid" => kid,
              "jwk" => %{"kty" => kty, "crv" => crv, "x" => x, "y" => y},
              "fingerprint" => Map.get(entry, "fingerprint")
            }
            | acc
          ]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  def extract_actor_keys(_actor), do: []

  defp local_actor_key(%User{} = user, kid) do
    keys = E2EE.list_active_keys(user)

    selected =
      cond do
        is_binary(kid) ->
          Enum.find(keys, fn %Key{} = key -> key.kid == kid end)

        true ->
          List.first(keys)
      end

    case selected do
      nil -> {:error, :no_e2ee_keys}
      key -> {:ok, local_key_to_map(key)}
    end
  end

  defp local_actor_key(_user, _kid), do: {:error, :no_e2ee_keys}

  defp local_key_to_map(%Key{} = key) do
    %{
      "kid" => key.kid,
      "jwk" => Map.take(key.public_key_jwk, ["kty", "crv", "x", "y"]),
      "fingerprint" => key.fingerprint
    }
  end

  defp remote_actor_key(actor_ap_id, kid) when is_binary(actor_ap_id) do
    cached = cached_actor_key(actor_ap_id, kid)

    cond do
      is_map(cached) and (is_binary(kid) or cache_fresh?(actor_ap_id)) ->
        {:ok, cached}

      is_map(cached) ->
        with {:ok, :refreshed} <- refresh_actor_keys(actor_ap_id),
             key when is_map(key) <- cached_actor_key(actor_ap_id, kid) do
          {:ok, key}
        else
          nil -> {:error, :no_e2ee_keys}
          {:error, _} = error -> error
        end

      true ->
        with {:ok, :refreshed} <- refresh_actor_keys(actor_ap_id),
             key when is_map(key) <- cached_actor_key(actor_ap_id, kid) do
          {:ok, key}
        else
          nil -> {:error, :no_e2ee_keys}
          {:error, _} = error -> error
        end
    end
  end

  defp remote_actor_key(_actor_ap_id, _kid), do: {:error, :no_e2ee_keys}

  defp cached_actor_key(actor_ap_id, kid) when is_binary(actor_ap_id) do
    cond do
      is_binary(kid) ->
        from(k in ActorKey,
          where: k.actor_ap_id == ^actor_ap_id and k.kid == ^kid,
          limit: 1
        )
        |> Repo.one()
        |> actor_key_to_map()

      true ->
        from(k in ActorKey,
          where: k.actor_ap_id == ^actor_ap_id and k.present,
          order_by: [asc: k.position],
          limit: 1
        )
        |> Repo.one()
        |> actor_key_to_map()
    end
  end

  defp cached_actor_key(_actor_ap_id, _kid), do: nil

  defp cached_actor_keys(actor_ap_id) when is_binary(actor_ap_id) do
    from(k in ActorKey,
      where: k.actor_ap_id == ^actor_ap_id,
      order_by: [desc: k.present, asc: k.position]
    )
    |> Repo.all()
    |> Enum.map(&actor_key_to_map/1)
    |> Enum.reject(&is_nil/1)
  end

  defp cached_actor_keys(_actor_ap_id), do: []

  defp refresh_actor_keys(actor_ap_id) when is_binary(actor_ap_id) do
    with {:ok, actor} <- fetch_actor(actor_ap_id),
         keys when is_list(keys) <- extract_actor_keys(actor),
         true <- keys != [] do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      _ =
        Repo.transaction(fn ->
          from(k in ActorKey, where: k.actor_ap_id == ^actor_ap_id)
          |> Repo.update_all(set: [present: false])

          keys
          |> Enum.with_index()
          |> Enum.each(fn {%{"kid" => kid, "jwk" => jwk, "fingerprint" => fingerprint}, idx} ->
            attrs = %{
              actor_ap_id: actor_ap_id,
              kid: kid,
              jwk: jwk,
              fingerprint: fingerprint,
              position: idx,
              present: true,
              fetched_at: now
            }

            %ActorKey{}
            |> ActorKey.changeset(attrs)
            |> Repo.insert(
              on_conflict: [
                set: [
                  jwk: jwk,
                  fingerprint: fingerprint,
                  position: idx,
                  present: true,
                  fetched_at: now,
                  updated_at: now
                ]
              ],
              conflict_target: [:actor_ap_id, :kid]
            )
          end)
        end)

      {:ok, :refreshed}
    else
      false ->
        {:error, :no_e2ee_keys}

      {:error, _} = error ->
        error

      _ ->
        {:error, :actor_fetch_failed}
    end
  end

  defp refresh_actor_keys(_actor_ap_id), do: {:error, :actor_fetch_failed}

  defp actor_key_to_map(%ActorKey{} = key) do
    %{
      "kid" => key.kid,
      "jwk" => key.jwk,
      "fingerprint" => key.fingerprint
    }
  end

  defp actor_key_to_map(_key), do: nil

  defp cache_fresh?(actor_ap_id) when is_binary(actor_ap_id) do
    ttl = cache_ttl_seconds()

    if ttl <= 0 do
      true
    else
      fetched_at =
        from(k in ActorKey,
          where: k.actor_ap_id == ^actor_ap_id and k.present,
          select: max(k.fetched_at)
        )
        |> Repo.one()

      case fetched_at do
        %DateTime{} = fetched_at ->
          DateTime.diff(DateTime.utc_now(), fetched_at, :second) <= ttl

        _ ->
          false
      end
    end
  end

  defp cache_fresh?(_actor_ap_id), do: false

  defp cache_ttl_seconds do
    case Config.get(:e2ee_actor_keys_cache_ttl_seconds, @default_cache_ttl_seconds) do
      ttl when is_integer(ttl) -> ttl
      _ -> @default_cache_ttl_seconds
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_value), do: nil

  defp fetch_actor_signed(actor_ap_id) when is_binary(actor_ap_id) do
    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           SignedFetch.get(actor_ap_id, accept: @accept),
         {:ok, actor} <- decode_json(body) do
      {:ok, actor}
    else
      _ -> {:error, :actor_fetch_failed}
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
end
