defmodule EgregorosWeb.MiniAppSessionRestoreController do
  use EgregorosWeb, :controller

  plug EgregorosWeb.Plugs.RateLimit,
    bucket: :mini_app_session_restore_consumes,
    config_key: :rate_limit_mini_app_session_restore_consumes,
    limit: 60,
    interval_ms: 60_000

  alias Egregoros.MiniApps.SessionRestores

  def consume(
        conn,
        %{"restoreCode" => restore_code, "restoreVerifier" => restore_verifier} = params
      )
      when map_size(params) == 2 and is_binary(restore_code) and is_binary(restore_verifier) do
    conn = secure_response(conn)

    case SessionRestores.consume(restore_code, restore_verifier) do
      {:ok, claims} -> json(conn, claims)
      {:error, :invalid_restore} -> invalid_restore(conn)
    end
  end

  def consume(conn, _params), do: conn |> secure_response() |> invalid_restore()

  defp secure_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp invalid_restore(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "invalid_restore"})
  end
end
