defmodule EgregorosWeb.PleromaAPI.NotificationsController do
  use EgregorosWeb, :controller

  alias Egregoros.User
  alias Egregoros.Users

  def read(conn, params) do
    with %User{} = user <- conn.assigns.current_user,
         max_id <- params["max_id"] || params["id"],
         max_id when is_integer(max_id) and max_id > 0 <- parse_positive_int(max_id) do
      Users.bump_notifications_last_seen_id(user, max_id)
    end

    json(conn, %{"status" => "success"})
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp parse_positive_int(_value), do: nil
end
