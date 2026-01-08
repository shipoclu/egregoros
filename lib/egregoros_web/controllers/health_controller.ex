defmodule EgregorosWeb.HealthController do
  use EgregorosWeb, :controller

  alias Egregoros.Repo

  def show(conn, _params) do
    {status, code} =
      case Repo.query("SELECT 1") do
        {:ok, _} -> {"ok", 200}
        _ -> {"error", 503}
      end

    conn
    |> put_status(code)
    |> json(%{
      "status" => if(status == "ok", do: "ok", else: "degraded"),
      "db" => status,
      "version" => app_version()
    })
  end

  defp app_version do
    case Application.spec(:egregoros, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end

