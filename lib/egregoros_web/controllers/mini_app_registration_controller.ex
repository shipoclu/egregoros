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
         {:ok, registration, :created} <- OAuthRegistrations.register_with_status(manifest),
         %OAuthApplication{} = application <-
           Repo.get(OAuthApplication, registration.oauth_application_id) do
      conn
      |> put_status(:created)
      |> json(%{
        "client_id" => application.client_id,
        "client_secret" => application.client_secret,
        "client_name" => application.name,
        "client_uri" => application.website,
        "redirect_uris" => registration.redirect_uris,
        "scope" => Enum.join(registration.scopes, " "),
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "client_secret_post"
      })
    else
      {:error, :invalid_manifest_url} ->
        registration_error(conn, 422, "invalid_manifest_url", "Use the canonical well-known URL")

      {:ok, _registration, :existing} ->
        registration_error(
          conn,
          409,
          "already_registered",
          "Reuse the existing registration for this issuer"
        )

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
