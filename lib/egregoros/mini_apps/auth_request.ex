defmodule Egregoros.MiniApps.AuthRequest do
  @moduledoc false

  alias Egregoros.MiniApps.OAuthRegistration
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.Origin
  alias Egregoros.OAuth

  @base64url_sha256 ~r/^[A-Za-z0-9_-]{43}$/
  @high_entropy_state ~r/^[A-Za-z0-9_-]{43,256}$/
  @request_id ~r/^[A-Za-z0-9_-]{1,64}$/

  def prepare(app_origin, params) when is_binary(app_origin) and is_map(params) do
    with %OAuthRegistration{} = registration <- OAuthRegistrations.get_by_origin(app_origin),
         client_id when is_binary(client_id) <- Map.get(params, "client_id"),
         %{id: application_id} = application <- OAuth.get_application_by_client_id(client_id),
         true <- application_id == registration.oauth_application_id or {:error, :invalid_client},
         true <- OAuthRegistrations.application_allowed?(application) or {:error, :invalid_client},
         {:ok, request_id} <- request_id(Map.get(params, "request_id")),
         {:ok, redirect_uri} <- redirect_uri(params, registration, app_origin),
         {:ok, scopes} <- scopes(Map.get(params, "scopes"), registration.scopes),
         {:ok, authorization_lifetime_seconds} <-
           OAuthRegistrations.authorization_lifetime(
             application,
             Enum.join(scopes, " "),
             Map.get(params, "authorization_lifetime_seconds")
           ),
         {:ok, state} <- state(Map.get(params, "state")),
         {:ok, code_challenge} <- pkce(params),
         {:ok, completion_mode} <- completion_mode(Map.get(params, "completion_mode")),
         :ok <- handoff_challenge(Map.get(params, "handoff_challenge"), completion_mode) do
      {:ok,
       %{
         request_id: request_id,
         relay_state: state,
         callback_origin: app_origin,
         application_id: application_id,
         redirect_uri: redirect_uri,
         scopes: scopes,
         code_challenge: code_challenge,
         completion_mode: completion_mode,
         authorization_url:
           authorization_url(
             client_id,
             redirect_uri,
             scopes,
             state,
             code_challenge,
             authorization_lifetime_seconds
           )
       }}
    else
      nil -> {:error, :invalid_client}
      false -> {:error, :invalid_request}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def prepare(_app_origin, _params), do: {:error, :invalid_request}

  defp request_id(value) when is_binary(value) do
    if String.match?(value, @request_id), do: {:ok, value}, else: {:error, :invalid_request_id}
  end

  defp request_id(_value), do: {:error, :invalid_request_id}

  defp redirect_uri(params, registration, app_origin) do
    redirect_uri = Map.get(params, "redirect_uri")

    cond do
      not is_binary(redirect_uri) -> {:error, :invalid_redirect_uri}
      redirect_uri not in registration.redirect_uris -> {:error, :invalid_redirect_uri}
      Origin.validate_url(redirect_uri, app_origin) != :ok -> {:error, :invalid_redirect_uri}
      true -> {:ok, redirect_uri}
    end
  end

  defp scopes(requested, registered) when is_list(requested) do
    requested_set = MapSet.new(requested)
    registered_set = MapSet.new(registered)

    if length(requested) in 1..32 and Enum.all?(requested, &is_binary/1) and
         MapSet.size(requested_set) == length(requested) and
         MapSet.subset?(requested_set, registered_set) do
      {:ok, Enum.filter(registered, &MapSet.member?(requested_set, &1))}
    else
      {:error, :invalid_scope}
    end
  end

  defp scopes(_requested, _registered), do: {:error, :invalid_scope}

  defp state(value) when is_binary(value) do
    if String.match?(value, @high_entropy_state), do: {:ok, value}, else: {:error, :invalid_state}
  end

  defp state(_value), do: {:error, :invalid_state}

  defp pkce(params) do
    challenge = Map.get(params, "code_challenge")

    if Map.get(params, "code_challenge_method") == "S256" and is_binary(challenge) and
         String.match?(challenge, @base64url_sha256) do
      {:ok, challenge}
    else
      {:error, :pkce_required}
    end
  end

  defp completion_mode(nil), do: {:ok, "backend_handoff"}
  defp completion_mode("backend_handoff"), do: {:ok, "backend_handoff"}
  defp completion_mode("browser_code"), do: {:ok, "browser_code"}
  defp completion_mode(_value), do: {:error, :invalid_completion_mode}

  defp handoff_challenge(value, "backend_handoff") when is_binary(value) do
    if String.match?(value, @base64url_sha256),
      do: :ok,
      else: {:error, :invalid_handoff_challenge}
  end

  defp handoff_challenge(nil, "browser_code"), do: :ok
  defp handoff_challenge(_value, _completion_mode), do: {:error, :invalid_handoff_challenge}

  defp authorization_url(
         client_id,
         redirect_uri,
         scopes,
         state,
         code_challenge,
         authorization_lifetime_seconds
       ) do
    query =
      URI.encode_query(%{
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => Enum.join(scopes, " "),
        "state" => state,
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256",
        "authorization_lifetime_seconds" => authorization_lifetime_seconds
      })

    "/oauth/authorize?" <> query
  end
end
