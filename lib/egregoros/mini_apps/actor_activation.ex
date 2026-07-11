defmodule Egregoros.MiniApps.ActorActivation do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  import Bitwise, only: [bsr: 2]

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Declaration
  alias Egregoros.MiniApps.Fetcher
  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.StrictJSON
  alias Egregoros.Repo

  @allowed_types ["Application", "Service"]
  @endpoint_fields ~w(inbox outbox followers)
  @max_pem_bytes 16_384

  def activate(origin) when is_binary(origin) do
    case Repo.get_by(Declaration, app_origin: origin) do
      %Declaration{activity_pub_actor_fingerprint: fingerprint} = declaration
      when is_binary(fingerprint) ->
        {:ok, declaration}

      %Declaration{activity_pub_actor_url: actor_url} = declaration when is_binary(actor_url) ->
        activate_declaration(declaration, actor_url)

      %Declaration{} ->
        {:error, :actor_not_declared}

      nil ->
        {:error, :declaration_not_found}
    end
  end

  def activate(_origin), do: {:error, :declaration_not_found}

  defp activate_declaration(declaration, actor_url) do
    with :ok <- require_current_policy(declaration.app_origin),
         {:ok, %{body: body}} <- Fetcher.get(actor_url, :actor),
         {:ok, actor} <- StrictJSON.decode(body),
         {:ok, fingerprint} <- validate_actor(actor, declaration),
         {:ok, activated} <- pin_activation(declaration, fingerprint) do
      {:ok, activated}
    else
      {:error, reason} when reason in [:timeout, :closed, :econnrefused, :nxdomain] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :invalid_actor_document}

      _ ->
        {:error, :invalid_actor_document}
    end
  end

  defp validate_actor(%{} = actor, %Declaration{} = declaration) do
    actor_url = declaration.activity_pub_actor_url
    origin = declaration.app_origin
    public_key = Map.get(actor, "publicKey")

    with true <- Map.get(actor, "id") == actor_url,
         true <- valid_actor_type?(Map.get(actor, "type")),
         :ok <- validate_endpoints(actor, origin),
         %{} <- public_key,
         true <- Map.get(public_key, "owner") == actor_url,
         :ok <- validate_key_id(Map.get(public_key, "id"), origin),
         pem when is_binary(pem) <- Map.get(public_key, "publicKeyPem"),
         :ok <- validate_rsa_public_key(pem) do
      {:ok, fingerprint(actor, public_key)}
    else
      _ -> {:error, :invalid_actor_document}
    end
  end

  defp validate_actor(_actor, _declaration), do: {:error, :invalid_actor_document}

  defp validate_endpoints(actor, origin) do
    if Enum.all?(@endpoint_fields, fn field ->
         case Map.get(actor, field) do
           url when is_binary(url) -> Origin.validate_url(url, origin) == :ok
           _ -> false
         end
       end) do
      :ok
    else
      {:error, :invalid_actor_document}
    end
  end

  defp validate_key_id(key_id, origin) when is_binary(key_id) do
    uri = URI.parse(key_id)

    with true <- uri.query in [nil, ""],
         true <- uri.userinfo in [nil, ""],
         base = URI.to_string(%{uri | fragment: nil}),
         :ok <- Origin.validate_url(base, origin) do
      :ok
    else
      _ -> {:error, :invalid_actor_document}
    end
  end

  defp validate_key_id(_key_id, _origin), do: {:error, :invalid_actor_document}

  defp validate_rsa_public_key(pem)
       when is_binary(pem) and byte_size(pem) > 0 and byte_size(pem) <= @max_pem_bytes do
    with [entry] <- :public_key.pem_decode(pem),
         {:RSAPublicKey, modulus, exponent} <- :public_key.pem_entry_decode(entry),
         true <- is_integer(modulus) and integer_bit_size(modulus) >= 2_048,
         true <- is_integer(exponent) and exponent >= 3 do
      :ok
    else
      _ -> {:error, :invalid_actor_document}
    end
  rescue
    _ -> {:error, :invalid_actor_document}
  end

  defp validate_rsa_public_key(_pem), do: {:error, :invalid_actor_document}

  defp integer_bit_size(integer) when is_integer(integer) and integer > 0 do
    <<first, rest::binary>> = :binary.encode_unsigned(integer)
    bit_length(first) + byte_size(rest) * 8
  end

  defp integer_bit_size(_integer), do: 0

  defp bit_length(0), do: 0
  defp bit_length(integer), do: 1 + bit_length(bsr(integer, 1))

  defp valid_actor_type?(type) when is_binary(type), do: type in @allowed_types

  defp valid_actor_type?(types) when is_list(types) do
    Enum.any?(types, &(&1 in @allowed_types))
  end

  defp valid_actor_type?(_type), do: false

  defp fingerprint(actor, public_key) do
    {@endpoint_fields |> Enum.map(&Map.fetch!(actor, &1)), Map.fetch!(actor, "id"),
     Map.get(actor, "type"), Map.fetch!(public_key, "id"), Map.fetch!(public_key, "owner"),
     Map.fetch!(public_key, "publicKeyPem")}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp pin_activation(declaration, fingerprint) do
    activated_at = DateTime.utc_now()

    {count, _rows} =
      from(candidate in Declaration,
        where: candidate.id == ^declaration.id,
        where: is_nil(candidate.activity_pub_actor_fingerprint)
      )
      |> Repo.update_all(
        set: [
          activity_pub_actor_fingerprint: fingerprint,
          activity_pub_actor_activated_at: activated_at,
          updated_at: activated_at
        ]
      )

    case {count, Repo.get(Declaration, declaration.id)} do
      {1, %Declaration{} = activated} ->
        {:ok, activated}

      {0, %Declaration{activity_pub_actor_fingerprint: ^fingerprint} = activated} ->
        {:ok, activated}

      _ ->
        {:error, :activation_conflict}
    end
  end

  defp require_current_policy(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) ->
        if MiniApps.domain_allowed?(host), do: :ok, else: {:error, :domain_denied}

      _ ->
        {:error, :invalid_origin}
    end
  end
end
