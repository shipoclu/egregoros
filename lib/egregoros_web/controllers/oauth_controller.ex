defmodule EgregorosWeb.OAuthController do
  use EgregorosWeb, :controller

  plug EgregorosWeb.Plugs.RateLimit,
       [bucket: :oauth, config_key: :rate_limit_oauth, limit: 30, interval_ms: 60_000]
       when action in [:approve, :token, :revoke]

  plug :secure_response

  alias Egregoros.OAuth
  alias Egregoros.MiniApps.OAuthRegistrations, as: MiniAppOAuthRegistrations
  alias Egregoros.User

  defp secure_response(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  def authorize(conn, params) do
    case conn.assigns.current_user do
      %User{} -> do_authorize(conn, params)
      _ -> redirect_to_login(conn)
    end
  end

  def approve(conn, %{"oauth" => %{} = params}) do
    case conn.assigns.current_user do
      %User{} = user -> do_approve(conn, user, params)
      _ -> redirect_to_login(conn)
    end
  end

  def approve(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> text("Invalid OAuth request")
  end

  def token(conn, params) do
    params = stringify_keys(params)

    case OAuth.exchange_code_for_token(params) do
      {:ok, token} ->
        expires_in =
          case token.expires_at do
            %DateTime{} = expires_at ->
              max(DateTime.diff(expires_at, DateTime.utc_now(), :second), 0)

            _ ->
              nil
          end

        response =
          %{
            "access_token" => token.token,
            "refresh_token" => token.refresh_token,
            "token_type" => "Bearer",
            "scope" => token.scopes,
            "created_at" => DateTime.to_unix(token.inserted_at)
          }
          |> maybe_put("expires_in", expires_in)

        json(conn, response)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => to_string(reason)})
    end
  end

  def revoke(conn, params) do
    params = stringify_keys(params)

    case OAuth.revoke_token(params) do
      :ok ->
        send_resp(conn, 200, "")

      {:error, :invalid_client} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "invalid_client"})

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => "invalid_request"})
    end
  end

  defp do_authorize(conn, params) do
    with %{} = app <- OAuth.get_application_by_client_id(Map.get(params, "client_id")),
         redirect_uri when is_binary(redirect_uri) and redirect_uri != "" <-
           Map.get(params, "redirect_uri"),
         true <- OAuth.redirect_uri_allowed?(app, redirect_uri),
         "code" <- Map.get(params, "response_type"),
         scope when is_binary(scope) <- Map.get(params, "scope"),
         :ok <-
           MiniAppOAuthRegistrations.validate_authorization(
             app,
             redirect_uri,
             scope,
             code_challenge: Map.get(params, "code_challenge"),
             code_challenge_method: Map.get(params, "code_challenge_method")
           ) do
      mini_app_registration = MiniAppOAuthRegistrations.get_by_application_id(app.id)

      form =
        Phoenix.Component.to_form(
          %{
            "client_id" => app.client_id,
            "redirect_uri" => redirect_uri,
            "response_type" => "code",
            "scope" => scope,
            "state" => Map.get(params, "state", ""),
            "code_challenge" => Map.get(params, "code_challenge", ""),
            "code_challenge_method" => Map.get(params, "code_challenge_method", ""),
            "write_confirmed" => "false"
          },
          as: :oauth
        )

      render(conn, :authorize,
        form: form,
        app: app,
        scope: scope,
        mini_app_registration: mini_app_registration,
        cancel_url:
          oauth_cancel_url(
            mini_app_registration,
            redirect_uri,
            Map.get(params, "state", "")
          )
      )
    else
      nil ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid client_id")

      false ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid redirect_uri")

      _ ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid OAuth request")
    end
  end

  defp oauth_cancel_url(nil, _redirect_uri, _state), do: "/"

  defp oauth_cancel_url(_mini_app_registration, redirect_uri, state) do
    redirect_uri
    |> append_query_params(%{"error" => "access_denied", "state" => to_string(state)})
  end

  defp do_approve(conn, user, params) do
    with %{} = app <- OAuth.get_application_by_client_id(Map.get(params, "client_id")),
         redirect_uri when is_binary(redirect_uri) and redirect_uri != "" <-
           Map.get(params, "redirect_uri"),
         true <- OAuth.redirect_uri_allowed?(app, redirect_uri),
         scope when is_binary(scope) <- Map.get(params, "scope"),
         :ok <- validate_write_confirmation(app, scope, params),
         {:ok, auth_code} <-
           OAuth.create_authorization_code(app, user, redirect_uri, scope,
             code_challenge: Map.get(params, "code_challenge"),
             code_challenge_method: Map.get(params, "code_challenge_method")
           ) do
      state = params |> Map.get("state", "") |> to_string()

      if oob_redirect_uri?(redirect_uri) do
        render(conn, :authorized, code: auth_code.code, app: app)
      else
        redirect_params =
          %{"code" => auth_code.code}
          |> maybe_put("state", state)

        redirect(conn, external: append_query_params(redirect_uri, redirect_params))
      end
    else
      nil ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid client_id")

      false ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid redirect_uri")

      _ ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid OAuth request")
    end
  end

  defp redirect_to_login(conn) do
    return_to = current_return_to(conn)

    conn
    |> redirect(to: "/login?return_to=" <> URI.encode_www_form(return_to))
    |> halt()
  end

  defp current_return_to(conn) do
    case conn.query_string do
      "" -> conn.request_path
      qs -> conn.request_path <> "?" <> qs
    end
  end

  defp oob_redirect_uri?("urn:ietf:wg:oauth:2.0:oob"), do: true
  defp oob_redirect_uri?(_), do: false

  defp validate_write_confirmation(app, scope, params) do
    registration = MiniAppOAuthRegistrations.get_by_application_id(app.id)
    write_requested? = "write" in String.split(scope, ~r/\s+/, trim: true)

    if registration && write_requested? do
      if Map.get(params, "write_confirmed") in [true, "true", "1", "on"],
        do: :ok,
        else: {:error, :write_confirmation_required}
    else
      :ok
    end
  end

  defp append_query_params(url, params) when is_binary(url) and is_map(params) do
    uri = URI.parse(url)
    encoded = URI.encode_query(params)

    query =
      case uri.query do
        nil -> encoded
        "" -> encoded
        existing -> existing <> "&" <> encoded
      end

    URI.to_string(%URI{uri | query: query})
  end

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_map(map) and is_binary(key) and is_binary(value) do
    Map.put(map, key, value)
  end

  defp maybe_put(map, key, value) when is_map(map) and is_binary(key) and is_integer(value) do
    Map.put(map, key, value)
  end

  defp stringify_keys(params) when is_map(params) do
    for {key, value} <- params, into: %{} do
      {to_string(key), value}
    end
  end
end
