defmodule Egregoros.ActivityPub.ObjectAuthority do
  @moduledoc false

  @owner_fields ["actor", "attributedTo", "issuer"]
  @schemes ~w(http https)

  def validate(%{} = object) do
    with id when is_binary(id) <- extract_id(Map.get(object, "id") || Map.get(object, :id)),
         owners when owners != [] <- owner_ids(object),
         {:ok, authority} <- authority(id),
         true <- Enum.all?(owners, &same_authority?(&1, authority)) do
      :ok
    else
      nil -> :ok
      [] -> :ok
      _ -> {:error, :id_authority_mismatch}
    end
  end

  def validate(_object), do: {:error, :id_authority_mismatch}

  defp owner_ids(object) do
    @owner_fields
    |> Enum.flat_map(fn field ->
      object
      |> owner_value(field)
      |> List.wrap()
    end)
    |> Enum.map(&extract_id/1)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp extract_id(%{"id" => id}) when is_binary(id), do: String.trim(id)
  defp extract_id(%{id: id}) when is_binary(id), do: String.trim(id)
  defp extract_id(id) when is_binary(id), do: String.trim(id)
  defp extract_id(_value), do: nil

  defp owner_value(object, "actor"), do: Map.get(object, "actor") || Map.get(object, :actor)

  defp owner_value(object, "attributedTo"),
    do: Map.get(object, "attributedTo") || Map.get(object, :attributedTo)

  defp owner_value(object, "issuer"), do: Map.get(object, "issuer") || Map.get(object, :issuer)

  defp same_authority?(owner_id, authority) when is_binary(owner_id) do
    case authority(owner_id) do
      {:ok, ^authority} -> true
      _ -> false
    end
  end

  defp authority(url) when is_binary(url) do
    case authority_uri(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in @schemes and is_binary(host) and host != "" and is_integer(port) ->
        {:ok, {String.downcase(scheme), String.downcase(host), port}}

      _ ->
        :error
    end
  end

  defp authority_uri("did:web:" <> identifier) do
    host =
      identifier
      |> String.split(":", parts: 2)
      |> List.first()
      |> URI.decode()

    URI.parse("https://" <> host)
  end

  defp authority_uri(url), do: URI.parse(url)
end
