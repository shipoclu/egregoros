defmodule Egregoros.MiniApps.Manifest do
  @moduledoc """
  Strict parser for `/.well-known/fediverse-miniapp.json`.

  This module validates syntax and exact-origin relationships without making a
  network request. Fetching and DNS/IP safety live behind the mini-app fetcher
  boundary.
  """

  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.StrictJSON

  @max_bytes 65_536
  @default_cache_ttl_seconds 3_600
  @allowed_fields ~w(version name publisher homeUrl iconUrl splash oauth wallet activityPub capabilities cacheTtlSeconds)
  @publisher_fields ~w(name url)
  @splash_fields ~w(imageUrl backgroundColor)
  @oauth_fields ~w(redirectUris scopes scopeAuthorizationMaxAgeSeconds)
  @wallet_fields ~w(evm)
  @evm_fields ~w(enabled required requiredChains)
  @activity_pub_fields ~w(actorUrl publicNotes transactionalMentions)
  @supported_capabilities ~w(compose_note)

  @enforce_keys [:version, :name, :origin, :home_url, :capabilities, :cache_ttl_seconds]
  defstruct [
    :version,
    :name,
    :origin,
    :home_url,
    :publisher,
    :icon_url,
    :splash,
    :oauth,
    :wallet,
    :activity_pub,
    :capabilities,
    :cache_ttl_seconds
  ]

  @type t :: %__MODULE__{}

  def decode(data, manifest_url) when is_binary(data) and is_binary(manifest_url) do
    with {:ok, origin} <- Origin.from_manifest_url(manifest_url),
         {:ok, attrs} <-
           StrictJSON.decode(data,
             max_bytes: @max_bytes,
             too_large_error: :manifest_too_large
           ),
         true <- is_map(attrs) or {:error, :invalid_manifest},
         :ok <- only_fields(attrs, @allowed_fields),
         {:ok, version} <- exact_version(attrs),
         {:ok, name} <- bounded_string(attrs, "name", 1, 64, :invalid_name),
         {:ok, home_url} <- exact_origin_url(attrs, "homeUrl", origin),
         {:ok, publisher} <- publisher(attrs["publisher"], origin),
         {:ok, icon_url} <- optional_exact_origin_url(attrs, "iconUrl", origin),
         {:ok, splash} <- splash(attrs["splash"], origin),
         {:ok, oauth} <- oauth(attrs["oauth"], origin),
         {:ok, wallet} <- wallet(attrs["wallet"]),
         {:ok, activity_pub} <- activity_pub(attrs["activityPub"], origin, oauth),
         {:ok, capabilities} <- capabilities(attrs["capabilities"]),
         :ok <- validate_capability_prerequisites(capabilities, oauth),
         {:ok, cache_ttl_seconds} <- cache_ttl(attrs) do
      {:ok,
       %__MODULE__{
         version: version,
         name: name,
         origin: origin,
         home_url: home_url,
         publisher: publisher,
         icon_url: icon_url,
         splash: splash,
         oauth: oauth,
         wallet: wallet,
         activity_pub: activity_pub,
         capabilities: capabilities,
         cache_ttl_seconds: cache_ttl_seconds
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_manifest}
    end
  end

  def decode(_data, _manifest_url), do: {:error, :invalid_manifest}

  defp exact_version(%{"version" => "1"}), do: {:ok, "1"}
  defp exact_version(_attrs), do: {:error, :unsupported_version}

  defp publisher(nil, _origin), do: {:ok, nil}

  defp publisher(attrs, origin) when is_map(attrs) do
    with :ok <- only_fields(attrs, @publisher_fields),
         {:ok, name} <- bounded_string(attrs, "name", 1, 100, :invalid_publisher),
         {:ok, url} <- exact_origin_url(attrs, "url", origin) do
      {:ok, %{name: name, url: url}}
    end
  end

  defp publisher(_attrs, _origin), do: {:error, :invalid_publisher}

  defp splash(nil, _origin), do: {:ok, nil}

  defp splash(attrs, origin) when is_map(attrs) do
    with :ok <- only_fields(attrs, @splash_fields),
         {:ok, image_url} <- exact_origin_url(attrs, "imageUrl", origin),
         {:ok, background_color} <-
           bounded_string(attrs, "backgroundColor", 7, 7, :invalid_splash),
         true <-
           String.match?(background_color, ~r/^#[0-9a-fA-F]{6}$/) or
             {:error, :invalid_splash} do
      {:ok, %{image_url: image_url, background_color: String.downcase(background_color)}}
    end
  end

  defp splash(_attrs, _origin), do: {:error, :invalid_splash}

  defp oauth(nil, _origin), do: {:ok, nil}

  defp oauth(attrs, origin) when is_map(attrs) do
    with :ok <- only_fields(attrs, @oauth_fields),
         {:ok, redirect_uris} <- string_list(attrs["redirectUris"], 1, 8),
         :ok <- unique(redirect_uris),
         :ok <- all_exact_origin_urls(redirect_uris, origin),
         {:ok, scopes} <- string_list(attrs["scopes"], 1, 32),
         :ok <- unique(scopes),
         true <- Enum.all?(scopes, &valid_scope?/1) or {:error, :invalid_scope},
         true <- "identify" in scopes or "read" in scopes or {:error, :identify_scope_required},
         {:ok, scope_max_ages} <-
           scope_authorization_max_ages(attrs["scopeAuthorizationMaxAgeSeconds"], scopes) do
      {:ok,
       %{
         redirect_uris: redirect_uris,
         scopes: scopes,
         scope_authorization_max_age_seconds: scope_max_ages
       }}
    end
  end

  defp oauth(_attrs, _origin), do: {:error, :invalid_oauth}

  defp scope_authorization_max_ages(nil, _scopes), do: {:ok, %{}}

  defp scope_authorization_max_ages(value, scopes) when is_map(value) do
    valid? =
      map_size(value) <= length(scopes) and
        Enum.all?(value, fn {scope, seconds} ->
          scope in scopes and is_integer(seconds) and seconds in 300..31_536_000
        end)

    if valid?,
      do: {:ok, value},
      else: {:error, :invalid_scope_authorization_max_age}
  end

  defp scope_authorization_max_ages(_value, _scopes),
    do: {:error, :invalid_scope_authorization_max_age}

  defp wallet(nil), do: {:ok, nil}

  defp wallet(attrs) when is_map(attrs) do
    with :ok <- only_fields(attrs, @wallet_fields),
         {:ok, evm} <- evm_wallet(attrs["evm"]) do
      {:ok, %{evm: evm}}
    end
  end

  defp wallet(_attrs), do: {:error, :invalid_wallet}

  defp evm_wallet(attrs) when is_map(attrs) do
    with :ok <- only_fields(attrs, @evm_fields),
         enabled when is_boolean(enabled) <- attrs["enabled"],
         required when is_boolean(required) <- Map.get(attrs, "required", false),
         {:ok, chains} <- string_list(Map.get(attrs, "requiredChains", []), 0, 16),
         :ok <- unique(chains),
         true <- Enum.all?(chains, &valid_chain?/1) or {:error, :invalid_chain},
         true <- enabled or (not required and chains == []) or {:error, :invalid_wallet} do
      {:ok, %{enabled: enabled, required: required, required_chains: chains}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_wallet}
    end
  end

  defp evm_wallet(_attrs), do: {:error, :invalid_wallet}

  defp activity_pub(nil, _origin, _oauth), do: {:ok, nil}

  defp activity_pub(attrs, origin, oauth) when is_map(attrs) do
    with :ok <- only_fields(attrs, @activity_pub_fields),
         {:ok, actor_url} <- exact_origin_url(attrs, "actorUrl", origin),
         :ok <- stable_actor_url(actor_url),
         public_notes when is_boolean(public_notes) <- attrs["publicNotes"],
         transactional_mentions when is_boolean(transactional_mentions) <-
           attrs["transactionalMentions"],
         true <- public_notes or transactional_mentions or {:error, :invalid_activity_pub},
         true <-
           not transactional_mentions or not is_nil(oauth) or
             {:error, :oauth_required_for_transactional_mentions} do
      {:ok,
       %{
         actor_url: actor_url,
         public_notes: public_notes,
         transactional_mentions: transactional_mentions
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_activity_pub}
    end
  end

  defp activity_pub(_attrs, _origin, _oauth), do: {:error, :invalid_activity_pub}

  defp stable_actor_url(actor_url) do
    case URI.parse(actor_url) do
      %URI{path: path, query: query}
      when is_binary(path) and path not in ["", "/"] and query in [nil, ""] ->
        :ok

      _ ->
        {:error, :invalid_activity_pub_actor_url}
    end
  end

  defp capabilities(value) do
    with {:ok, capabilities} <- string_list(value, 0, 16),
         :ok <- unique(capabilities),
         true <-
           Enum.all?(capabilities, &(&1 in @supported_capabilities)) or
             {:error, :unsupported_capability} do
      {:ok, capabilities}
    end
  end

  defp validate_capability_prerequisites(capabilities, nil) do
    if "compose_note" in capabilities,
      do: {:error, :oauth_required_for_capability},
      else: :ok
  end

  defp validate_capability_prerequisites(_capabilities, _oauth), do: :ok

  defp cache_ttl(attrs) do
    case Map.get(attrs, "cacheTtlSeconds", @default_cache_ttl_seconds) do
      ttl when is_integer(ttl) and ttl in 60..3_600 -> {:ok, ttl}
      _ -> {:error, :invalid_cache_ttl}
    end
  end

  defp bounded_string(attrs, key, min, max, error) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        size = String.length(value)

        if size in min..max and String.valid?(value) and String.trim(value) == value,
          do: {:ok, value},
          else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp optional_exact_origin_url(attrs, key, origin) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      _value -> exact_origin_url(attrs, key, origin)
    end
  end

  defp exact_origin_url(attrs, key, origin) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case Origin.validate_url(value, origin) do
          :ok -> {:ok, value}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  defp all_exact_origin_urls(urls, origin) do
    Enum.reduce_while(urls, :ok, fn url, :ok ->
      case Origin.validate_url(url, origin) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp string_list(value, min, max) when is_list(value) and length(value) in min..max//1 do
    if Enum.all?(value, &is_binary/1), do: {:ok, value}, else: {:error, :invalid_list}
  end

  defp string_list(_value, _min, _max), do: {:error, :invalid_list}

  defp unique(values) do
    if length(values) == MapSet.size(MapSet.new(values)),
      do: :ok,
      else: {:error, :duplicate_value}
  end

  defp valid_scope?(scope) when byte_size(scope) in 1..64 do
    String.match?(scope, ~r/^[a-z][a-z0-9:_-]*$/)
  end

  defp valid_scope?(_scope), do: false

  defp valid_chain?(chain) when byte_size(chain) in 1..64 do
    String.match?(chain, ~r/^eip155:[1-9][0-9]*$/)
  end

  defp valid_chain?(_chain), do: false

  defp only_fields(attrs, allowed) when is_map(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in allowed)), do: :ok, else: {:error, :unknown_field}
  end
end
