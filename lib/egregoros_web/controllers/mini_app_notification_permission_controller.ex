defmodule EgregorosWeb.MiniAppNotificationPermissionController do
  use EgregorosWeb, :controller

  alias Egregoros.Auth.BearerToken
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.OAuthRegistration
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Scopes
  alias Egregoros.OAuth.Token
  alias Egregoros.User

  def show(conn, _params) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")
      |> put_resp_header("referrer-policy", "no-referrer")

    with {:ok, %Token{user: user, application: application} = token} <- authenticate(conn),
         :ok <- require_identify(token),
         {:ok, %OAuthRegistration{} = registration} <- registration(application.id),
         {:ok, app_actor} <- Declarations.notification_actor(registration.app_origin) do
      if NotificationConsents.granted?(user.id, registration.app_origin) do
        json(conn, %{
          "state" => "granted",
          "recipientActor" => user.ap_id,
          "appActor" => app_actor
        })
      else
        json(conn, %{"state" => "denied"})
      end
    else
      {:error, :unauthorized} ->
        error(conn, 401, "unauthorized")

      {:error, :insufficient_scope} ->
        error(conn, 403, "insufficient_scope")

      {:error, :not_mini_app} ->
        error(conn, 403, "not_mini_app")

      {:error, :notifications_not_declared} ->
        error(conn, 403, "notifications_not_declared")

      {:error, :actor_not_activated} ->
        error(conn, 403, "actor_not_activated")
    end
  end

  defp authenticate(conn) do
    with raw_token when is_binary(raw_token) <- BearerToken.access_token(conn),
         %Token{user: %User{}, application: %{}} = token <- OAuth.get_token(raw_token) do
      {:ok, token}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp require_identify(%Token{scopes: scopes}) do
    if Scopes.contains_all?(scopes, ["identify"]),
      do: :ok,
      else: {:error, :insufficient_scope}
  end

  defp registration(application_id) do
    case OAuthRegistrations.get_by_application_id(application_id) do
      %OAuthRegistration{} = registration -> {:ok, registration}
      _ -> {:error, :not_mini_app}
    end
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{"error" => code})
  end
end
