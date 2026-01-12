defmodule EgregorosWeb.AdminController do
  use EgregorosWeb, :controller

  alias Egregoros.InstanceSettings
  alias Egregoros.Relays
  alias Egregoros.User
  alias EgregorosWeb.Param

  def index(conn, _params) do
    form = Phoenix.Component.to_form(%{"ap_id" => ""}, as: :relay)
    registrations_open? = InstanceSettings.registrations_open?()

    registrations_form =
      Phoenix.Component.to_form(
        %{"open" => registrations_open?},
        as: :registrations
      )

    render(conn, :index,
      relays: Relays.list_relays(),
      form: form,
      registrations_open?: registrations_open?,
      registrations_form: registrations_form,
      notifications_count: notifications_count(conn.assigns.current_user)
    )
  end

  def update_registrations(conn, %{"registrations" => %{} = params}) do
    open? = Param.truthy?(Map.get(params, "open"))

    case InstanceSettings.set_registrations_open(open?) do
      {:ok, _settings} ->
        conn
        |> put_flash(:info, "Registration settings updated.")
        |> redirect(to: ~p"/admin")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not update registration settings.")
        |> redirect(to: ~p"/admin")
    end
  end

  def update_registrations(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> text("Unprocessable Entity")
  end

  def create_relay(conn, %{"relay" => %{} = params}) do
    ap_id = params |> Map.get("ap_id", "") |> to_string() |> String.trim()

    case Relays.subscribe(ap_id) do
      {:ok, _relay} ->
        conn
        |> put_flash(:info, "Relay subscribed.")
        |> redirect(to: ~p"/admin")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not subscribe to relay.")
        |> redirect(to: ~p"/admin")
    end
  end

  def create_relay(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> text("Unprocessable Entity")
  end

  def delete_relay(conn, %{"id" => id}) do
    with {id, _rest} <- Integer.parse(to_string(id)),
         {:ok, _relay} <- Relays.unsubscribe(id) do
      conn
      |> put_flash(:info, "Relay unsubscribed.")
      |> redirect(to: ~p"/admin")
    else
      _ ->
        conn
        |> put_flash(:error, "Could not unsubscribe from relay.")
        |> redirect(to: ~p"/admin")
    end
  end

  defp notifications_count(%User{} = user) do
    Egregoros.Notifications.list_for_user(user, limit: 20)
    |> length()
  end

  defp notifications_count(_), do: 0
end
