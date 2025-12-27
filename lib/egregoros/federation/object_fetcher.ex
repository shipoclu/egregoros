defmodule Egregoros.Federation.ObjectFetcher do
  @moduledoc false

  alias Egregoros.Federation.SignedFetch
  alias Egregoros.Pipeline
  alias Egregoros.SafeURL

  @accept "application/activity+json, application/ld+json"

  def fetch_and_ingest(ap_id) when is_binary(ap_id) do
    ap_id = String.trim(ap_id)

    with :ok <- SafeURL.validate_http_url(ap_id),
         {:ok, %{status: status, body: body}} <- SignedFetch.get(ap_id, accept: @accept),
         true <- status in 200..299,
         {:ok, map} <- decode_json(body),
         :ok <- validate_id(map, ap_id),
         {:ok, object} <- Pipeline.ingest(map, local: false) do
      {:ok, object}
    else
      false ->
        {:error, :object_fetch_failed}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :object_fetch_failed}
    end
  end

  def fetch_and_ingest(_ap_id), do: {:error, :object_fetch_failed}

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_json(_body), do: {:error, :invalid_json}

  defp validate_id(%{"id" => id}, expected) when is_binary(id) and is_binary(expected) do
    if id == expected, do: :ok, else: {:error, :id_mismatch}
  end

  defp validate_id(_map, _expected), do: :ok
end
