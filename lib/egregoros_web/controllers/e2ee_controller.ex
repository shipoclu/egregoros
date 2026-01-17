defmodule EgregorosWeb.E2EEController do
  use EgregorosWeb, :controller

  alias Egregoros.E2EE
  alias Egregoros.Federation.SignedFetch
  alias Egregoros.Federation.WebFinger
  alias Egregoros.HTTP
  alias Egregoros.SafeURL
  alias Egregoros.User

  def show(conn, _params) do
    case conn.assigns.current_user do
      %User{} = user ->
        render_status(conn, user)

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "unauthorized"})
    end
  end

  def actor_key(conn, params) when is_map(params) do
    with %User{} <- conn.assigns.current_user,
         {:ok, actor_ap_id} <- resolve_actor_ap_id(params),
         {:ok, actor} <- fetch_actor(actor_ap_id),
         {:ok, key} <- extract_actor_key(actor, params["kid"]) do
      json(conn, %{"actor_ap_id" => actor_ap_id, "key" => key})
    else
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "unauthorized"})

      {:error, :invalid_payload} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "invalid_payload"})

      {:error, :no_e2ee_keys} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "no_e2ee_keys"})

      _ ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{"error" => "actor_fetch_failed"})
    end
  end

  def actor_key(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "invalid_payload"})
  end

  def enable_mnemonic(conn, %{
        "kid" => kid,
        "public_key_jwk" => %{} = public_key_jwk,
        "wrapper" => %{
          "type" => type,
          "wrapped_private_key" => wrapped_private_key_b64,
          "params" => %{} = params
        }
      }) do
    with %User{} = user <- conn.assigns.current_user,
         {:ok, wrapped_private_key} <- decode_b64url(wrapped_private_key_b64),
         {:ok, %{key: key}} <-
           E2EE.enable_key_with_wrapper(user, %{
             kid: kid,
             public_key_jwk: public_key_jwk,
             wrapper: %{
               type: type,
               wrapped_private_key: wrapped_private_key,
               params: params
             }
           }) do
      conn
      |> put_status(:created)
      |> json(%{"kid" => key.kid, "fingerprint" => key.fingerprint})
    else
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "unauthorized"})

      {:error, :already_enabled} ->
        conn
        |> put_status(:conflict)
        |> json(%{"error" => "already_enabled"})

      {:error, :invalid_key} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "invalid_payload"})

      {:error, :invalid_base64} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "invalid_payload"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "invalid_payload", "details" => errors_on(changeset)})
    end
  end

  def enable_mnemonic(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "invalid_payload"})
  end

  defp render_status(conn, %User{} = user) do
    case E2EE.get_active_key(user) do
      nil ->
        json(conn, %{"enabled" => false, "active_key" => nil, "wrappers" => []})

      key ->
        wrappers =
          user
          |> E2EE.list_wrappers(key.kid)
          |> Enum.map(fn wrapper ->
            %{
              "type" => wrapper.type,
              "wrapped_private_key" =>
                Base.url_encode64(wrapper.wrapped_private_key, padding: false),
              "params" => wrapper.params
            }
          end)

        json(conn, %{
          "enabled" => true,
          "active_key" => %{
            "kid" => key.kid,
            "fingerprint" => key.fingerprint,
            "public_key_jwk" => key.public_key_jwk,
            "created_at" => DateTime.to_iso8601(key.inserted_at)
          },
          "wrappers" => wrappers
        })
    end
  end

  defp decode_b64url(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_b64url(_), do: {:error, :invalid_base64}

  defp resolve_actor_ap_id(%{"actor_ap_id" => actor_ap_id}) when is_binary(actor_ap_id) do
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

  defp resolve_actor_ap_id(%{"handle" => handle}) when is_binary(handle) do
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

  defp resolve_actor_ap_id(_params), do: {:error, :invalid_payload}

  defp fetch_actor(actor_ap_id) when is_binary(actor_ap_id) do
    headers = [
      {"accept", "application/activity+json, application/ld+json"},
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

  defp fetch_actor_signed(actor_ap_id) when is_binary(actor_ap_id) do
    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           SignedFetch.get(actor_ap_id, accept: "application/activity+json, application/ld+json"),
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

  defp extract_actor_key(%{} = actor, kid) do
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

  defp errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
