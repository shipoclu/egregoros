defmodule EgregorosWeb.InboxController do
  use EgregorosWeb, :controller

  require Logger

  plug EgregorosWeb.Plugs.RateLimitInbox
  plug EgregorosWeb.Plugs.VerifySignature

  alias Egregoros.Users
  alias Egregoros.Workers.IngestActivity

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @internal_fetch_nickname "internal.fetch"
  @recipient_fields ~w(to cc bto bcc audience)

  def inbox(conn, %{"nickname" => nickname}) do
    with %{ap_id: inbox_user_ap_id} <- Users.get_by_nickname(nickname),
         activity when is_map(activity) <- conn.body_params,
         :ok <- log_incoming_activity(activity, nickname),
         args <- ingest_args(nickname, inbox_user_ap_id, activity),
         {:ok, _job} <-
           Oban.insert(IngestActivity.new(args)) do
      send_resp(conn, 202, "")
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _changeset} -> send_resp(conn, 500, "Internal Server Error")
      _ -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp log_incoming_activity(activity, nickname) when is_map(activity) do
    actor = Map.get(activity, "actor")
    type = Map.get(activity, "type")
    object_info = extract_object_info(Map.get(activity, "object"))

    Logger.debug(
      "Inbox POST to #{nickname}: actor=#{inspect(actor)} type=#{inspect(type)} #{object_info}"
    )

    :ok
  end

  defp extract_object_info(%{"type" => object_type}) when is_binary(object_type) do
    "object_type=#{inspect(object_type)}"
  end

  defp extract_object_info(object_url) when is_binary(object_url) do
    "object_url=#{inspect(object_url)}"
  end

  defp extract_object_info(_), do: ""

  defp ingest_args(@internal_fetch_nickname, _inbox_user_ap_id, activity) when is_map(activity) do
    if public_activity?(activity) do
      %{"activity" => activity}
    else
      %{"activity" => activity, "inbox_user_ap_id" => internal_fetch_ap_id()}
    end
  end

  defp ingest_args(_nickname, inbox_user_ap_id, activity)
       when is_binary(inbox_user_ap_id) and is_map(activity) do
    %{"activity" => activity, "inbox_user_ap_id" => inbox_user_ap_id}
  end

  defp internal_fetch_ap_id do
    EgregorosWeb.Endpoint.url() <> "/users/" <> @internal_fetch_nickname
  end

  defp public_activity?(%{} = activity) do
    addressed_to_public?(activity) or addressed_to_public?(Map.get(activity, "object"))
  end

  defp public_activity?(_activity), do: false

  defp addressed_to_public?(%{} = value) do
    Enum.any?(@recipient_fields, fn field ->
      value
      |> Map.get(field, [])
      |> List.wrap()
      |> Enum.any?(&public_recipient?/1)
    end)
  end

  defp addressed_to_public?(_), do: false

  defp public_recipient?(%{"id" => id}), do: public_recipient?(id)
  defp public_recipient?(%{id: id}), do: public_recipient?(id)

  defp public_recipient?(id) when is_binary(id) do
    String.trim(id) == @as_public
  end

  defp public_recipient?(_), do: false
end
