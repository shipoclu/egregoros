defmodule EgregorosWeb.MastodonAPI.AppsController do
  use EgregorosWeb, :controller

  plug EgregorosWeb.Plugs.RateLimit,
    bucket: :oauth_apps,
    config_key: :rate_limit_oauth_apps,
    limit: 20,
    interval_ms: 3_600_000

  alias Egregoros.OAuth

  def create(conn, params) do
    case OAuth.create_application(params) do
      {:ok, app} ->
        response =
          %{
            "id" => app.id,
            "name" => app.name,
            "website" => app.website,
            "redirect_uri" => List.first(app.redirect_uris) || "",
            "client_id" => app.client_id,
            "client_secret" => app.client_secret,
            "vapid_key" => ""
          }
          |> maybe_put_kind(app.kind)

        json(conn, response)

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "Could not create application"})
    end
  end

  defp maybe_put_kind(response, "miniapp"), do: Map.put(response, "fap:kind", "miniapp")
  defp maybe_put_kind(response, _kind), do: response
end
