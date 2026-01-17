defmodule Egregoros.E2EE.ActorKeys do
  @moduledoc false

  alias Egregoros.E2EE
  alias Egregoros.Federation.SignedFetch
  alias Egregoros.Federation.WebFinger
  alias Egregoros.HTTP
  alias Egregoros.SafeURL
  alias Egregoros.User
  alias Egregoros.Users

  @accept "application/activity+json, application/ld+json"

  def supports_e2ee_dm?(actor_ap_id) when is_binary(actor_ap_id) do
    actor_ap_id = String.trim(actor_ap_id)

    cond do
      actor_ap_id == "" ->
        false

      true ->
        case Users.get_by_ap_id(actor_ap_id) do
          %User{local: true} = user ->
            E2EE.get_active_key(user) != nil

          _ ->
            remote_supports_e2ee_dm?(actor_ap_id)
        end
    end
  end

  def supports_e2ee_dm?(_actor_ap_id), do: false

  def resolve_actor_ap_id(%{"actor_ap_id" => actor_ap_id}) when is_binary(actor_ap_id) do
    actor_ap_id = String.trim(actor_ap_id)

    if actor_ap_id == "" do
      {:error, :invalid_payload}
    else
      with :ok <- SafeURL.validate_http_url(actor_ap_id) do
        {:ok, actor_ap_id}
      else
        _ -> {:error, :invalid_payload}
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
    keys = get_in(actor, ["egregoros:e2ee", "keys"])

    keys =
      keys
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    selected =
      cond do
        is_binary(kid) and String.trim(kid) != "" ->
          Enum.find(keys, fn entry -> is_binary(entry["kid"]) and entry["kid"] == kid end)

        true ->
          List.first(keys)
      end

    case selected do
      %{"kid" => key_kid, "kty" => kty, "crv" => crv, "x" => x, "y" => y} = key
      when is_binary(key_kid) and is_binary(kty) and is_binary(crv) and is_binary(x) and
             is_binary(y) ->
        {:ok,
         %{
           "kid" => key_kid,
           "jwk" => %{"kty" => kty, "crv" => crv, "x" => x, "y" => y},
           "fingerprint" => Map.get(key, "fingerprint")
         }}

      _ ->
        {:error, :no_e2ee_keys}
    end
  end

  def extract_actor_key(_actor, _kid), do: {:error, :no_e2ee_keys}

  defp remote_supports_e2ee_dm?(actor_ap_id) when is_binary(actor_ap_id) do
    with :ok <- SafeURL.validate_http_url(actor_ap_id),
         {:ok, actor} <- fetch_actor(actor_ap_id),
         {:ok, _key} <- extract_actor_key(actor, nil) do
      true
    else
      _ -> false
    end
  end

  defp remote_supports_e2ee_dm?(_actor_ap_id), do: false

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
