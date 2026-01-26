defmodule EgregorosWeb.PleromaAPI.NotificationsController do
  use EgregorosWeb, :controller

  alias Egregoros.User
  alias Egregoros.Users

  def read(conn, params) do
    with %User{} = user <- conn.assigns.current_user,
         max_id <- params["max_id"] || params["id"],
         max_id when is_binary(max_id) <- normalize_max_id(max_id) do
      Users.bump_notifications_last_seen_id(user, max_id)
    end

    json(conn, %{"status" => "success"})
  end

  defp normalize_max_id(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and flake_id?(value) do
      value
    end
  end

  defp normalize_max_id(_value), do: nil

  defp flake_id?(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" ->
        false

      byte_size(id) < 18 ->
        false

      true ->
        try do
          match?(<<_::128>>, FlakeId.from_string(id))
        rescue
          _ -> false
        end
    end
  end

  defp flake_id?(_id), do: false
end
