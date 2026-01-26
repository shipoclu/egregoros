defmodule EgregorosWeb.MastodonAPI.AppsController do
  use EgregorosWeb, :controller

  alias Egregoros.OAuth

  def create(conn, params) do
    case OAuth.create_application(params) do
      {:ok, app} ->
        json(conn, %{
          "id" => app.id,
          "name" => app.name,
          "website" => app.website,
          "redirect_uri" => List.first(app.redirect_uris) || "",
          "client_id" => app.client_id,
          "client_secret" => app.client_secret,
          "vapid_key" => ""
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "Could not create application"})
    end
  end
end
