defmodule EgregorosWeb.MiniAppRegistrationController do
  use EgregorosWeb, :controller

  plug EgregorosWeb.Plugs.RateLimit,
    bucket: :mini_app_registrations,
    config_key: :rate_limit_mini_app_registrations,
    limit: 20,
    interval_ms: 3_600_000

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.Origin
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo

  def create(conn, %{"manifest_url" => manifest_url}) when is_binary(manifest_url) do
    conn = secure_response(conn)

    with {:ok, origin} <- Origin.from_manifest_url(manifest_url),
         {:ok, manifest} <- MiniApps.fetch_manifest(origin),
         {:ok, registration, registration_status} <-
           OAuthRegistrations.register_with_status(manifest),
         %OAuthApplication{} = application <-
           Repo.get(OAuthApplication, registration.oauth_application_id) do
      conn
      |> put_status(if(registration_status == :created, do: :created, else: :ok))
      |> json(%{
        "client_id" => application.client_id,
        "client_name" => application.name,
        "client_uri" => application.website,
        "redirect_uris" => registration.redirect_uris,
        "scope" => Enum.join(registration.scopes, " "),
        "scope_authorization_max_age_seconds" => registration.scope_authorization_max_age_seconds,
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      })
    else
      {:error, :invalid_manifest_url} ->
        registration_error(conn, 422, "invalid_manifest_url", "Use the canonical well-known URL")

      {:error, :oauth_not_declared} ->
        registration_error(conn, 422, "oauth_not_declared", "The manifest does not declare OAuth")

      {:error, :manifest_changed} ->
        registration_error(
          conn,
          409,
          "manifest_changed",
          "Registered OAuth metadata is immutable"
        )

      {:error, reason} when reason in [:disabled, :domain_denied] ->
        registration_error(conn, 403, Atom.to_string(reason), "Registration is not permitted")

      _ ->
        registration_error(conn, 422, "invalid_manifest", "Manifest registration failed")
    end
  end

  def create(conn, _params) do
    conn
    |> secure_response()
    |> registration_error(422, "invalid_request", "manifest_url is required")
  end

  defp secure_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp registration_error(conn, status, error, description) do
    conn
    |> put_status(status)
    |> json(%{"error" => error, "error_description" => description})
  end
end
