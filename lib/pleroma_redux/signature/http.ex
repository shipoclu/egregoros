defmodule PleromaRedux.Signature.HTTP do
  @behaviour PleromaRedux.Signature

  alias PleromaRedux.Users

  @impl true
  def verify_request(conn) do
    headers = normalize_headers(conn.req_headers)

    with {:ok, key_id, signature, headers_param} <- parse_signature(headers),
         {:ok, key} <- public_key_for_key_id(key_id),
         {:ok, method} <- method_atom(conn.method),
         path <- request_path_with_query(conn),
         signature_string <- signature_string(method, path, headers, headers_param),
         true <- verify_rsa(signature, signature_string, key) do
      :ok
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_signature}
      _ -> {:error, :invalid_signature}
    end
  end

  defp normalize_headers(headers) do
    Enum.into(headers, %{}, fn {key, value} -> {String.downcase(key), value} end)
  end

  defp parse_signature(%{"authorization" => authorization}) do
    case parse_authorization(authorization) do
      {:ok, params} -> {:ok, params.key_id, params.signature, params.headers}
      {:error, _} = error -> error
    end
  end

  defp parse_signature(%{"signature" => signature}) do
    parse_signature(Map.put(%{}, "authorization", signature))
  end

  defp parse_signature(_), do: {:error, :missing_signature}

  defp parse_authorization("Signature " <> rest) do
    params =
      rest
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce(%{}, fn part, acc ->
        case String.split(part, "=", parts: 2) do
          [key, value] ->
            Map.put(acc, key, value |> String.trim("\""))

          _ ->
            acc
        end
      end)

    with key_id when is_binary(key_id) <- Map.get(params, "keyId"),
         signature_b64 when is_binary(signature_b64) <- Map.get(params, "signature") do
      headers_param =
        params
        |> Map.get("headers", "(request-target) date")
        |> String.split()

      case Base.decode64(signature_b64) do
        {:ok, decoded} ->
          {:ok,
           %{
             key_id: key_id,
             signature: decoded,
             headers: headers_param
           }}

        :error ->
          {:error, :invalid_signature}
      end
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp parse_authorization(_), do: {:error, :invalid_signature}

  defp public_key_for_key_id(key_id) when is_binary(key_id) do
    ap_id = key_id |> String.split("#") |> List.first()

    case Users.get_by_ap_id(ap_id) do
      %{} = user ->
        [entry] = :public_key.pem_decode(user.public_key)
        {:ok, :public_key.pem_entry_decode(entry)}

      _ ->
        {:error, :unknown_key}
    end
  end

  defp public_key_for_key_id(_), do: {:error, :invalid_signature}

  defp signature_string(method, path, headers, headers_param) do
    headers_param
    |> Enum.map(fn
      "(request-target)" -> "(request-target): #{method} #{path}"
      header -> "#{header}: #{Map.get(headers, header, "")}"
    end)
    |> Enum.join("\n")
  end

  defp verify_rsa(signature, data, public_key) do
    :public_key.verify(data, :sha256, signature, public_key)
  end

  defp request_path_with_query(conn) do
    case conn.query_string do
      "" -> conn.request_path
      nil -> conn.request_path
      qs -> conn.request_path <> "?" <> qs
    end
  end

  defp method_atom(method) when is_binary(method) do
    case String.downcase(method) do
      "get" -> {:ok, "get"}
      "post" -> {:ok, "post"}
      "put" -> {:ok, "put"}
      "patch" -> {:ok, "patch"}
      "delete" -> {:ok, "delete"}
      "head" -> {:ok, "head"}
      "options" -> {:ok, "options"}
      _ -> {:error, :invalid_method}
    end
  end
end
