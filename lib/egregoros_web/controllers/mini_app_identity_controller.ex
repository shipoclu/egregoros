defmodule EgregorosWeb.MiniAppIdentityController do
  use EgregorosWeb, :controller

  alias Egregoros.Auth.BearerToken
  alias Egregoros.MiniApps.OAuthRegistration
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Scopes
  alias Egregoros.OAuth.Token
  alias Egregoros.User
  alias EgregorosWeb.Endpoint
  alias EgregorosWeb.ProfilePaths
  alias EgregorosWeb.URL

  def show(conn, _params) do
    conn = private_response(conn)

    with {:ok, %Token{user: user, application: application} = token} <- authenticate(conn),
         :ok <- require_identify(token),
         %OAuthRegistration{} <-
           OAuthRegistrations.get_by_application_id(application.id),
         true <- OAuthRegistrations.application_allowed?(application) do
      json(conn, identity(user))
    else
      {:error, :unauthorized} -> error(conn, 401, "unauthorized")
      {:error, :insufficient_scope} -> error(conn, 403, "insufficient_scope")
      _other -> error(conn, 403, "not_mini_app")
    end
  end

  defp authenticate(conn) do
    with raw_token when is_binary(raw_token) <- BearerToken.access_token(conn),
         %Token{user: %User{}, application: %{}} = token <- OAuth.get_token(raw_token) do
      {:ok, token}
    else
      _other -> {:error, :unauthorized}
    end
  end

  defp require_identify(%Token{scopes: scopes}) do
    if Scopes.contains_all?(scopes, ["identify"]),
      do: :ok,
      else: {:error, :insufficient_scope}
  end

  defp identity(%User{} = user) do
    host = URI.parse(Endpoint.url()).host

    %{
      "id" => user.ap_id,
      "username" => user.nickname,
      "acct" => "#{user.nickname}@#{host}",
      "display_name" => user.name || user.nickname,
      "url" => URL.absolute(ProfilePaths.profile_path(user))
    }
  end

  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{"error" => code})
  end
end
