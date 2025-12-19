defmodule PleromaReduxWeb.RegistrationController do
  use PleromaReduxWeb, :controller

  alias PleromaRedux.User
  alias PleromaRedux.Users

  def new(conn, _params) do
    form = Phoenix.Component.to_form(%{"nickname" => ""}, as: :registration)
    render(conn, :new, form: form, error: nil)
  end

  def create(conn, %{"registration" => %{"nickname" => nickname}}) do
    nickname = nickname |> to_string() |> String.trim()

    cond do
      nickname == "" ->
        form = Phoenix.Component.to_form(%{"nickname" => nickname}, as: :registration)
        render(conn, :new, form: form, error: "Nickname can't be empty.")

      true ->
        case Users.get_by_nickname(nickname) do
          %User{} = user ->
            conn
            |> put_session(:user_id, user.id)
            |> redirect(to: ~p"/")

          nil ->
            case Users.create_local_user(nickname) do
              {:ok, %User{} = user} ->
                conn
                |> put_session(:user_id, user.id)
                |> redirect(to: ~p"/")

              {:error, _changeset} ->
                form = Phoenix.Component.to_form(%{"nickname" => nickname}, as: :registration)
                render(conn, :new, form: form, error: "Nickname is unavailable.")
            end
        end
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> text("Unprocessable Entity")
  end

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end
end

